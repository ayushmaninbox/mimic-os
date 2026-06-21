import Foundation
import LocalAuthentication

/// Touch ID / device-password gate. Every secret (the phone's lock PIN, saved
/// app passwords) is released only after the Mac's owner proves who they are —
/// so even though the secrets live on this Mac, nobody can use them without the
/// fingerprint enrolled on this machine.
enum Biometrics {
    /// True if this Mac can do biometric (Touch ID) auth right now.
    static var isAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Prompts for Touch ID (falling back to the Mac login password if no finger
    /// is enrolled or the sensor is unavailable). Returns true only on success.
    ///
    /// `reason` is the line macOS shows in the system prompt, e.g.
    /// "unlock your phone".
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        // Prefer biometrics; if the Mac has no enrolled finger, fall back to the
        // device passcode so the feature still works (just less convenient).
        let policy: LAPolicy = isAvailable
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
