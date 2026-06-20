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

    /// Connects with retries and verifies the device actually reaches "device"
    /// state. After `adb tcpip` the phone's daemon restarts and is briefly
    /// unreachable, so a single connect attempt usually fails — we poll until it
    /// comes back (up to ~`attempts` tries) and confirm via `adb devices`.
    static func connectVerified(hostPort: String, attempts: Int = 12) async -> Bool {
        for attempt in 0..<attempts {
            let result = await Shell.run(ToolLocator.adb, ["connect", hostPort])
            let out = result.stdout.lowercased()
            // "connected to" or "already connected" both mean the socket is up.
            if out.contains("connected to") || out.contains("already connected") {
                // Confirm it's actually usable (not "offline"/"unauthorized").
                let devices = await listDevices()
                if devices.contains(where: { $0.serial == hostPort && $0.state.isUsable }) {
                    return true
                }
            }
            // Daemon still restarting — wait and retry. Back off slightly.
            try? await Task.sleep(for: .milliseconds(attempt < 4 ? 700 : 1200))
        }
        return false
    }

    static func disconnect(hostPort: String) async -> ProcessResult {
        await Shell.run(ToolLocator.adb, ["disconnect", hostPort])
    }

    // MARK: - USB -> wireless (TCP/IP) — works over a phone hotspot

    /// Switches a USB-connected device's adb daemon to listen over TCP/IP on the
    /// given port. This is the classic `adb tcpip` path: it does NOT require the
    /// phone's "Wireless debugging" toggle (which Android disables when there's
    /// no Wi-Fi network), so it works while the phone is sharing a hotspot.
    ///
    /// After this succeeds the USB cable can be unplugged and we connect over
    /// the network. Note: the device falls back to USB mode on reboot.
    static func enableTcpip(_ serial: String, port: Int = 5555) async -> ProcessResult {
        await Shell.run(ToolLocator.adb, ["-s", serial, "tcpip", "\(port)"])
    }

    /// Best-effort detection of the IP address the Mac can reach the phone on.
    ///
    /// When the phone is the hotspot, its access-point interface carries a
    /// gateway address (commonly 192.168.43.1). We read the phone's interfaces
    /// over the USB connection and pick the most likely LAN/hotspot address.
    static func wirelessIP(_ serial: String) async -> String? {
        // `ip route` / `ip addr` are the modern tools; fall back to ifconfig.
        let candidates = [
            ["shell", "ip", "-f", "inet", "addr", "show"],
            ["shell", "ifconfig"]
        ]
        for args in candidates {
            let result = await Shell.run(ToolLocator.adb, ["-s", serial] + args)
            guard result.succeeded else { continue }
            if let ip = parsePrivateIPv4(result.stdout) { return ip }
        }
        return nil
    }

    /// Pulls the first private (RFC1918) IPv4 out of `ip addr` / `ifconfig`
    /// output, preferring hotspot/Wi-Fi ranges over others. Skips loopback.
    private static func parsePrivateIPv4(_ text: String) -> String? {
        // Collect every "inet <ip>" we see.
        var found: [String] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("inet ") || line.contains(" inet ") else { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let idx = tokens.firstIndex(of: "inet"), idx + 1 < tokens.count else { continue }
            // Strip any CIDR suffix or "addr:" prefix.
            var ip = tokens[idx + 1]
            ip = ip.replacingOccurrences(of: "addr:", with: "")
            ip = ip.split(separator: "/").first.map(String.init) ?? ip
            if isPrivateIPv4(ip) { found.append(ip) }
        }
        // Prefer the typical Android hotspot/Wi-Fi ranges.
        let preferred = ["192.168.43.", "192.168.", "172.", "10."]
        for prefix in preferred {
            if let hit = found.first(where: { $0.hasPrefix(prefix) }) { return hit }
        }
        return found.first
    }

    private static func isPrivateIPv4(_ ip: String) -> Bool {
        if ip == "127.0.0.1" { return false }
        return ip.hasPrefix("10.")
            || ip.hasPrefix("192.168.")
            || (172...172).contains(Int(ip.split(separator: ".").first ?? "") ?? 0)
                && (16...31).contains(Int(ip.split(separator: ".").dropFirst().first ?? "") ?? 0)
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

    /// Copies a local file onto the device (default: Downloads), then asks
    /// Android to index the new file so it appears immediately in Gallery/Files
    /// (otherwise MediaStore may not see it until a scan/reboot).
    static func push(_ serial: String, localPath: String, remotePath: String = "/sdcard/Download/") async -> ProcessResult {
        let result = await Shell.run(ToolLocator.adb, ["-s", serial, "push", localPath, remotePath])
        if result.succeeded {
            await scanMedia(serial, path: remotePath)
        }
        return result
    }

    /// Total size of a directory on the phone via `du -s` (returns KB on toybox,
    /// so we multiply by 1024). nil if it can't be read.
    static func directorySize(_ serial: String, path: String) async -> Int64? {
        let result = await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "du", "-s", shellQuote(path)])
        guard result.succeeded else { return nil }
        // Output: "6988\t/sdcard/Download/onboarding"
        let firstField = result.stdout.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
        if let kb = firstField.flatMap({ Int64($0) }) { return kb * 1024 }
        return nil
    }

    /// Byte size of a single file on the phone, or nil if it doesn't exist yet.
    /// Used to compute live transfer progress (adb hides its own % when piped).
    static func fileSize(_ serial: String, path: String) async -> Int64? {
        // `stat -c %s` is available on toybox; fall back to `wc -c`.
        let stat = await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "stat", "-c", "%s", shellQuote(path)])
        if stat.succeeded, let n = Int64(stat.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return n
        }
        return nil
    }

    /// Triggers a MediaStore scan of a path so newly pushed files show up in the
    /// phone's apps without waiting for the periodic scan.
    static func scanMedia(_ serial: String, path: String) async {
        _ = await Shell.run(ToolLocator.adb, [
            "-s", serial, "shell", "am", "broadcast",
            "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
            "-d", "file://\(path)"
        ])
    }

    static func pull(_ serial: String, remotePath: String, localPath: String) async -> ProcessResult {
        await Shell.run(ToolLocator.adb, ["-s", serial, "pull", remotePath, localPath])
    }

    /// Cancellable push — exposes the running process so a transfer can be killed.
    static func pushCancellable(_ serial: String, localPath: String, remotePath: String,
                                onStart: @escaping @Sendable (Process) -> Void) async -> ProcessResult {
        let result = await Shell.runCancellable(ToolLocator.adb,
            ["-s", serial, "push", localPath, remotePath], onStart: onStart)
        if result.succeeded { await scanMedia(serial, path: remotePath) }
        return result
    }

    /// Cancellable pull.
    static func pullCancellable(_ serial: String, remotePath: String, localPath: String,
                                onStart: @escaping @Sendable (Process) -> Void) async -> ProcessResult {
        await Shell.runCancellable(ToolLocator.adb,
            ["-s", serial, "pull", remotePath, localPath], onStart: onStart)
    }

    /// Installs an APK (replacing an existing install with `-r`).
    static func installAPK(_ serial: String, apkPath: String) async -> ProcessResult {
        await Shell.run(ToolLocator.adb, ["-s", serial, "install", "-r", apkPath])
    }

    /// An entry in a phone directory listing.
    struct RemoteFile: Identifiable, Hashable {
        let name: String
        let isDirectory: Bool
        let sizeBytes: Int64?     // nil for directories
        let modified: String?     // "YYYY-MM-DD HH:MM" as reported by ls
        let path: String          // full remote path

        var id: String { path }
    }

    /// Lists a directory on the phone via `ls -lAp`. Toybox `ls` (modern Android)
    /// prints: perms links owner group size YYYY-MM-DD HH:MM name
    static func listFiles(_ serial: String, path: String) async -> [RemoteFile] {
        let result = await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "ls", "-lAp", shellQuote(path)])
        guard result.succeeded else { return [] }

        var files: [RemoteFile] = []
        for raw in result.stdout.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("total ") { continue }
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 8, let perms = cols.first else { continue }
            let isDir = perms.hasPrefix("d")
            let size = isDir ? nil : Int64(cols[4])
            // Toybox date+time live in cols[5] (YYYY-MM-DD) and cols[6] (HH:MM).
            let modified = "\(cols[5]) \(cols[6])"
            // Name is everything after the 8th column (handles spaces in names).
            let nameStart = line.range(of: cols[7])
            var name = nameStart.map { String(line[$0.lowerBound...]) } ?? cols.last ?? ""
            name = name.trimmingCharacters(in: .whitespaces)
            if name.hasSuffix("/") { name.removeLast() }
            if name.isEmpty || name == "." || name == ".." { continue }
            let base = path.hasSuffix("/") ? path : path + "/"
            files.append(RemoteFile(name: name, isDirectory: isDir, sizeBytes: size,
                                    modified: modified, path: base + name))
        }
        return files.sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory && !$1.isDirectory
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Deletes a file or directory on the phone.
    @discardableResult
    static func delete(_ serial: String, path: String) async -> ProcessResult {
        await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "rm", "-rf", shellQuote(path)])
    }

    /// Creates a directory on the phone.
    @discardableResult
    static func makeDirectory(_ serial: String, path: String) async -> ProcessResult {
        await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "mkdir", "-p", shellQuote(path)])
    }

    /// Searches for files recursively under a path on the phone.
    static func searchFiles(_ serial: String, underPath path: String, query: String) async -> [RemoteFile] {
        let escapedQuery = "*\(query)*"
        let args = ["-s", serial, "shell", "find", shellQuote(path), "-iname", shellQuote(escapedQuery), "-maxdepth", "5", "-exec", "ls", "-ld", "{}", "+"]
        let result = await Shell.run(ToolLocator.adb, args)
        
        var files: [RemoteFile] = []
        let lines = result.stdout.split(separator: "\n")
        
        // If find -exec ls -ld failed or returned nothing, let's try a simple find without ls as fallback
        if lines.isEmpty {
            let fallbackArgs = ["-s", serial, "shell", "find", shellQuote(path), "-iname", shellQuote(escapedQuery), "-maxdepth", "5"]
            let fallbackResult = await Shell.run(ToolLocator.adb, fallbackArgs)
            for rawLine in fallbackResult.stdout.split(separator: "\n") {
                let fullPath = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                if fullPath.isEmpty { continue }
                let name = (fullPath as NSString).lastPathComponent
                files.append(RemoteFile(name: name, isDirectory: false, sizeBytes: nil, modified: nil, path: fullPath))
            }
            return files
        }
        
        for raw in lines {
            let line = String(raw)
            if line.hasPrefix("total ") { continue }
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 8, let perms = cols.first else { continue }
            let isDir = perms.hasPrefix("d")
            let size = isDir ? nil : Int64(cols[4])
            let modified = "\(cols[5]) \(cols[6])"
            let nameStart = line.range(of: cols[7])
            var fullPath = nameStart.map { String(line[$0.lowerBound...]) } ?? cols.last ?? ""
            fullPath = fullPath.trimmingCharacters(in: .whitespaces)
            if fullPath.hasSuffix("/") { fullPath.removeLast() }
            if fullPath.isEmpty { continue }
            
            let name = (fullPath as NSString).lastPathComponent
            if name == "." || name == ".." { continue }
            files.append(RemoteFile(name: name, isDirectory: isDir, sizeBytes: size,
                                    modified: modified, path: fullPath))
        }
        return files
    }

    /// Minimal shell quoting for a remote path.
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Clipboard

    /// Reads the phone's clipboard text. Works reliably when scrcpy (or another
    /// foreground app) holds focus; Android restricts background reads otherwise.
    static func getClipboard(_ serial: String) async -> String? {
        let result = await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "cmd", "clipboard", "get"])
        guard result.succeeded else { return nil }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // The command prints nothing (or an error) when empty/denied.
        return text.isEmpty || text.contains("Exception") ? nil : text
    }

    /// Sets the phone's clipboard text.
    ///
    /// `cmd clipboard` syntax varies across Android versions, and many builds
    /// reject a clipboard write unless a foreground app is present. We try the
    /// known subcommand spellings in order and report whether any succeeded.
    @discardableResult
    static func setClipboard(_ serial: String, _ text: String) async -> Bool {
        let quoted = shellQuote(text)
        let variants = [
            ["cmd", "clipboard", "set-text", quoted],     // newer toybox variant
            ["cmd", "clipboard", "set", quoted],          // some Android 13+
            ["cmd", "clipboard", "set-primary", quoted],  // older builds
        ]
        for args in variants {
            let result = await Shell.run(ToolLocator.adb, ["-s", serial, "shell"] + args)
            let combined = (result.stdout + result.stderr).lowercased()
            let rejected = combined.contains("exception")
                || combined.contains("error")
                || combined.contains("unknown command")
                || combined.contains("usage")
            if result.succeeded && !rejected { return true }
        }
        return false
    }

    // MARK: - Screenshot folder watching

    /// Returns the full path of the most recently modified file in the phone's
    /// Screenshots folder, or nil. Used to detect when the user takes a phone
    /// screenshot so MimicOS can mirror it to the Mac's clipboard.
    static func latestScreenshotPath(_ serial: String) async -> String? {
        let dir = "/sdcard/Pictures/Screenshots/"
        // `ls -t` sorts newest-first; take the first real entry.
        let result = await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "ls", "-t", dir])
        guard result.succeeded else { return nil }
        let first = result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("ls:") }
        guard let name = first else { return nil }
        return dir + name
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

    // MARK: - Screen capture & recording

    /// Captures a PNG screenshot of the phone screen straight to a local file on
    /// the Mac. Uses `exec-out screencap -p` so the image bytes stream over adb
    /// without ever touching the phone's storage. Returns the saved URL on
    /// success, or nil. Works whether or not a scrcpy mirror is open.
    static func screenshot(_ serial: String, to localFile: URL) async -> URL? {
        let result = await Shell.runData(ToolLocator.adb,
                                         ["-s", serial, "exec-out", "screencap", "-p"])
        guard result.exitCode == 0, !result.stdout.isEmpty else { return nil }
        do {
            try result.stdout.write(to: localFile)
            return localFile
        } catch {
            return nil
        }
    }

    /// Starts `screenrecord` on the phone, writing to a temp path on the phone.
    /// Returns the live `Process` and the remote path so the caller can stop it
    /// (terminate the process / send SIGINT) and then pull the finished file.
    /// `screenrecord` caps at ~3 minutes per Android's limit; we set --time-limit
    /// to the max so it ends cleanly if not stopped sooner.
    static func startScreenRecord(_ serial: String, remotePath: String,
                                  onStart: @escaping @Sendable (Process) -> Void) -> Bool {
        let args = ["-s", serial, "shell", "screenrecord", "--time-limit", "180", remotePath]
        let proc = Shell.launch(ToolLocator.adb, args)
        if let proc { onStart(proc) }
        return proc != nil
    }

    /// After stopping a recording, pulls the .mp4 off the phone into `localFile`
    /// and deletes the temp file on the phone. Returns the saved URL or nil.
    static func finishScreenRecord(_ serial: String, remotePath: String,
                                   localFile: URL) async -> URL? {
        // screenrecord finalizes the MP4 moov atom only after it gets SIGINT and
        // exits; give it a beat to flush before we pull.
        try? await Task.sleep(for: .milliseconds(800))
        let pull = await Shell.run(ToolLocator.adb,
                                   ["-s", serial, "pull", remotePath, localFile.path])
        _ = await delete(serial, path: remotePath)
        guard pull.succeeded,
              FileManager.default.fileExists(atPath: localFile.path) else { return nil }
        return localFile
    }

    // MARK: - Display rotation

    /// Reads the current user rotation (0–3, where each step is 90°). nil if the
    /// phone doesn't expose it.
    static func userRotation(_ serial: String) async -> Int? {
        let result = await Shell.run(ToolLocator.adb,
            ["-s", serial, "shell", "settings", "get", "system", "user_rotation"])
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Rotates the phone display 90° clockwise. Disables accelerometer-driven
    /// auto-rotate first (otherwise the phone snaps back), then bumps
    /// `user_rotation` to the next 90° step.
    static func rotateDisplay(_ serial: String) async {
        _ = await Shell.run(ToolLocator.adb,
            ["-s", serial, "shell", "settings", "put", "system", "accelerometer_rotation", "0"])
        let current = await userRotation(serial) ?? 0
        let next = (current + 1) % 4
        _ = await Shell.run(ToolLocator.adb,
            ["-s", serial, "shell", "settings", "put", "system", "user_rotation", "\(next)"])
    }

}

