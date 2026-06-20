import Foundation

/// Result of running a process to completion.
struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

/// Like `ProcessResult` but keeps stdout as raw bytes — needed for binary output
/// such as `screencap -p` PNG data, which UTF-8 decoding would corrupt.
struct ProcessDataResult {
    let exitCode: Int32
    let stdout: Data
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

            process.environment = ToolLocator.toolEnvironment()

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

    /// Like `run`, but keeps stdout as raw `Data` for binary output (e.g. a PNG
    /// streamed from `screencap -p`). Reads stdout on a background pipe so large
    /// captures don't deadlock the fixed-size pipe buffer.
    static func runData(_ launchPath: String, _ arguments: [String]) async -> ProcessDataResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            if launchPath.contains("/") {
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [launchPath] + arguments
            }
            process.environment = ToolLocator.toolEnvironment()

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Drain stdout concurrently to avoid filling the OS pipe buffer on
            // big images, which would otherwise stall the child process.
            final class Box: @unchecked Sendable { var data = Data() }
            let box = Box()
            let outHandle = outPipe.fileHandleForReading
            let drain = DispatchQueue(label: "com.ayushman.mimicos.shell.runData")
            drain.async { box.data = outHandle.readDataToEndOfFile() }

            process.terminationHandler = { proc in
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                drain.sync {}   // ensure the stdout read finished
                continuation.resume(returning: ProcessDataResult(
                    exitCode: proc.terminationStatus,
                    stdout: box.data,
                    stderr: String(decoding: errData, as: UTF8.self)))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: ProcessDataResult(
                    exitCode: -1, stdout: Data(),
                    stderr: "Failed to launch \(launchPath): \(error.localizedDescription)"))
            }
        }
    }

    /// Like `run`, but hands the live `Process` to `onStart` so the caller can
    /// terminate it (e.g. to cancel a file transfer). Resolves when it exits.
    static func runCancellable(_ launchPath: String, _ arguments: [String],
                               onStart: @escaping @Sendable (Process) -> Void) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            if launchPath.contains("/") {
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [launchPath] + arguments
            }
            process.environment = ToolLocator.toolEnvironment()

            let outPipe = Pipe(); let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.terminationHandler = { proc in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: ProcessResult(
                    exitCode: proc.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)))
            }
            do {
                try process.run()
                onStart(process)
            } catch {
                continuation.resume(returning: ProcessResult(
                    exitCode: -1, stdout: "",
                    stderr: "Failed to launch \(launchPath): \(error.localizedDescription)"))
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

        process.environment = ToolLocator.toolEnvironment()

        do {
            try process.run()
            return process
        } catch {
            return nil
        }
    }
}
