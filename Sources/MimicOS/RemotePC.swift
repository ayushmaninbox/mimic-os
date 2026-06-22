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

    // MARK: - SSH command execution (non-interactive)

    /// Whether `sshpass` is installed (lets us pass a password to ssh/scp
    /// non-interactively). Without it, SSH commands rely on key-based auth.
    static var sshpassAvailable: Bool { ToolLocator.isAvailable("sshpass") }

    /// Runs a command over SSH on the remote host and returns the result. Uses
    /// `sshpass` with the given password when available; otherwise relies on SSH
    /// keys (BatchMode, so it fails fast instead of hanging on a prompt).
    static func runSSH(host: String, username: String, port: Int?, password: String,
                       command: String) async -> ProcessResult {
        let target = username.isEmpty ? host : "\(username)@\(host)"
        var sshArgs = ["-o", "StrictHostKeyChecking=no",
                       "-o", "UserKnownHostsFile=/dev/null"]
        if let port { sshArgs += ["-p", "\(port)"] }
        sshArgs += [target, command]

        if sshpassAvailable, !password.isEmpty {
            return await Shell.run(ToolLocator.path(for: "sshpass"),
                                   ["-p", password, "ssh"] + sshArgs)
        } else {
            // No sshpass: force key-based, fail fast if no key is set up.
            return await Shell.run("/usr/bin/ssh", ["-o", "BatchMode=yes"] + sshArgs)
        }
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
        var url = "\(scheme)://\(credentials)\(host)"
        if scheme == "smb" && !username.isEmpty {
            url += "/\(username)"
        }
        let result = await Shell.run("/usr/bin/open", [url])
        return result.succeeded
    }
}
