import Foundation

/// Local, on-Mac persistence for per-phone preferences and the list of phones
/// the user has chosen to "remember." Keyed by ADB serial. Nothing is written
/// to the phone itself.
struct DeviceStore {
    private static let namesKey = "iDroid.customNames"
    private static let knownKey = "iDroid.knownSerials"

    private static var defaults: UserDefaults { .standard }

    // MARK: - Custom names

    static func customNames() -> [String: String] {
        defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]
    }

    static func customName(for serial: String) -> String? {
        customNames()[serial]
    }

    static func setCustomName(_ name: String?, for serial: String) {
        var names = customNames()
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            names[serial] = name
        } else {
            names.removeValue(forKey: serial)
        }
        defaults.set(names, forKey: namesKey)
    }

    // MARK: - Known (remembered) devices

    /// Serials the user has seen/used and wants kept around even when offline,
    /// so they can be reconnected or deleted deliberately.
    static func knownSerials() -> [String] {
        defaults.stringArray(forKey: knownKey) ?? []
    }

    static func remember(_ serial: String) {
        var known = knownSerials()
        guard !known.contains(serial) else { return }
        known.append(serial)
        defaults.set(known, forKey: knownKey)
    }

    /// Fully forget a device: remove it from the known list and drop its name.
    static func forget(_ serial: String) {
        defaults.set(knownSerials().filter { $0 != serial }, forKey: knownKey)
        setCustomName(nil, for: serial)
    }
}
