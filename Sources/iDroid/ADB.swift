import Foundation

/// All the app-free Android control surface, driven through the `adb` binary.
///
/// Every feature here works without installing anything on the phone — the only
/// prerequisite is that the user enabled USB debugging and authorized this Mac.
enum ADB {
    // MARK: - Availability

    static var isInstalled: Bool { ToolLocator.isAvailable("adb") }

    /// `adb start-server` — ensures the daemon is up. Safe to call repeatedly.
    static func startServer() async {
        _ = await Shell.run(ToolLocator.adb, ["start-server"])
    }

    // MARK: - Device discovery

    /// Parses `adb devices -l` into a list of devices.
    static func listDevices() async -> [Device] {
        let result = await Shell.run(ToolLocator.adb, ["devices"])
        guard result.succeeded else { return [] }

        return result.stdout
            .split(separator: "\n")
            .dropFirst() // header line: "List of devices attached"
            .compactMap { line in
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map(String.init)
                    .filter { !$0.isEmpty }
                guard parts.count >= 2 else { return nil }
                return Device(serial: parts[0], state: .init(raw: parts[1]), model: nil)
            }
    }

    /// Reads a system property for a device. Returns nil if unavailable.
    static func getProp(_ serial: String, _ prop: String) async -> String? {
        let result = await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "getprop", prop])
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Fetches the friendly model name (e.g. "Pixel 7").
    static func model(_ serial: String) async -> String? {
        await getProp(serial, "ro.product.model")
    }

    /// Gathers a battery/version/resolution snapshot for the dashboard.
    static func info(_ serial: String) async -> DeviceInfo {
        var info = DeviceInfo()
        info.androidVersion = await getProp(serial, "ro.build.version.release")

        let battery = await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "dumpsys", "battery"])
        for line in battery.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("level:") {
                info.batteryLevel = Int(trimmed.dropFirst("level:".count).trimmingCharacters(in: .whitespaces))
            } else if trimmed.hasPrefix("status:") {
                // status 2 == charging in Android's BatteryManager
                info.isCharging = trimmed.contains("2")
            }
        }

        let size = await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "wm", "size"])
        if let line = size.stdout.split(separator: "\n").first(where: { $0.contains("Physical size:") }) {
            info.resolution = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
        }
        return info
    }

    // MARK: - Wireless pairing (same Wi-Fi)

    /// Android 11+ pairing: `adb pair host:port` with the 6-digit code shown
    /// under Wireless debugging.
    static func pair(hostPort: String, code: String) async -> ProcessResult {
        await Shell.run(ToolLocator.adb, ["pair", hostPort, code])
    }

    /// Connects to an already-paired device, or one switched into TCP/IP mode.
    static func connect(hostPort: String) async -> ProcessResult {
        await Shell.run(ToolLocator.adb, ["connect", hostPort])
    }

    static func disconnect(hostPort: String) async -> ProcessResult {
        await Shell.run(ToolLocator.adb, ["disconnect", hostPort])
    }

    /// One service line from `adb mdns services`.
    struct MDNSService {
        let instanceName: String   // e.g. "adb-XXXX-YYYY" or our QR service name
        let serviceType: String    // "_adb-tls-pairing._tcp." / "_adb-tls-connect._tcp."
        let hostPort: String       // "192.168.1.5:37123"

        var isPairing: Bool { serviceType.contains("pairing") }
        var isConnect: Bool { serviceType.contains("connect") }
    }

    /// Parses `adb mdns services`. adb's own discovery daemon is the most
    /// reliable source for ADB services — and it's the same daemon that will
    /// perform the pairing handshake, so what it sees here is what `adb pair`
    /// can actually reach.
    ///
    /// Output rows look like:
    ///   adb-39031FDH-vWms8w  _adb-tls-pairing._tcp.  192.168.1.5:37123
    static func mdnsServices() async -> [MDNSService] {
        let result = await Shell.run(ToolLocator.adb, ["mdns", "services"])
        guard result.succeeded else { return [] }

        return result.stdout
            .split(separator: "\n")
            .dropFirst() // "List of discovered mdns services"
            .compactMap { line in
                let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map(String.init)
                    .filter { !$0.isEmpty }
                guard cols.count >= 3 else { return nil }
                return MDNSService(instanceName: cols[0], serviceType: cols[1], hostPort: cols[2])
            }
    }

    // MARK: - Files

    /// Copies a local file onto the device (default: Downloads).
    static func push(_ serial: String, localPath: String, remotePath: String = "/sdcard/Download/") async -> ProcessResult {
        await Shell.run(ToolLocator.adb, ["-s", serial, "push", localPath, remotePath])
    }

    static func pull(_ serial: String, remotePath: String, localPath: String) async -> ProcessResult {
        await Shell.run(ToolLocator.adb, ["-s", serial, "pull", remotePath, localPath])
    }

    /// Installs an APK (replacing an existing install with `-r`).
    static func installAPK(_ serial: String, apkPath: String) async -> ProcessResult {
        await Shell.run(ToolLocator.adb, ["-s", serial, "install", "-r", apkPath])
    }

    // MARK: - Automation (input injection)

    static func tap(_ serial: String, x: Int, y: Int) async {
        _ = await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "input", "tap", "\(x)", "\(y)"])
    }

    static func swipe(_ serial: String, x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int = 300) async {
        _ = await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "input", "swipe",
                                              "\(x1)", "\(y1)", "\(x2)", "\(y2)", "\(durationMs)"])
    }

    static func typeText(_ serial: String, _ text: String) async {
        // adb input text wants spaces escaped as %s.
        let escaped = text.replacingOccurrences(of: " ", with: "%s")
        _ = await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "input", "text", escaped])
    }

    /// Sends a hardware key (e.g. 3 = HOME, 4 = BACK, 26 = POWER).
    static func keyEvent(_ serial: String, keycode: Int) async {
        _ = await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "input", "keyevent", "\(keycode)"])
    }

    /// Launches an app by package + activity, or just brings a package forward.
    static func launchApp(_ serial: String, package: String) async {
        _ = await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "monkey",
                                              "-p", package, "-c", "android.intent.category.LAUNCHER", "1"])
    }

    // MARK: - Notifications (app-free polling)

    /// A best-effort snapshot of active notifications via `dumpsys notification`.
    /// This is a coarse text scrape — good enough for a list, not for actions.
    static func notificationSnapshot(_ serial: String) async -> [String] {
        let result = await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "dumpsys", "notification", "--noredact"])
        guard result.succeeded else { return [] }

        var titles: [String] = []
        for line in result.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // android.title and android.text show up as "key=String (value)".
            if trimmed.hasPrefix("android.title=") || trimmed.hasPrefix("android.text=") {
                if let value = trimmed.split(separator: "=", maxSplits: 1).last {
                    let cleaned = value
                        .replacingOccurrences(of: "String (", with: "")
                        .replacingOccurrences(of: ")", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if !cleaned.isEmpty { titles.append(cleaned) }
                }
            }
        }
        return titles
    }
}
