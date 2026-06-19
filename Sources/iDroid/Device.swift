import Foundation

/// A connected Android device as reported by `adb devices`.
struct Device: Identifiable, Hashable {
    /// The ADB serial (USB serial, or `ip:port` for wireless). Unique per device.
    let serial: String
    /// Connection state reported by adb: "device", "unauthorized", "offline", etc.
    let state: State
    /// Friendly model name, populated lazily from `getprop`.
    var model: String?

    var id: String { serial }

    /// True for a wireless connection (serial looks like `192.168.1.5:5555`).
    var isWireless: Bool {
        serial.contains(":") && serial.split(separator: ":").first.map { $0.contains(".") } == true
    }

    /// Best label to show in the UI.
    var displayName: String {
        if let model, !model.isEmpty { return model }
        return serial
    }

    enum State: String {
        case ready = "device"          // authorized and usable
        case unauthorized              // user hasn't accepted the RSA prompt yet
        case offline
        case unknown

        init(raw: String) {
            self = State(rawValue: raw) ?? .unknown
        }

        var isUsable: Bool { self == .ready }
    }
}

/// Lightweight battery/info snapshot for the dashboard.
struct DeviceInfo {
    var androidVersion: String?
    var batteryLevel: Int?
    var isCharging: Bool?
    var resolution: String?
}
