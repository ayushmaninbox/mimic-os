import Foundation

/// Finds the `adb` and `scrcpy` executables.
///
/// Resolution order:
///   1. Bundled inside the app at `Resources/tools/` (the shipping path).
///   2. Common Homebrew locations (handy during development).
///   3. Bare name, resolved against the process `PATH`.
///
/// Phase 1 leans on a Homebrew install for development; bundling the binaries
/// into the `.app` is a packaging step we do before release.
enum ToolLocator {
    /// Directories we probe for the binaries, in priority order.
    private static var searchDirectories: [URL] {
        var dirs: [URL] = []

        // 1. Bundled tools, relative to the running executable.
        //    <App>.app/Contents/MacOS/MimicOS  ->  .../Resources/tools
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
        if let exeDir {
            dirs.append(exeDir.appendingPathComponent("../Resources/tools").standardizedFileURL)
        }
        // Also probe a `tools` dir next to the executable (SwiftPM dev layout).
        if let exeDir {
            dirs.append(exeDir.appendingPathComponent("tools"))
        }

        // 2. Homebrew (Apple Silicon and Intel locations).
        dirs.append(URL(fileURLWithPath: "/opt/homebrew/bin"))
        dirs.append(URL(fileURLWithPath: "/usr/local/bin"))

        return dirs
    }

    /// Returns the resolved path for a tool, or just its name if not found
    /// (so the process launcher can fall back to `PATH`).
    static func path(for tool: String) -> String {
        for dir in searchDirectories {
            let candidate = dir.appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return tool
    }

    /// True when we could resolve an actual file on disk for the tool.
    static func isAvailable(_ tool: String) -> Bool {
        path(for: tool) != tool
    }

    static var adb: String { path(for: "adb") }
    static var scrcpy: String { path(for: "scrcpy") }

    /// Path to a bundled `scrcpy-server`, if present next to the binaries.
    static var bundledServerPath: String? {
        for dir in searchDirectories {
            let candidate = dir.appendingPathComponent("scrcpy-server")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    /// Environment to launch the tools with: extends PATH and, when we ship a
    /// bundled scrcpy-server, points scrcpy at it (and at the bundled adb) so
    /// the app works on machines with no Homebrew install.
    static func toolEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        if let server = bundledServerPath { env["SCRCPY_SERVER_PATH"] = server }
        if isAvailable("adb") { env["ADB"] = adb }   // scrcpy uses $ADB if set
        env["SDL_MAC_BACKGROUND_APP"] = "1"          // Prevents duplicate scrcpy icon in Dock
        return env
    }
}
