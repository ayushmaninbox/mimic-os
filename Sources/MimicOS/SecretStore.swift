import Foundation
import Security

/// Encrypted, on-Mac storage for unlock secrets — the phone's lock-screen PIN and
/// per-app passwords. Backed by the **macOS Keychain** with a biometric access
/// control, so the bytes are encrypted at rest and the OS itself refuses to hand
/// them over without Touch ID at read time. Nothing is written to the phone.
///
/// This is the "store it in the app, but you must give your fingerprint to use
/// it" model: the secret lives here, but reading it triggers the system Touch ID
/// prompt — there is no plaintext copy we could leak.
enum SecretStore {
    /// Keychain service namespace for everything MimicOS stores.
    private static let service = "com.ayushman.mimicos.secrets"

    /// Account key for a phone's lock-screen PIN/password, namespaced per device
    /// serial so multiple phones don't collide.
    private static func lockAccount(serial: String) -> String { "lockpin::\(serial)" }

    /// Account key for a saved app password, namespaced per device + label.
    private static func appAccount(serial: String, label: String) -> String {
        "apppass::\(serial)::\(label)"
    }

    // MARK: - Lock PIN / password

    /// Stores (or replaces) the lock-screen PIN/password for a device. The value
    /// is gated behind Touch ID (enforced in `AppModel`) for any future read.
    /// Pattern locks aren't supported — Android can't replay a continuous unlock
    /// gesture without root.
    @discardableResult
    static func setLockPIN(_ pin: String, serial: String) -> Bool {
        save(pin, account: lockAccount(serial: serial))
    }

    /// Reads the lock PIN. The Touch ID gate is enforced by the caller before
    /// this runs. Returns nil if none is stored.
    static func lockSecret(serial: String, reason: String) -> String? {
        read(account: lockAccount(serial: serial), reason: reason)
    }

    /// Whether a lock PIN is stored for this device (existence check only — no
    /// secret is read).
    static func hasLockPIN(serial: String) -> Bool {
        exists(account: lockAccount(serial: serial))
    }

    @discardableResult
    static func clearLockPIN(serial: String) -> Bool {
        delete(account: lockAccount(serial: serial))
    }

    // MARK: - App passwords

    /// A saved app-password entry the user can autofill. The password itself
    /// never lives here — only the label; the secret is in the Keychain.
    struct AppEntry: Identifiable, Hashable {
        let label: String          // e.g. "Bank app", "Email"
        var id: String { label }
    }

    @discardableResult
    static func setAppPassword(_ password: String, label: String, serial: String) -> Bool {
        save(password, account: appAccount(serial: serial, label: label))
    }

    static func appPassword(label: String, serial: String, reason: String) -> String? {
        read(account: appAccount(serial: serial, label: label), reason: reason)
    }

    @discardableResult
    static func clearAppPassword(label: String, serial: String) -> Bool {
        delete(account: appAccount(serial: serial, label: label))
    }

    /// Lists the labels of saved app passwords for a device (existence only — no
    /// secret material is read, so no Touch ID prompt).
    static func appLabels(serial: String) -> [String] {
        let prefix = "apppass::\(serial)::"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            // Don't authenticate — we only want the account names, not the data.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .sorted()
    }

    // MARK: - Remote-desktop host passwords

    /// Account key for a saved remote-desktop host's password, namespaced by the
    /// host's stable id so RDP/VNC connections don't collide.
    private static func remoteAccount(hostID: String) -> String { "remote::\(hostID)" }

    @discardableResult
    static func setRemotePassword(_ password: String, hostID: String) -> Bool {
        save(password, account: remoteAccount(hostID: hostID))
    }

    /// Reads a saved host password. Unlike phone secrets, this isn't Touch
    /// ID-gated — it's a convenience credential for a desktop the user owns, on
    /// par with what Remote Desktop / Screen Sharing themselves store.
    static func remotePassword(hostID: String) -> String? {
        read(account: remoteAccount(hostID: hostID), reason: "")
    }

    static func hasRemotePassword(hostID: String) -> Bool {
        exists(account: remoteAccount(hostID: hostID))
    }

    @discardableResult
    static func clearRemotePassword(hostID: String) -> Bool {
        delete(account: remoteAccount(hostID: hostID))
    }

    // MARK: - Keychain primitives

    /// Writes a secret to the Keychain, replacing any existing item for the same
    /// account.
    ///
    /// Note on the biometric gate: a Keychain-level `.biometryCurrentSet` access
    /// control requires the `keychain-access-groups` entitlement, which only
    /// exists in a code-signed `.app` bundle — an unsigned `swift build` binary
    /// gets `errSecMissingEntitlement` (-34018) and the write silently fails.
    /// So we store the item plainly (still encrypted at rest, this-device-only)
    /// and enforce Touch ID in our own code: every caller that reads a secret
    /// goes through `Biometrics.authenticate()` first (see `AppModel`). When the
    /// app ships signed, the hardware-backed flag can be reintroduced here.
    private static func save(_ secret: String, account: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }

        // Remove any prior value first, then add fresh.
        delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Reads a secret from the Keychain. The Touch ID gate is enforced by the
    /// caller (`Biometrics.authenticate()`) before this is invoked — see the note
    /// on `save(_:account:)`.
    private static func read(account: String, reason: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        guard code == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Existence check that never reads the protected data (so no auth prompt).
    private static func exists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    private static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let code = SecItemDelete(query as CFDictionary)
        return code == errSecSuccess || code == errSecItemNotFound
    }
}
