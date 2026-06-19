import Foundation
import AppKit

/// Automatic two-way clipboard sync between the Mac and the connected phone.
///
/// - Mac → phone: we watch `NSPasteboard.changeCount` and push new text to the
///   phone. This is reliable.
/// - phone → Mac: we poll `adb shell cmd clipboard get`. Android restricts
///   background clipboard reads (Android 10+), so this is best-effort and works
///   most reliably while scrcpy holds focus.
@MainActor
final class ClipboardSync {
    private var timer: Timer?
    private var serial: String?

    private var lastMacChangeCount: Int = NSPasteboard.general.changeCount
    private var lastSyncedText: String?

    /// Begins syncing for the given device serial.
    func start(serial: String, interval: TimeInterval = 1.0) {
        stop()
        self.serial = serial
        lastMacChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        serial = nil
        lastSyncedText = nil
    }

    private func tick() async {
        guard let serial else { return }

        // Mac → phone: did the Mac clipboard change since we last looked?
        let pb = NSPasteboard.general
        if pb.changeCount != lastMacChangeCount {
            lastMacChangeCount = pb.changeCount
            if let text = pb.string(forType: .string), text != lastSyncedText {
                lastSyncedText = text
                await ADB.setClipboard(serial, text)
                return // avoid immediately echoing it back this tick
            }
        }

        // phone → Mac: pull the phone clipboard and update the Mac if different.
        if let phoneText = await ADB.getClipboard(serial),
           phoneText != lastSyncedText {
            lastSyncedText = phoneText
            pb.clearContents()
            pb.setString(phoneText, forType: .string)
            lastMacChangeCount = pb.changeCount // don't bounce it back to the phone
        }
    }
}
