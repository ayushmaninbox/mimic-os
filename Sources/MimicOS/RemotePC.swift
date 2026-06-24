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

    /// The SSH port. gnome-remote-desktop / RDP use 3389; SSH is always 22.
    static let sshPort = 22

    /// Checks whether a TCP port on `host` is open (accepting connections), with a
    /// short timeout. Used to verify gnome-remote-desktop is actually listening on
    /// 3389 after setup, rather than trusting the script's self-report. Uses
    /// `nc -z` (preinstalled on macOS).
    static func isPortOpen(_ host: String, port: Int, timeout: Int = 3) async -> Bool {
        let result = await Shell.run("/usr/bin/nc", ["-z", "-G", "\(timeout)", host, "\(port)"])
        return result.exitCode == 0
    }

    /// Runs a shell script on the remote host **as the logged-in user** (not root),
    /// streaming each output line to `onLine` for a live console. The script can
    /// still elevate individual commands with `sudo -S` — the login password is fed
    /// as the first stdin line, so the first `sudo -S` reads it without a prompt.
    /// Returns the exit code. Needs `sshpass`.
    ///
    /// No PTY (`-tt`) is used: the password travels purely on a plain stdin pipe, so
    /// it can never echo into the captured output. Output still streams reasonably
    /// because the script's `echo` lines flush on their own.
    static func runUserScriptStreaming(host: String, username: String, port: Int?,
                                       password: String, script: String,
                                       onLine: @escaping @MainActor (String) -> Void) async -> Int32 {
        guard sshpassAvailable else {
            await MainActor.run { onLine("error: sshpass not installed — run `brew install sshpass`.") }
            return 127
        }
        let target = username.isEmpty ? host : "\(username)@\(host)"
        var sshArgs = ["-o", "StrictHostKeyChecking=no",
                       "-o", "UserKnownHostsFile=/dev/null",
                       "-o", "ConnectTimeout=10"]
        if let port { sshArgs += ["-p", "\(port)"] }
        // The script is base64-encoded and decoded into a process-substitution FILE
        // that bash executes (`bash <(… | base64 -d)`). That keeps the script off
        // stdin, so stdin is free for the *only* thing we send there — the login
        // password — which the script captures with one `read -r PW` and then feeds
        // to each `sudo -S` via a here-string. (If the script came in on stdin via
        // `bash -s`, bash would run the password line as the script's first
        // command.) base64 also sidesteps every shell-quoting hazard.
        let b64 = Data(script.utf8).base64EncodedString()
        // Force bash for the outer shell too — process substitution `<()` isn't
        // available under dash/sh, which is the default login shell on Debian.
        let remote = "bash -c 'bash <(echo \(b64) | base64 -d)'"
        let stdin = password + "\n"
        return await Shell.runStreaming(ToolLocator.path(for: "sshpass"),
                                        ["-p", password, "ssh"] + sshArgs + [target, remote],
                                        stdin: stdin, onLine: onLine)
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
