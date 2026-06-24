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

    // MARK: - Wireless connect (USB → TCP/IP over hotspot)

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

    // MARK: - Unlock

    /// The phone's current display size in pixels, e.g. (1080, 2400). nil if it
    /// can't be parsed.
    static func screenSize(_ serial: String) async -> (Int, Int)? {
        let result = await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "wm", "size"])
        guard result.succeeded else { return nil }
        // "Physical size: 1080x2400" (sometimes an "Override size:" line too).
        for line in result.stdout.split(separator: "\n") {
            guard line.contains("size:") else { continue }
            let dims = line.split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces)
                .split(separator: "x")
            if let dims, dims.count == 2,
               let w = Int(dims[0].trimmingCharacters(in: .whitespaces)),
               let h = Int(dims[1].trimmingCharacters(in: .whitespaces)) {
                return (w, h)
            }
        }
        return nil
    }

    /// Wakes the screen and dismisses the lock curtain so the PIN/password entry
    /// is in front. Returns once the swipe has settled.
    static func wakeAndPrepareLockScreen(_ serial: String) async {
        // KEYCODE_WAKEUP (224) turns the screen on without toggling it back off
        // (unlike KEYCODE_POWER, which would sleep an already-awake screen).
        await keyEvent(serial, keycode: 224)
        try? await Task.sleep(for: .milliseconds(350))
        // Swipe up to clear the lock curtain and reveal the PIN pad. Coordinates
        // are derived from the live screen size so it works across resolutions.
        if let (w, h) = await screenSize(serial) {
            await swipe(serial, x1: w / 2, y1: Int(Double(h) * 0.85),
                        x2: w / 2, y2: Int(Double(h) * 0.15), durationMs: 200)
        } else {
            await swipe(serial, x1: 540, y1: 1800, x2: 540, y2: 300, durationMs: 200)
        }
        try? await Task.sleep(for: .milliseconds(350))
    }

    /// Types a numeric/text PIN into the lock screen and confirms it.
    ///
    /// PIN/password unlock screens accept hardware-keyboard digits via
    /// `input text`, then KEYCODE_ENTER (66) submits. (Pattern locks can't be
    /// driven this way — they need per-user gesture coordinates — so this targets
    /// PIN/password locks.)
    static func submitLockPIN(_ serial: String, pin: String) async {
        await typeText(serial, pin)
        try? await Task.sleep(for: .milliseconds(200))
        await keyEvent(serial, keycode: 66)   // KEYCODE_ENTER
    }

    /// Types text into whatever input field currently has focus on the phone —
    /// used to autofill an app password. Does NOT submit, so the user can review
    /// it before confirming via the mirror.
    static func autofillFocusedField(_ serial: String, text: String) async {
        await typeText(serial, text)
    }

    // MARK: - Focused-field detection (for auto-autofill)

    /// What's currently focused on the phone, as far as the input-method service
    /// can tell. Used to auto-offer autofill when a password field gains focus.
    struct FocusedField: Equatable {
        let isPassword: Bool
        let inputType: Int          // raw EditorInfo.inputType
        let packageName: String?    // app owning the focused field
    }

    /// Reads the currently-focused text field's input type + owning package via
    /// `dumpsys input_method`. Returns nil if nothing editable is focused.
    ///
    /// The IME service reports the active `EditorInfo`: we parse its `inputType`
    /// (whose password variations we can recognise) and the `packageName`. This
    /// is app-free and works without root.
    static func focusedField(_ serial: String) async -> FocusedField? {
        let result = await Shell.run(ToolLocator.adb,
            ["-s", serial, "shell", "dumpsys", "input_method"])
        guard result.succeeded else { return nil }

        // The current editor's line looks like:
        //   inputType=0x12 imeOptions=0x... fieldId=0x...
        // We take the LAST non-zero inputType we see (the live focused field;
        // earlier 0x0 lines are stale/unfocused clients).
        var lastType: Int?
        var pkg: String?
        for raw in result.stdout.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let t = parseHexField(line, key: "inputType="), t != 0 {
                lastType = t
            }
            if line.contains("packageName=") {
                pkg = line.split(separator: " ")
                    .first { $0.hasPrefix("packageName=") }
                    .map { String($0.dropFirst("packageName=".count)) }
            }
        }
        guard let type = lastType else { return nil }
        return FocusedField(isPassword: isPasswordInputType(type),
                            inputType: type, packageName: pkg)
    }

    /// Parses a `key=0x..` hex value out of a dumpsys line.
    private static func parseHexField(_ line: String, key: String) -> Int? {
        guard let range = line.range(of: key) else { return nil }
        let rest = line[range.upperBound...]
        let token = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        guard token.hasPrefix("0x") else { return Int(token) }
        return Int(token.dropFirst(2), radix: 16)
    }

    /// True if an Android `EditorInfo.inputType` is a password variation.
    /// TYPE_CLASS_TEXT(0x01) + PASSWORD/VISIBLE/WEB_PASSWORD, or
    /// TYPE_CLASS_NUMBER(0x02) + NUMBER_PASSWORD.
    ///
    /// Android's inputType bit layout: class = `& 0x0f`, variation = `& 0x0ff0`,
    /// flags = `& 0xfff000`. We must mask the VARIATION bits only — using a wider
    /// mask would catch unrelated flag bits (e.g. NO_SUGGESTIONS 0x80000) and
    /// false-positive on ordinary fields like a dialer search box.
    static func isPasswordInputType(_ inputType: Int) -> Bool {
        let cls = inputType & 0x0f
        let variation = inputType & 0x0ff0
        if cls == 0x01 {   // TYPE_CLASS_TEXT
            // 0x80 PASSWORD, 0x90 VISIBLE_PASSWORD, 0xe0 WEB_PASSWORD
            return variation == 0x80 || variation == 0x90 || variation == 0xe0
        }
        if cls == 0x02 {   // TYPE_CLASS_NUMBER
            return variation == 0x10   // NUMBER_VARIATION_PASSWORD
        }
        return false
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

    // Screen recording is handled by scrcpy's own `--record` pipeline (see
    // `Scrcpy.startRecording`), which bypasses the device's `screenrecord` and
    // its "Encoder failed (err=-38)" issues on some phones.

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

    // MARK: - Audio & Do Not Disturb Controls

    /// Sets the phone's ringer mode ("SILENT", "VIBRATE", or "NORMAL").
    @discardableResult
    static func setRingerMode(_ serial: String, mode: String) async -> ProcessResult {
        await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "cmd", "audio", "set-ringer-mode", mode])
    }

    /// Gets the phone's current ringer mode (0 = SILENT, 1 = VIBRATE, 2 = NORMAL).
    static func getRingerMode(_ serial: String) async -> Int? {
        let result = await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "settings", "get", "global", "mode_ringer"])
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Toggles Do Not Disturb mode (DND ON maps to zen_mode > 0, DND OFF maps to zen_mode == 0).
    @discardableResult
    static func setDND(_ serial: String, enabled: Bool) async -> ProcessResult {
        let dndMode = enabled ? "none" : "all"
        return await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "cmd", "notification", "set_dnd", dndMode])
    }

    /// Gets the phone's current zen mode (DND state: 0 = OFF, >=1 = ON).
    static func getZenMode(_ serial: String) async -> Int? {
        let result = await Shell.run(ToolLocator.adb, ["-s", serial, "shell", "settings", "get", "global", "zen_mode"])
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Telephony (incoming-call detection & control)

    /// Direction/phase of the current call, derived from `dumpsys
    /// telephony.registry`.
    enum CallState {
        case idle       // no call
        case ringing    // incoming call ringing (not yet answered)
        case dialing    // outgoing call placed (ringing on the other end)
        case active     // a call is connected
    }

    /// A snapshot of the phone's current call status, read over adb without any
    /// app on the phone. `number` is the other party's number (empty/`nil` if the
    /// OS withholds it or it's a private number).
    struct CallStatus: Equatable {
        var state: CallState
        var number: String?
    }

    /// Reads the current call from `dumpsys telephony.registry`. We deliberately
    /// do NOT use `dumpsys telecom`: on many OEM builds (e.g. the Jio/Android
    /// build this app targets) telecom emits no `Call id=` summary line at all,
    /// and worse, it *redacts* the number to `tel:*************` for privacy. The
    /// telephony registry instead exposes the raw, unredacted number in
    /// `mCallIncomingNumber=` along with the precise call state — and it works
    /// for any country code (+91, +1, …) since we never parse or assume a prefix.
    ///
    /// State mapping (`mCallState`): 0=idle, 1=ringing, 2=offhook. When offhook
    /// we read `mForegroundCallState` to tell a still-dialing outgoing call
    /// (DIALING/ALERTING) from a connected one (ACTIVE).
    ///
    /// The incoming number is only populated by Android while ringing, so for
    /// outgoing/active calls we fall back to the most recent call-log entry,
    /// which carries the full number too. Returns `nil` if the device isn't
    /// reachable.
    static func callStatus(_ serial: String) async -> CallStatus? {
        let result = await Shell.run(ToolLocator.adb,
            ["-s", serial, "shell",
             "dumpsys telephony.registry | grep -E " +
             "'mCallState=|mForegroundCallState=|mCallIncomingNumber='"])
        guard result.exitCode >= 0 else { return nil }

        // The fields repeat once per SIM/subscription; the first occurrence of
        // each is the active voice subscription, which is what we want.
        func firstValue(_ key: String) -> String? {
            for line in result.stdout.split(whereSeparator: \.isNewline) {
                if let r = line.range(of: key) {
                    return line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }

        guard let callStateRaw = firstValue("mCallState=").flatMap({ Int($0) }) else {
            return CallStatus(state: .idle, number: nil)
        }

        // Precise foreground states (android.telephony PreciseCallState):
        // 1=ACTIVE, 3=DIALING, 4=ALERTING.
        let fg = firstValue("mForegroundCallState=").flatMap { Int($0) } ?? 0
        // mCallIncomingNumber is the raw number, but only while ringing.
        let incoming = firstValue("mCallIncomingNumber=")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }

        switch callStateRaw {
        case 1:  // RINGING — incoming, number is in mCallIncomingNumber.
            return CallStatus(state: .ringing, number: incoming)
        case 2:  // OFFHOOK — outgoing (dialing/alerting) or connected (active).
            let state: CallState = (fg == 3 || fg == 4) ? .dialing : .active
            // No incoming number for these; the latest call-log row has it.
            let number: String?
            if let incoming { number = incoming }
            else { number = await latestCallNumber(serial) }
            return CallStatus(state: state, number: number)
        default: // 0 / unknown — no call.
            return CallStatus(state: .idle, number: nil)
        }
    }

    /// The phone number of the most recent call-log entry, used to label an
    /// outgoing/active call (where the live registry doesn't carry a number).
    /// Returns the full number including country code, or `nil` if unavailable.
    private static func latestCallNumber(_ serial: String) async -> String? {
        let result = await Shell.run(ToolLocator.adb,
            ["-s", serial, "shell",
             "content query --uri content://call_log/calls " +
             "--projection number --sort 'date DESC'"])
        guard result.exitCode == 0,
              let r = result.stdout.range(of: "number=") else { return nil }
        let value = result.stdout[r.upperBound...]
            .prefix { $0 != "," && $0 != "\n" && $0 != "\r" }
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Resolves a phone number to a saved contact name via the Contacts
    /// PhoneLookup provider. Returns `nil` if there's no match or the number is
    /// empty. Output looks like: `Row: 0 display_name=Alice`.
    static func contactName(_ serial: String, number: String) async -> String? {
        let digits = number.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty else { return nil }
        let uri = "content://com.android.contacts/phone_lookup/\(digits)"
        let result = await Shell.run(ToolLocator.adb,
            ["-s", serial, "shell",
             "content query --uri \(uri) --projection display_name"])
        guard result.exitCode == 0 else { return nil }
        guard let r = result.stdout.range(of: "display_name=") else { return nil }
        let name = result.stdout[r.upperBound...]
            .prefix { $0 != "\n" && $0 != "\r" }
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    // MARK: - Call log & dialer

    /// One entry from the phone's call log.
    struct CallLogEntry: Identifiable, Equatable {
        enum Kind: Int {
            case incoming = 1, outgoing = 2, missed = 3, voicemail = 4, rejected = 5, blocked = 6
        }
        let id = UUID()
        var number: String
        var name: String?     // resolved contact name, if any
        var kind: Kind
        var date: Date
        var duration: Int     // seconds
    }

    /// Reads the most recent call-log entries (newest first). `limit` caps how
    /// many rows are parsed. Works with no app on the phone.
    static func callLog(_ serial: String, limit: Int = 50) async -> [CallLogEntry] {
        let result = await Shell.run(ToolLocator.adb,
            ["-s", serial, "shell",
             "content query --uri content://call_log/calls " +
             "--projection number:type:date:duration:name --sort 'date DESC'"])
        guard result.exitCode == 0 else { return [] }

        var entries: [CallLogEntry] = []
        for line in result.stdout.split(separator: "\n") where line.contains("Row:") {
            // Format: `Row: 0 number=+91..., type=1, date=178..., duration=22, name=Alice`
            func field(_ key: String) -> String? {
                guard let r = line.range(of: "\(key)=") else { return nil }
                let tail = line[r.upperBound...]
                let v = tail.prefix { $0 != "," }.trimmingCharacters(in: .whitespaces)
                return v.isEmpty || v == "NULL" ? nil : v
            }
            guard let number = field("number"),
                  let typeStr = field("type"), let type = Int(typeStr),
                  let kind = CallLogEntry.Kind(rawValue: type) else { continue }
            let ms = Double(field("date") ?? "0") ?? 0
            let dur = Int(field("duration") ?? "0") ?? 0
            entries.append(CallLogEntry(
                number: number,
                name: field("name"),
                kind: kind,
                date: Date(timeIntervalSince1970: ms / 1000),
                duration: dur))
            if entries.count >= limit { break }
        }
        return entries
    }

    /// Places an outgoing call to `number` on the phone via the dialer intent.
    static func dial(_ serial: String, number: String) async {
        let cleaned = number.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return }
        _ = await Shell.run(ToolLocator.adb,
            ["-s", serial, "shell", "am", "start", "-a",
             "android.intent.action.CALL", "-d", "tel:\(cleaned)"])
    }

    // MARK: - Contacts

    /// A saved contact (name + a single phone number).
    struct Contact: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var number: String
    }

    /// Reads all saved contacts (name + number), sorted by name. De-dupes exact
    /// name+number repeats that some phones store for formatting variants.
    static func contacts(_ serial: String) async -> [Contact] {
        let result = await Shell.run(ToolLocator.adb,
            ["-s", serial, "shell",
             "content query --uri content://com.android.contacts/data/phones " +
             "--projection display_name:data1 --sort 'display_name ASC'"])
        guard result.exitCode == 0 else { return [] }

        var seen = Set<String>()
        var out: [Contact] = []
        for line in result.stdout.split(separator: "\n") where line.contains("Row:") {
            guard let nameR = line.range(of: "display_name="),
                  let numR = line.range(of: "data1=") else { continue }
            let name = line[nameR.upperBound...].prefix { $0 != "," }
                .trimmingCharacters(in: .whitespaces)
            let number = line[numR.upperBound...].prefix { $0 != "," }
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !number.isEmpty else { continue }
            let key = name + "|" + number.filter(\.isNumber)
            if seen.insert(key).inserted {
                out.append(Contact(name: name, number: number))
            }
        }
        return out
    }

    // MARK: - SMS

    /// One SMS message. `id` is stable across refreshes (thread + timestamp +
    /// direction) so live polling doesn't churn SwiftUI's diffing or scroll.
    struct SMS: Identifiable, Equatable {
        var threadID: String
        var address: String   // sender/recipient
        var body: String
        var date: Date
        var incoming: Bool    // type 1 = received, 2 = sent
        var id: String { "\(threadID)-\(Int(date.timeIntervalSince1970 * 1000))-\(incoming ? "i" : "o")" }
    }

    /// A grouped SMS conversation (most-recent message first within `messages`).
    struct Conversation: Identifiable, Equatable {
        var id: String { threadID }
        var threadID: String
        var address: String
        var contactName: String?
        var lastBody: String
        var lastDate: Date
        var messages: [SMS]
    }

    /// Reads recent SMS (newest first) and groups them into conversations by
    /// thread. `limit` caps total messages parsed.
    static func conversations(_ serial: String, limit: Int = 300) async -> [Conversation] {
        let result = await Shell.run(ToolLocator.adb,
            ["-s", serial, "shell",
             "content query --uri content://sms " +
             "--projection thread_id:address:body:date:type --sort 'date DESC'"])
        guard result.exitCode == 0 else { return [] }

        var msgs: [SMS] = []
        for line in result.stdout.split(separator: "\n") where line.contains("Row:") {
            func field(_ key: String) -> String? {
                guard let r = line.range(of: "\(key)=") else { return nil }
                let v = line[r.upperBound...].prefix { $0 != "," }
                    .trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            guard let thread = field("thread_id"),
                  let address = field("address") else { continue }
            let body = field("body") ?? ""
            let ms = Double(field("date") ?? "0") ?? 0
            let type = Int(field("type") ?? "1") ?? 1
            msgs.append(SMS(threadID: thread, address: address, body: body,
                            date: Date(timeIntervalSince1970: ms / 1000),
                            incoming: type == 1))
            if msgs.count >= limit { break }
        }

        // Group by thread, preserving newest-first order of first appearance.
        var order: [String] = []
        var grouped: [String: [SMS]] = [:]
        for m in msgs {
            if grouped[m.threadID] == nil { order.append(m.threadID) }
            grouped[m.threadID, default: []].append(m)
        }
        return order.compactMap { tid in
            guard let list = grouped[tid], let first = list.first else { return nil }
            return Conversation(threadID: tid, address: first.address,
                                contactName: nil, lastBody: first.body,
                                lastDate: first.date, messages: list)
        }
    }

    /// KeyEvent codes for call control. These are injected as hardware keys, so
    /// they work without an app — though a few heavily-skinned OEM ROMs intercept
    /// them, so treat them as best-effort.
    private enum CallKey {
        static let call = 5      // KEYCODE_CALL — answers a ringing call
        static let endCall = 6   // KEYCODE_ENDCALL — declines/hangs up
    }

    /// Answers the currently ringing call (KEYCODE_CALL).
    static func answerCall(_ serial: String) async {
        await keyEvent(serial, keycode: CallKey.call)
    }

    /// Declines the currently ringing call / hangs up the active one (KEYCODE_ENDCALL).
    static func declineCall(_ serial: String) async {
        await keyEvent(serial, keycode: CallKey.endCall)
    }

    /// Silences the ringer for the current incoming call without rejecting it.
    /// `cmd audio set-ringer-mode SILENT` mutes the ringtone immediately; the
    /// call keeps ringing on the network so it can still be answered or will roll
    /// to voicemail.
    static func silenceRinger(_ serial: String) async {
        _ = await setRingerMode(serial, mode: "SILENT")
    }

    /// Toggles the microphone mute on the active call (KEYCODE_MUTE = 91).
    static func toggleCallMute(_ serial: String) async {
        await keyEvent(serial, keycode: 91)
    }

    /// Reads whether the call microphone is currently muted, from `dumpsys audio`
    /// (`mic mute ... from system=true`). Returns nil if it can't be determined.
    static func isMicMuted(_ serial: String) async -> Bool? {
        let result = await Shell.run(ToolLocator.adb,
            ["-s", serial, "shell", "dumpsys audio | grep -m1 'mic mute'"])
        guard result.exitCode == 0,
              let r = result.stdout.range(of: "from system=") else { return nil }
        let value = result.stdout[r.upperBound...]
            .prefix { $0 != "\n" && $0 != "\r" && $0 != " " }
        return value.contains("true")
    }

}

