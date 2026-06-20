import Foundation
import AppKit
import ApplicationServices

/// Pins scrcpy's mirror window so it stays put: always-on-top (set via scrcpy's
/// own flag), a locked size/position that it's snapped back to if it drifts, and
/// — where the OS permits — visible on every Mission Control space.
///
/// scrcpy runs in its own process, so we can't use `NSWindow` directly. We drive
/// its window through the Accessibility API (find by title, read/write the
/// `AXPosition`/`AXSize` attributes) and, for the "all spaces" behaviour, the
/// private CoreGraphics window-space API used by window managers.
@MainActor
final class PhoneWindowPinner {
    /// The window title scrcpy was launched with, so we can find its window.
    private var windowTitle: String?
    /// The frame we lock the window to, captured the first time we see it.
    private var lockedFrame: CGRect?
    /// Re-asserts the locked frame and all-spaces flag periodically.
    private var watcher: Task<Void, Never>?
    /// Whether pinning is currently active.
    private(set) var isPinned = false

    /// One-time check (and prompt) that we hold the Accessibility permission
    /// needed to move another app's window. Returns true if granted.
    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        // The literal value of kAXTrustedCheckOptionPrompt; using it directly
        // avoids referencing the (non-Sendable) global under strict concurrency.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Begin pinning the scrcpy window identified by `title`.
    func pin(windowTitle title: String) {
        windowTitle = title
        isPinned = true
        lockedFrame = nil
        Self.ensureAccessibilityPermission(prompt: true)
        startWatcher()
    }

    /// Stop pinning and let the window behave normally again.
    func unpin() {
        isPinned = false
        watcher?.cancel()
        watcher = nil
        lockedFrame = nil
        if let element = scrcpyWindowElement() {
            // Drop it back to the current space only.
            setAllSpaces(false, for: element)
        }
    }

    private func startWatcher() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                self?.reassert()
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }

    /// Find the window, capture its frame the first time, then keep snapping it
    /// back if something moved/resized it, and keep it on all spaces.
    private func reassert() {
        guard isPinned, let element = scrcpyWindowElement() else { return }

        if lockedFrame == nil {
            lockedFrame = currentFrame(of: element)
            setAllSpaces(true, for: element)
        }
        guard let target = lockedFrame else { return }

        if let now = currentFrame(of: element),
           !framesApproximatelyEqual(now, target) {
            setPosition(target.origin, for: element)
            setSize(target.size, for: element)
        }
    }

    // MARK: - Accessibility plumbing

    /// The AXUIElement for scrcpy's mirror window, matched by title.
    private func scrcpyWindowElement() -> AXUIElement? {
        guard let title = windowTitle else { return nil }
        let scrcpyApps = NSWorkspace.shared.runningApplications.filter {
            ($0.executableURL?.lastPathComponent == "scrcpy")
                || ($0.localizedName?.lowercased().contains("scrcpy") ?? false)
        }
        for app in scrcpyApps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for window in windows {
                if let wTitle = stringAttribute(window, kAXTitleAttribute),
                   wTitle == title || wTitle.contains(title) {
                    return window
                }
            }
            // Fall back to the first window if there is exactly one.
            if windows.count == 1 { return windows.first }
        }
        return nil
    }

    private func currentFrame(of element: AXUIElement) -> CGRect? {
        guard let origin = pointAttribute(element, kAXPositionAttribute),
              let size = sizeAttribute(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func setPosition(_ point: CGPoint, for element: AXUIElement) {
        var p = point
        if let axValue = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axValue)
        }
    }

    private func setSize(_ size: CGSize, for element: AXUIElement) {
        var s = size
        if let axValue = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axValue)
        }
    }

    private func stringAttribute(_ element: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func pointAttribute(_ element: AXUIElement, _ attr: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(axValue as! AXValue, .cgPoint, &point)
        return point
    }

    private func sizeAttribute(_ element: AXUIElement, _ attr: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        AXValueGetValue(axValue as! AXValue, .cgSize, &size)
        return size
    }

    private func framesApproximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 2 && abs(a.origin.y - b.origin.y) < 2
            && abs(a.size.width - b.size.width) < 2 && abs(a.size.height - b.size.height) < 2
    }

    // MARK: - All-spaces via the private CoreGraphics window-space API
    //
    // The collection-behaviour bit that makes a window appear on every space is
    // only exposed for our own NSWindows; for another process we use the private
    // CGS space API (the same one window managers like yabai use). It's wrapped
    // in availability/symbol guards so a future macOS that drops it just no-ops
    // and pinning falls back to always-on-top + frame locking.

    private func setAllSpaces(_ enabled: Bool, for element: AXUIElement) {
        guard let windowID = windowID(of: element) else { return }
        PrivateSpaces.setWindowOnAllSpaces(windowID, enabled: enabled)
    }

    /// CoreGraphics window number for an AX window (needed by the CGS space API).
    private func windowID(of element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        // _AXUIElementGetWindow is a private but long-stable bridge from an AX
        // window element to its CGWindowID.
        let result = _AXUIElementGetWindow(element, &wid)
        return result == .success && wid != 0 ? wid : nil
    }
}

// Private AX -> CGWindowID bridge. Declared here; resolved at runtime from the
// ApplicationServices framework where it has lived for many macOS releases.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
