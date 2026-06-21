import Foundation

/// Launches and manages remote-desktop sessions to a Windows (RDP) or
/// Linux/macOS (VNC) machine.
///
/// Like `Scrcpy`, this app doesn't embed the remote framebuffer — it launches an
/// external client that opens its own native window. RDP (Windows, or Linux via
/// xrdp) runs through a FreeRDP client — preferring the SDL build, which needs no
/// XQuartz — or, if none is installed, a `.rdp` file handed to whatever RDP client
/// the user has. VNC (Linux/macOS) uses the built-in Screen Sharing app
/// (`open vnc://…`). MimicOS builds the right command line and tracks the running
/// process so it can be stopped.
final class RemoteDesktop {
    /// Which wire protocol a saved host speaks.
    enum Kind: String, CaseIterable, Identifiable, Codable {
        case rdp   // Windows Remote Desktop
        case vnc   // Linux/macOS Screen Sharing

        var id: String { rawValue }
        var label: String {
            switch self {
            case .rdp: return "RDP"
            case .vnc: return "VNC"
            }
        }
        var defaultPort: Int {
            switch self {
            case .rdp: return 3389
            case .vnc: return 5900
            }
        }
    }

    /// Everything needed to open one connection.
    struct Connection {
        var host: String
        var port: Int?
        var username: String
        var password: String
        var proto: Kind
        /// Open RDP straight into fullscreen. When false, opens in a resizable
        /// window that scales the remote desktop to fit (smart-sizing), so nothing
        /// gets clipped. Either way, Ctrl+Alt+Enter toggles fullscreen live.
        var fullscreen: Bool = false
        /// Make the Mac's ⌘ (Command) key act as Ctrl inside the RDP session, so
        /// ⌘C/⌘V/⌘Tab work like on the Mac (RDP only).
        var commandAsCtrl: Bool = true
    }

    /// FreeRDP client binaries we can drive, in priority order. The SDL clients
    /// (`sdl-freerdp` / `sdl3-freerdp` / `sdl2-freerdp`) render natively and need
    /// NO XQuartz, so they're preferred; `xfreerdp` is the X11 build (needs
    /// XQuartz) kept as a fallback. All share the same `/v: /u: /p:` CLI syntax.
    static let freeRDPClientNames = ["sdl-freerdp", "sdl3-freerdp", "sdl2-freerdp", "xfreerdp"]

    /// The path to the first installed FreeRDP client, or nil if none is present.
    static var freeRDPClient: String? {
        for name in freeRDPClientNames where ToolLocator.isAvailable(name) {
            return ToolLocator.path(for: name)
        }
        return nil
    }

    /// True when any FreeRDP client is installed. When present, RDP runs in a
    /// window we own and can stop; otherwise we hand a generated `.rdp` file to
    /// whatever RDP client the user has (NoMachine, Remmina, etc.) via `open`.
    static var freeRDPInstalled: Bool { freeRDPClient != nil }

    private var process: Process?
    var lastError: String = ""

    /// True while a session is running. VNC hands off to the OS Screen Sharing
    /// app (a separate process we don't own), so it's only ever true for RDP.
    var isRunning: Bool { process?.isRunning ?? false }

    /// Opens a connection. `onExit` fires when an owned client process (RDP) ends.
    /// VNC launches the system Screen Sharing app and returns immediately — we
    /// can't track its lifetime, so `onExit` is called right away for VNC.
    @discardableResult
    func connect(_ connection: Connection,
                 onExit: (@Sendable (Int32, String) -> Void)? = nil) -> Bool {
        stop()
        lastError = ""
        switch connection.proto {
        case .rdp: return connectRDP(connection, onExit: onExit)
        case .vnc: return connectVNC(connection, onExit: onExit)
        }
    }

    // MARK: - RDP

    /// Opens an RDP machine (Windows or Linux xrdp). Prefers an installed FreeRDP
    /// client — the SDL build renders natively with no XQuartz — running in a
    /// window we own and can stop. With no FreeRDP client present, falls back to
    /// writing a `.rdp` file and handing it to whatever RDP client the user has
    /// (NoMachine, Remmina, etc.) via `open`, which we don't own.
    private func connectRDP(_ c: Connection,
                            onExit: (@Sendable (Int32, String) -> Void)?) -> Bool {
        if let client = RemoteDesktop.freeRDPClient {
            return connectRDPViaFreeRDP(c, clientPath: client, onExit: onExit)
        }
        return connectRDPViaFile(c, onExit: onExit)
    }

    /// Builds a `.rdp` file and opens it with the default RDP client. macOS
    /// prompts to choose / find one if none is installed. The password can't be
    /// embedded in a plain `.rdp` (it needs DPAPI-encrypted blobs), so the client
    /// prompts for it — the saved username is still prefilled.
    private func connectRDPViaFile(_ c: Connection,
                                   onExit: (@Sendable (Int32, String) -> Void)?) -> Bool {
        let host = c.port.map { "\(c.host):\($0)" } ?? c.host
        var lines = [
            "full address:s:\(host)",
            "screen mode id:i:\(c.fullscreen ? 2 : 1)",   // 2 = fullscreen, 1 = window
            "dynamic resolution:i:1",
            "smart sizing:i:1",
            "redirectclipboard:i:1",
            "audiomode:i:1",                      // play audio on the remote machine
            "authentication level:i:0",           // don't fail on cert mismatch
        ]
        if !c.username.isEmpty { lines.append("username:s:\(c.username)") }

        let safeName = c.host.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimicOS-\(safeName).rdp")
        do {
            try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            lastError = "Couldn't write .rdp file: \(error.localizedDescription)"
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [tmp.path]
        do {
            try process.run()
            process.waitUntilExit()
            // `open` hands off to the RDP client and returns; we don't track that
            // client's lifetime, so RDP-via-file is fire-and-forget.
            onExit?(process.terminationStatus, "")
            return process.terminationStatus == 0
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - RDP via a FreeRDP client (SDL build = no XQuartz; or X11 xfreerdp)

    private func connectRDPViaFreeRDP(_ c: Connection,
                                      clientPath: String,
                                      onExit: (@Sendable (Int32, String) -> Void)?) -> Bool {
        let host = c.port.map { "\(c.host):\($0)" } ?? c.host
        var args = ["/v:\(host)"]
        if !c.username.isEmpty { args.append("/u:\(c.username)") }
        if !c.password.isEmpty { args.append("/p:\(c.password)") }

        if c.fullscreen {
            // Avoid native macOS space-switching which causes black screens under XQuartz/SDL.
            // Launch as a borderless window matching full screen size instead.
            args.append(contentsOf: ["-decorations", "/size:100%", "/smart-sizing", "/gdi:sw"])
        } else {
            // Open in a generous resizable window and scale the remote desktop to
            // fit it (smart-sizing) so nothing is clipped and dragging resizes the
            // view. Without this the SDL window opens at the server's resolution
            // and gets cut off with no way to fit it. Ctrl+Alt+Enter still toggles
            // true fullscreen.
            args.append(contentsOf: ["/size:1440x900", "/smart-sizing"])
        }
        // Trust an unknown/self-signed cert and don't block on the prompt — most
        // home/lab Windows / xrdp boxes use a self-signed RDP certificate.
        args.append("/cert:ignore")
        if c.commandAsCtrl {
            // Map the Mac's ⌘ (which SDL reports as Left Win, 0x15b) to Left Ctrl
            // (0x1d), so ⌘C/⌘V/etc. behave like Ctrl shortcuts in the session.
            // Use the short-hex form — leading-zero hex (0x015b) fails to parse on
            // FreeRDP 3.9+ (a known regression).
            args.append("/kbd:remap:0x15b=0x1d")
        }
        // Sane defaults for a smooth desktop over a LAN.
        args.append(contentsOf: ["+clipboard", "/gfx", "/network:auto"])

        let process = Process()
        if clientPath.contains("/") {
            process.executableURL = URL(fileURLWithPath: clientPath)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [clientPath] + args
        }
        process.environment = ToolLocator.toolEnvironment(backgroundApp: false)

        let errPipe = Pipe()
        process.standardError = errPipe

        final class SafeErrorLines: @unchecked Sendable {
            private let queue = DispatchQueue(label: "com.ayushman.mimicos.rdp.errors")
            private var lines: [String] = []
            func append(_ line: String) {
                queue.async {
                    if self.lines.count > 30 { self.lines.removeFirst() }
                    self.lines.append(line)
                }
            }
            func getJoined() -> String { queue.sync { self.lines.joined(separator: "\n") } }
        }

        let safeLines = SafeErrorLines()
        let fileHandle = errPipe.fileHandleForReading
        Task.detached {
            do {
                for try await line in fileHandle.bytes.lines {
                    safeLines.append(line)
                    print("[freerdp-stderr] \(line)")
                }
            } catch {
                print("[freerdp-stderr] Error reading: \(error)")
            }
        }

        process.terminationHandler = { proc in
            let errText = safeLines.getJoined()
            onExit?(proc.terminationStatus, errText)
        }

        do {
            try process.run()
            self.process = process
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - VNC (macOS Screen Sharing)

    /// Opens a `vnc://` URL with the system handler (Screen Sharing.app). The
    /// username/password can be embedded in the URL; Screen Sharing prompts for
    /// anything missing. We don't own the resulting process.
    private func connectVNC(_ c: Connection,
                            onExit: (@Sendable (Int32, String) -> Void)?) -> Bool {
        // Percent-encode credentials so an `@`, `:` or `/` in a username/password
        // doesn't corrupt the URL's authority component.
        let userInfo = CharacterSet.urlUserAllowed
        var credentials = ""
        if !c.username.isEmpty {
            credentials = c.username.addingPercentEncoding(withAllowedCharacters: userInfo) ?? c.username
            if !c.password.isEmpty {
                let pw = c.password.addingPercentEncoding(withAllowedCharacters: userInfo) ?? c.password
                credentials += ":\(pw)"
            }
            credentials += "@"
        }
        let hostPart = c.port.map { "\(c.host):\($0)" } ?? c.host
        let urlString = "vnc://\(credentials)\(hostPart)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [urlString]
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()   // `open` returns immediately once it hands off
            // We don't own Screen Sharing's process, so report "launched" and let
            // the caller treat VNC as fire-and-forget.
            onExit?(process.terminationStatus, "")
            return process.terminationStatus == 0
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Teardown

    /// Terminates an owned RDP client process. No-op for VNC.
    func stop() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }
}
