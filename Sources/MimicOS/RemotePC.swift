import Foundation

/// Network helpers for the PC section that don't go through an external client:
/// reachability (ping), SSH-terminal launch, and file transfer hand-off. Kept
/// separate from `RemoteDesktop` (which owns the screen-share clients).
enum RemotePC {

    // MARK: - Reachability (ping)

    /// Pings a host once with a short timeout. Returns true if it replied.
    static func ping(_ host: String) async -> Bool {
        // `-c 1` one packet, `-t 2` 2-second TTL/timeout (macOS ping uses -t for
        // timeout-to-give-up in seconds when combined with -c).
        let result = await Shell.run("/sbin/ping", ["-c", "1", "-t", "2", host])
        return result.exitCode == 0
    }

    // MARK: - SSH terminal

    /// Opens Terminal.app with an SSH session to `user@host`. Uses AppleScript so
    /// the connection runs in a real interactive terminal (password prompts,
    /// host-key acceptance, etc. all work). Port is optional.
    @discardableResult
    static func openSSH(host: String, username: String, port: Int?) async -> Bool {
        var command = "ssh "
        if let port { command += "-p \(port) " }
        let target = username.isEmpty ? host : "\(username)@\(host)"
        command += target

        // Escape for embedding in an AppleScript string literal.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        let result = await Shell.run("/usr/bin/osascript", ["-e", script])
        return result.succeeded
    }

    // MARK: - File transfer hand-off

    /// Opens the PC's file share in Finder. For Windows hosts this is an SMB
    /// share (`smb://`); for Linux/Mac an SFTP mount (`ftp`/`smb` depending on
    /// what's running). Finder prompts for credentials. Returns true if `open`
    /// launched.
    @discardableResult
    static func openFileShare(scheme: String, host: String, username: String) async -> Bool {
        var credentials = ""
        if !username.isEmpty {
            let enc = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
            credentials = "\(enc)@"
        }
        let url = "\(scheme)://\(credentials)\(host)"
        let result = await Shell.run("/usr/bin/open", [url])
        return result.succeeded
    }
}
