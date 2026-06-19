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
        var useHIDKeyboard: Bool = true
        /// Where the phone's audio should play while mirroring.
        var audio: AudioRoute = .mac

        func asArguments() -> [String] {
            var args: [String] = []
            if turnScreenOff { args.append("--turn-screen-off") }
            if stayAwake { args.append("--stay-awake") }
            if let maxSize { args.append(contentsOf: ["--max-size", "\(maxSize)"]) }
            if let bitRateMbps { args.append(contentsOf: ["--video-bit-rate", "\(bitRateMbps)M"]) }
            if useHIDKeyboard { args.append("--keyboard=uhid") }
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

    /// True while a mirror session is running.
    var isRunning: Bool { process?.isRunning ?? false }

    /// Starts a mirror session for the given device serial. `onExit` fires when
    /// scrcpy terminates for any reason (including the user closing its window).
    @discardableResult
    func start(serial: String, options: Options = Options(), onExit: (@Sendable () -> Void)? = nil) -> Bool {
        stop() // never run two sessions for the same controller
        let args = ["-s", serial] + options.asArguments()
        let launched = Shell.launch(ToolLocator.scrcpy, args)
        launched?.terminationHandler = { _ in onExit?() }
        process = launched
        return launched != nil
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
            }
            self.process = nil
        }
    }

    deinit { stop() }
}
