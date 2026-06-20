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
