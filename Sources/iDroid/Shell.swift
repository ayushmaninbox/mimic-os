import Foundation

/// Result of running a process to completion.
struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

/// Thin async wrapper around `Process` for launching CLI tools.
enum Shell {
    /// Runs an executable to completion and captures its output.
    ///
    /// Homebrew lives outside the SwiftPM process `PATH`, so we always inject a
    /// sensible `PATH` that includes both Homebrew prefixes.
    static func run(_ launchPath: String, _ arguments: [String]) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            let process = Process()

            // If we were handed a bare tool name, run it through the login shell's
            // PATH; otherwise launch the resolved absolute path directly.
            if launchPath.contains("/") {
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [launchPath] + arguments
            }

            var env = ProcessInfo.processInfo.environment
            let extraPath = "/opt/homebrew/bin:/usr/local/bin"
            env["PATH"] = extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { proc in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: ProcessResult(
                    exitCode: proc.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: ProcessResult(
                    exitCode: -1,
                    stdout: "",
                    stderr: "Failed to launch \(launchPath): \(error.localizedDescription)"
                ))
            }
        }
    }

    /// Launches a long-running process (e.g. scrcpy) and returns the handle
    /// immediately so the caller can terminate it later. Output is inherited.
    @discardableResult
    static func launch(_ launchPath: String, _ arguments: [String]) -> Process? {
        let process = Process()
        if launchPath.contains("/") {
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [launchPath] + arguments
        }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env

        do {
            try process.run()
            return process
        } catch {
            return nil
        }
    }
}
