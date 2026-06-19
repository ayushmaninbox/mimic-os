import Foundation

/// Launches and manages scrcpy mirroring sessions.
///
/// scrcpy opens its own native window for the mirror; iDroid's job is to launch
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

        func asArguments() -> [String] {
            var args: [String] = []
            if turnScreenOff { args.append("--turn-screen-off") }
            if stayAwake { args.append("--stay-awake") }
            if let maxSize { args.append(contentsOf: ["--max-size", "\(maxSize)"]) }
            if let bitRateMbps { args.append(contentsOf: ["--video-bit-rate", "\(bitRateMbps)M"]) }
            return args
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

    /// Terminates the running mirror session, if any.
    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
    }

    deinit { stop() }
}
