import Foundation
import AppKit
import ApplicationServices

/// Pins scrcpy's mirror window so it appears on **every** Mission Control space,
/// while staying freely movable and resizable. Also enforces a minimum size and
/// reports the window's last frame for persistence.
///
/// All window finding/tracking is delegated to a shared `ScrcpyWindowTracker`
/// (event-driven via AXObserver). This class just decides when to apply the
/// all-spaces membership (via the private CGS API) and the minimum size.
@MainActor
final class PhoneWindowPinner {
    private let tracker: ScrcpyWindowTracker
    private(set) var isPinned = false
    private(set) var lastKnownFrame: CGRect?

    /// Smallest size (points) the window may shrink to.
    var minimumSize = CGSize(width: 280, height: 480)

    init(tracker: ScrcpyWindowTracker) {
        self.tracker = tracker
        // CRITICAL: macOS only keeps a window on the spaces it was added to *at
        // the moment of the call*; switching desktops doesn't fire an AX move
        // event, so we must re-add the window to all spaces every time the active
        // space changes — otherwise the phone window drops off other desktops.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reapplyOnSpaceChange() }
            }
    }

    // The pinner lives for the whole app session (owned by AppModel), so the
    // space-change observer is intentionally left registered until the process
    // exits — no deinit cleanup needed.

    /// Re-assert all-spaces membership after a desktop switch. Without a
    /// SIP-disabled scripting addition there's no permanent sticky bit, so the
    /// window must be re-added to all spaces each time the active space changes.
    /// We fire a short burst because the window/space state can settle a beat
    /// after the notification.
    private func reapplyOnSpaceChange() {
        guard isPinned else { return }
        applyAllSpaces()
        // A couple of delayed retries to cover the window-recreation / settle race.
        for delay in [0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isPinned else { return }
                self.applyAllSpaces()
            }
        }
    }

    private func applyAllSpaces() {
        guard let wid = tracker.windowID else { return }
        PrivateSpaces.setWindowOnAllSpaces(wid, enabled: true)
    }

    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Begin pinning state. The shared tracker is already running; we just hook
    /// its callbacks to keep the all-spaces membership and min-size applied.
    func startTracking(sticky: Bool) {
        isPinned = sticky
        applyForCurrentWindow()
    }

    func setSticky(_ sticky: Bool) {
        isPinned = sticky
        if sticky {
            applyForCurrentWindow()
        } else if let wid = tracker.windowID {
            PrivateSpaces.setWindowOnAllSpaces(wid, enabled: false)
        }
    }

    /// Called by the owner whenever the tracker reports a frame change, so we can
    /// re-assert pinning (CGS membership can reset on space moves) and clamp size.
    func handleFrameChange(_ frame: CGRect) {
        lastKnownFrame = frame
        enforceMinimumSize(frame)
        if isPinned, let wid = tracker.windowID {
            PrivateSpaces.setWindowOnAllSpaces(wid, enabled: true)
        }
    }

    func handleWindowAppeared(_ frame: CGRect) {
        lastKnownFrame = frame
        applyForCurrentWindow()
    }

    @discardableResult
    func stop() -> CGRect? {
        if let wid = tracker.windowID {
            PrivateSpaces.setWindowOnAllSpaces(wid, enabled: false)
        }
        lastKnownFrame = tracker.currentFrame ?? lastKnownFrame
        isPinned = false
        return lastKnownFrame
    }

    private func applyForCurrentWindow() {
        guard let wid = tracker.windowID else { return }
        if isPinned {
            PrivateSpaces.setWindowOnAllSpaces(wid, enabled: true)
        }
        if let frame = tracker.currentFrame { enforceMinimumSize(frame) }
    }

    private func enforceMinimumSize(_ frame: CGRect) {
        if frame.size.width < minimumSize.width || frame.size.height < minimumSize.height {
            tracker.setSize(CGSize(width: max(frame.size.width, minimumSize.width),
                                   height: max(frame.size.height, minimumSize.height)))
        }
    }
}
