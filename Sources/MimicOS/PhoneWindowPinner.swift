import Foundation
import AppKit
import ApplicationServices

/// Pins scrcpy's mirror window so it appears on **every** Mission Control space
/// (sticky), while staying freely movable and resizable. The window's last frame
/// is reported back so it can be restored next session.
///
/// scrcpy runs in its own process, so we can't use `NSWindow` directly — we drive
/// its window through the Accessibility API (find by title, read `AXPosition` /
/// `AXSize`) and tag it sticky via the private CoreGraphics window-space API.
@MainActor
final class PhoneWindowPinner {
    /// The window title scrcpy was launched with, so we can find its window.
    private var windowTitle: String?
    /// Re-finds the window and (re)applies the sticky tag as it appears/moves.
    private var watcher: Task<Void, Never>?
    /// Whether sticky/all-spaces pinning is currently active.
    private(set) var isPinned = false
    /// Last known frame of the scrcpy window (in AX/top-left coords), tracked so
    /// the caller can persist and restore it. Updated on every watcher tick.
    private(set) var lastKnownFrame: CGRect?

    /// One-time check (and prompt) that we hold the Accessibility permission
    /// needed to read/move another app's window. Returns true if granted.
    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        // The literal value of kAXTrustedCheckOptionPrompt; using it directly
        // avoids referencing the (non-Sendable) global under strict concurrency.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Begin watching the scrcpy window identified by `title`. When `sticky` is
    /// true the window is tagged onto all spaces; either way we keep tracking its
    /// frame so it can be saved.
    func startTracking(windowTitle title: String, sticky: Bool) {
        windowTitle = title
        isPinned = sticky
        startWatcher()
    }

    /// Turn the sticky/all-spaces tag on or off live, without losing tracking.
    func setSticky(_ sticky: Bool) {
        isPinned = sticky
        if let element = scrcpyWindowElement() {
            setAllSpaces(sticky, for: element)
        }
    }

    /// Stop tracking. Returns the final frame so the caller can persist it.
    @discardableResult
    func stop() -> CGRect? {
        watcher?.cancel()
        watcher = nil
        // Best-effort: clear the sticky tag so a future un-pinned window is normal.
        if let element = scrcpyWindowElement() {
            lastKnownFrame = currentFrame(of: element) ?? lastKnownFrame
            setAllSpaces(false, for: element)
        }
        windowTitle = nil
        isPinned = false
        return lastKnownFrame
    }

    private func startWatcher() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            var taggedWindowID: CGWindowID?
            while !Task.isCancelled {
                self?.tick(taggedWindowID: &taggedWindowID)
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    /// One watcher pass: track the window's frame, and (re)apply the sticky tag
    /// whenever a new window id shows up (scrcpy can recreate its window).
    private func tick(taggedWindowID: inout CGWindowID?) {
        guard let element = scrcpyWindowElement() else { return }
        lastKnownFrame = currentFrame(of: element) ?? lastKnownFrame

        guard isPinned else { return }
        let wid = windowID(of: element)
        if let wid, wid != taggedWindowID {
            setAllSpaces(true, for: element)
            taggedWindowID = wid
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

    /// Current frame in AX coordinates (top-left origin, y grows downward).
    private func currentFrame(of element: AXUIElement) -> CGRect? {
        guard let origin = pointAttribute(element, kAXPositionAttribute),
              let size = sizeAttribute(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
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

    // MARK: - All-spaces via the private CoreGraphics window-space API

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

    /// The scrcpy window's current frame, in **AppKit screen coordinates**
    /// (bottom-left origin), suitable for persisting and feeding back to scrcpy.
    /// scrcpy's `--window-x/-y` use top-left origin, so callers that pass these
    /// back convert as needed; we expose the raw AX (top-left) frame too.
    func currentScrcpyFrame() -> CGRect? {
        guard let element = scrcpyWindowElement() else { return nil }
        return currentFrame(of: element)
    }
}

// Private AX -> CGWindowID bridge. Declared here; resolved at runtime from the
// ApplicationServices framework where it has lived for many macOS releases.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
