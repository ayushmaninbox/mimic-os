import SwiftUI
import AppKit

// MARK: - Copyable command block

/// A single shell command (or multi-line snippet) shown in monospace with a
/// one-tap copy button. Run these on the remote machine — e.g. over SSH from the
/// Terminal tab.
struct CopyableCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .help(copied ? "Copied" : "Copy command")
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A collapsible setup guide: a title, an intro line, and a series of numbered
/// steps each with a copyable command. Used contextually in the PC tabs to fix
/// things on the remote (Linux) machine from the Mac.
struct SetupGuide: View {
    let title: String
    let systemImage: String
    let intro: String
    let steps: [Step]
    @State private var expanded = false

    struct Step: Identifiable {
        let id = UUID()
        let text: String
        let command: String?
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text(intro)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(idx + 1)")
                                .font(.caption2).bold()
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(.tint))
                                .foregroundStyle(.white)
                            Text(.init(step.text)).font(.caption)
                            Spacer(minLength: 0)
                        }
                        if let command = step.command {
                            CopyableCommand(command: command)
                                .padding(.leading, 26)
                        }
                    }
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline).bold()
        }
    }
}

// MARK: - Per-feature Linux guides

/// The setup guides we offer for Linux hosts. Each builds its steps from the
/// host (so the username is filled into the commands).
enum LinuxSetup {
    /// Samba / SMB file sharing — fixes "Open files in Finder".
    static func fileSharing(_ host: RemoteHost) -> SetupGuide {
        let user = host.username.isEmpty ? "$USER" : host.username
        return SetupGuide(
            title: "Set up file sharing on Linux (Samba)",
            systemImage: "folder.badge.gearshape",
            intro: "Run these on the Ubuntu/Linux machine (e.g. in the Terminal tab's SSH session) so Finder can mount it over SMB.",
            steps: [
                .init(text: "Install Samba.",
                      command: "sudo apt update && sudo apt install -y samba"),
                .init(text: "Share your home folder — append a share block to the Samba config.",
                      command: """
                      sudo tee -a /etc/samba/smb.conf >/dev/null <<'EOF'

                      [\(user)]
                         path = /home/\(user)
                         browseable = yes
                         read only = no
                         valid users = \(user)
                      EOF
                      """),
                .init(text: "Set a Samba password (separate from the login password) — this is what Finder will ask for.",
                      command: "sudo smbpasswd -a \(user)"),
                .init(text: "Restart Samba and enable it at boot.",
                      command: "sudo systemctl restart smbd && sudo systemctl enable smbd"),
                .init(text: "Allow Samba through the firewall (if ufw is on).",
                      command: "sudo ufw allow samba"),
                .init(text: "Back in MimicOS, hit **Open files in Finder** — Finder asks for the Samba password above.",
                      command: nil),
            ])
    }

    /// xrdp — fixes / enables RDP screen-share, including audio redirection.
    static func remoteDesktop(_ host: RemoteHost) -> SetupGuide {
        let port = host.port ?? 3389
        return SetupGuide(
            title: "Set up Remote Desktop on Linux (xrdp)",
            systemImage: "display",
            intro: "Run these on the Linux machine so RDP screen-share works. Note: log out of the desktop session first — xrdp can't attach to an already-logged-in GNOME session.",
            steps: [
                .init(text: "Install xrdp.",
                      command: "sudo apt update && sudo apt install -y xrdp"),
                .init(text: "Enable and start it.",
                      command: "sudo systemctl enable --now xrdp"),
                .init(text: "Open the RDP port in the firewall.",
                      command: "sudo ufw allow \(port)/tcp"),
                .init(text: "Check it's listening.",
                      command: "sudo systemctl status xrdp --no-pager"),
            ])
    }

    /// OpenSSH server — enables the Terminal tab and SFTP.
    static func ssh(_ host: RemoteHost) -> SetupGuide {
        SetupGuide(
            title: "Set up SSH on Linux (Remote Login)",
            systemImage: "terminal",
            intro: "Run these on the Linux machine so the Terminal tab (and command-line file transfer) can connect.",
            steps: [
                .init(text: "Install the OpenSSH server.",
                      command: "sudo apt update && sudo apt install -y openssh-server"),
                .init(text: "Enable and start it.",
                      command: "sudo systemctl enable --now ssh"),
                .init(text: "Allow SSH through the firewall.",
                      command: "sudo ufw allow ssh"),
            ])
    }

    /// VNC server — alternative screen-share to RDP.
    static func vnc(_ host: RemoteHost) -> SetupGuide {
        SetupGuide(
            title: "Set up VNC on Linux",
            systemImage: "rectangle.on.rectangle",
            intro: "Run these on the Linux machine to share the current desktop over VNC. (Or, on GNOME, just turn on Settings ▸ Sharing ▸ Remote Desktop / Screen Sharing.)",
            steps: [
                .init(text: "Install x11vnc.",
                      command: "sudo apt update && sudo apt install -y x11vnc"),
                .init(text: "Set a VNC password.",
                      command: "x11vnc -storepasswd"),
                .init(text: "Share the active display (run after logging in to the desktop).",
                      command: "x11vnc -usepw -display :0 -forever -shared"),
                .init(text: "Allow the VNC port through the firewall.",
                      command: "sudo ufw allow 5900/tcp"),
            ])
    }
}
