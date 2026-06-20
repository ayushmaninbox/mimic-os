import Foundation
import ServiceManagement
import os

/// Registers (or unregisters) MimicOS as a macOS login item via `SMAppService`,
/// so it relaunches automatically after a reboot or re-login.
///
/// `SMAppService.mainApp` only works for a real, signed `.app` bundle — when run
/// as a bare SwiftPM binary it throws, which we swallow so development builds
/// don't crash. The user-facing toggle still reflects intent and takes effect in
/// the packaged app.
enum LoginItem {
    private static let log = Logger(subsystem: "com.ayushman.mimicos", category: "LoginItem")

    /// Whether the app is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Turn launch-at-login on or off. Returns true on success.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            log.error("Login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Reconcile the OS login-item registration with the saved preference. Call
    /// at launch so the system state matches what the user chose.
    static func sync(desired: Bool) {
        let current = isEnabled
        guard current != desired else { return }
        setEnabled(desired)
    }
}
