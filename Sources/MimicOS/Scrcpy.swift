import Foundation

/// Launches and manages scrcpy mirroring sessions.
///
/// scrcpy opens its own native window for the mirror; MimicOS's job is to launch
/// it with the right flags and keep track of the running process so it can be
/// stopped. (Embedding scrcpy's video directly into a SwiftUI view is a Phase 2+
/// effort — it means consuming scrcpy-server's H.264 stream ourselves.)
final class Scrcpy {
    /// Options that map onto scrcpy command-line flags.
    struct Options {
        /// Keep the phone's physical screen black while mirroring (the
        /// "sleeping phone" experience). Maps to `--turn-screen-off`.
        var turnScreenOff: Bool = true
        /// Keep the device awake while plugged in. Maps to `--stay-awake`.
        var stayAwake: Bool = true
        /// Cap the resolution to keep latency low on Wi-Fi. Maps to `--max-size`.
        var maxSize: Int? = nil
        /// Bitrate in Mbps. Maps to `--video-bit-rate`.
        var bitRateMbps: Int? = nil
        /// Simulate a physical HID keyboard so Mac-style text editing works:
        /// ⌘A/⌘C/⌘V/⌘X, ⇧+Enter for a newline, Enter to submit, ⌥/⇧+arrows for
        /// word/selection movement. Default `sdk` injection lacks these.
        var useHIDKeyboard: Bool = false
        /// Where the phone's audio should play while mirroring.
        var audio: AudioRoute = .mac
        /// Keep scrcpy's mirror window above other windows. Maps to
        /// `--always-on-top`. The "pin across all spaces / lock frame" behaviour
        /// is layered on top via the Accessibility API in `PhoneWindowPinner`.
        var alwaysOnTop: Bool = false
        /// A stable window title so we can find scrcpy's window via the
        /// Accessibility API for pinning. Maps to `--window-title`.
        var windowTitle: String? = nil

        func asArguments() -> [String] {
            var args: [String] = []
            if turnScreenOff { args.append("--turn-screen-off") }
            if stayAwake { args.append("--stay-awake") }
            if let maxSize { args.append(contentsOf: ["--max-size", "\(maxSize)"]) }
            if let bitRateMbps { args.append(contentsOf: ["--video-bit-rate", "\(bitRateMbps)M"]) }
            if useHIDKeyboard { args.append("--keyboard=uhid") }
            if alwaysOnTop { args.append("--always-on-top") }
            if let windowTitle { args.append(contentsOf: ["--window-title", windowTitle]) }
            args.append(contentsOf: audio.arguments)
            return args
        }
    }

    /// Where phone audio plays during mirroring. The phone's own routing
    /// (speaker / Bluetooth / wired) is the phone's choice — these decide
    /// whether the Mac also receives it and whether the phone keeps playing.
    enum AudioRoute: String, CaseIterable, Identifiable {
        case mac        // forward to the Mac, phone goes silent
        case phone      // keep audio on the phone (its own speaker/BT/wired)
        case both       // play on the Mac AND keep playing on the phone

        var id: String { rawValue }
        var label: String {
            switch self {
            case .mac: return "This Mac"
            case .phone: return "Phone / its connected device"
            case .both: return "Both (Mac + phone)"
            }
        }
        var arguments: [String] {
            switch self {
            case .mac:   return ["--audio-source=output"]
            case .phone: return ["--no-audio"]
            case .both:  return ["--audio-source=playback", "--audio-dup"]
            }
        }
    }

    static var isInstalled: Bool { ToolLocator.isAvailable("scrcpy") }

    private var process: Process?
    var lastError: String = ""

    /// True while a mirror session is running.
    var isRunning: Bool { process?.isRunning ?? false }

    /// Starts a mirror session for the given device serial. `onExit` fires when
    /// scrcpy terminates for any reason, passing the exit status and collected stderr.
    @discardableResult
    func start(serial: String, options: Options = Options(), onExit: (@Sendable (Int32, String) -> Void)? = nil) -> Bool {
        stop() // never run two sessions for the same controller
        lastError = ""
        let args = ["-s", serial] + options.asArguments()
        
        let process = Process()
        let launchPath = ToolLocator.scrcpy
        if launchPath.contains("/") {
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [launchPath] + args
        }
        process.environment = ToolLocator.toolEnvironment()
        
        let errPipe = Pipe()
        process.standardError = errPipe
        
        final class SafeErrorLines: @unchecked Sendable {
            private let queue = DispatchQueue(label: "com.ayushman.mimicos.scrcpy.errors")
            private var lines: [String] = []
            func append(_ line: String) {
                queue.async {
                    if self.lines.count > 30 { self.lines.removeFirst() }
                    self.lines.append(line)
                }
            }
            func getJoined() -> String {
                queue.sync { self.lines.joined(separator: "\n") }
            }
        }
        
        let safeLines = SafeErrorLines()
        let fileHandle = errPipe.fileHandleForReading
        Task.detached {
            do {
                for try await line in fileHandle.bytes.lines {
                    safeLines.append(line)
                    print("[scrcpy-stderr] \(line)")
                }
            } catch {
                print("[scrcpy-stderr] Error reading: \(error)")
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

    /// Starts a headless mirror session purely for background clipboard synchronization.
    @discardableResult
    func startHeadless(serial: String, onExit: (@Sendable () -> Void)? = nil) -> Bool {
        stop()
        let args = ["-s", serial, "--no-video", "--no-audio", "--no-window"]
        let launched = Shell.launch(ToolLocator.scrcpy, args)
        launched?.terminationHandler = { _ in onExit?() }
        process = launched
        return launched != nil
    }

    /// Terminates the running mirror session, if any.
    func stop() {
        if let process {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            self.process = nil
        }
    }

    deinit { stop() }
}
