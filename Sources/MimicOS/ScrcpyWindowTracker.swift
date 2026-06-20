import Foundation
import AppKit
import ApplicationServices

/// Tracks scrcpy's mirror window and reports its frame the instant it moves or
/// resizes — **event-driven** via `AXObserver`, not polling — so anything docked
/// to it (the floating remote) follows perfectly smoothly.
///
/// scrcpy is a separate process, so we locate its window through the
/// Accessibility API and subscribe to move/resize/destroy notifications. A slow
/// safety-net poll re-acquires the window if scrcpy recreates it (e.g. on a
/// reconnect), but normal movement is delivered as live callbacks.
@MainActor
final class ScrcpyWindowTracker {
    /// Frame in top-left-origin screen coordinates, pushed on every change.
    var onFrameChange: ((CGRect) -> Void)?
    /// Fired when the window appears (or reappears after being recreated).
    var onAppear: ((CGRect) -> Void)?
    /// Fired when the window goes away.
    var onDisappear: (() -> Void)?
    /// Fired when scrcpy's window is raised/focused (so the docked sidebar can be
    /// re-ordered to come forward with it).
    var onRaise: (() -> Void)?

    private var windowTitle: String?
    private var axApp: AXUIElement?
    private var axWindow: AXUIElement?
    private var observer: AXObserver?
    private var reacquireTimer: Timer?
    private(set) var currentFrame: CGRect?
    private(set) var windowID: CGWindowID?

    /// Smallest size (points) the phone window is allowed to shrink to. Enforced
    /// on every resize event so the mirror never becomes a tiny unusable sliver.
    var minimumSize = CGSize(width: 280, height: 480)

    private var activationObserver: NSObjectProtocol?

    func start(windowTitle title: String) {
        windowTitle = title
        acquireWindow()
        // Low-frequency safety net: re-acquire if scrcpy recreated its window,
        // or first-acquire if it wasn't up yet when we started. This does NOT
        // drive movement — that's all event-based — so it can be slow & cheap.
        reacquireTimer?.invalidate()
        reacquireTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.acquireIfNeeded() }
        }
        // When scrcpy is brought to the front (e.g. clicked, or opened from
        // Mission Control), raise the docked sidebar with it. A click that only
        // focuses the window fires no AX move event, so we listen for app
        // activation instead.
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main) { [weak self] _ in
                    // The queue is .main, so read the now-frontmost app directly
                    // rather than the non-Sendable notification payload.
                    let isScrcpy = NSWorkspace.shared.frontmostApplication?
                        .localizedName?.lowercased().contains("scrcpy") ?? false
                    MainActor.assumeIsolated {
                        guard let self, isScrcpy else { return }
                        self.onRaise?()
                    }
                }
        }
    }

    func stop() {
        reacquireTimer?.invalidate()
        reacquireTimer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        teardownObserver()
        windowTitle = nil
        axApp = nil
        axWindow = nil
        currentFrame = nil
        windowID = nil
    }

    /// Re-read the frame on demand (used right after acquiring).
    func refreshFrame() {
        guard let axWindow, let frame = frame(of: axWindow) else { return }
        currentFrame = frame
        onFrameChange?(frame)
    }

    // MARK: - Window acquisition

    private func acquireIfNeeded() {
        // Still valid? Cheap check: can we still read its position?
        if let axWindow, frame(of: axWindow) != nil { return }
        teardownObserver()
        axWindow = nil
        acquireWindow()
    }

    private func acquireWindow() {
        guard let title = windowTitle else { return }
        // scrcpy spawns more than one process (the SDL UI app plus dock-less
        // helpers). Only one actually owns the mirror window, so scan ALL of them
        // and match on the window title — picking the first matching process by
        // PID alone grabs the wrong (window-less) one.
        let apps = NSWorkspace.shared.runningApplications.filter {
            ($0.executableURL?.lastPathComponent == "scrcpy")
                || ($0.localizedName?.lowercased().contains("scrcpy") ?? false)
        }

        var anyWindow: (pid: pid_t, app: AXUIElement, window: AXUIElement)?
        for app in apps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement], !windows.isEmpty else { continue }

            if let exact = windows.first(where: { w in
                if let t = string(w, kAXTitleAttribute) { return t == title || t.contains(title) }
                return false
            }) {
                bind(pid: app.processIdentifier, app: appElement, window: exact)
                return
            }
            if anyWindow == nil {
                anyWindow = (app.processIdentifier, appElement, windows[0])
            }
        }

        // No title match (scrcpy may report an empty AX title on some builds) —
        // fall back to the single scrcpy window we did find.
        if let any = anyWindow {
            bind(pid: any.pid, app: any.app, window: any.window)
        }
    }

    private func bind(pid: pid_t, app: AXUIElement, window: AXUIElement) {
        axApp = app
        axWindow = window
        windowID = Self.windowID(of: window)
        installObserver(pid: pid, window: window)
        if let raw = frame(of: window) {
            let frame = enforceMinimumSize(raw)
            currentFrame = frame
            onAppear?(frame)
            onFrameChange?(frame)
        }
    }

    // MARK: - AXObserver (live move/resize callbacks)

    private func installObserver(pid: pid_t, window: AXUIElement) {
        teardownObserver()
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<ScrcpyWindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in tracker.handleAXEvent() }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        observer = obs

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for note in [kAXMovedNotification, kAXResizedNotification,
                     kAXWindowMovedNotification, kAXWindowResizedNotification,
                     kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(obs, window, note as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    private func teardownObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                                  AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
    }

    private func handleAXEvent() {
        guard let axWindow else { return }
        guard var frame = frame(of: axWindow) else {
            // Window destroyed.
            teardownObserver()
            self.axWindow = nil
            currentFrame = nil
            windowID = nil
            onDisappear?()
            return
        }
        frame = enforceMinimumSize(frame)
        currentFrame = frame
        windowID = Self.windowID(of: axWindow)
        onFrameChange?(frame)
    }

    /// Grow the window back up to the minimum size if the user shrank it too far.
    private func enforceMinimumSize(_ frame: CGRect) -> CGRect {
        guard frame.width < minimumSize.width || frame.height < minimumSize.height else { return frame }
        let clamped = CGSize(width: max(frame.width, minimumSize.width),
                             height: max(frame.height, minimumSize.height))
        setSize(clamped)
        var out = frame
        out.size = clamped
        return out
    }

    // MARK: - AX attribute helpers

    func setSize(_ size: CGSize) {
        guard let axWindow else { return }
        var s = size
        if let v = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, v)
        }
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = point(element, kAXPositionAttribute),
              let size = sizeValue(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func string(_ element: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private func point(_ element: AXUIElement, _ attr: String) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &v) == .success,
              let val = v, CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        AXValueGetValue(val as! AXValue, .cgPoint, &p)
        return p
    }

    private func sizeValue(_ element: AXUIElement, _ attr: String) -> CGSize? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &v) == .success,
              let val = v, CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        AXValueGetValue(val as! AXValue, .cgSize, &s)
        return s
    }

    /// CGWindowID for an AX window via the long-stable private bridge.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        let result = _AXUIElementGetWindow(element, &wid)
        return result == .success && wid != 0 ? wid : nil
    }
}

// Private AX -> CGWindowID bridge, resolved from ApplicationServices at runtime.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
