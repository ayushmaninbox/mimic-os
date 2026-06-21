import SwiftUI
import AppKit

/// The detail pane for the PC section: a header for the selected computer, a tab
/// bar (Screen / Files / Terminal / Power), and the chosen tab's content. Talks
/// to a Windows or Linux/Mac machine over the network — no phone involved.
struct PCPanelView: View {
    @Environment(AppModel.self) private var model
    @State private var editingHost: RemoteHost?
    @State private var showEditor = false

    var body: some View {
        @Bindable var model = model
        if let host = model.selectedHost {
            VStack(spacing: 0) {
                PCDetailHeader(host: host) {
                    editingHost = host
                    showEditor = true
                }
                Divider()
                PCTabNavBar(selection: $model.selectedPCTab)
                Divider()
                Group {
                    switch model.selectedPCTab {
                    case .screen:   PCScreenTab(host: host)
                    case .files:    PCFilesTab(host: host)
                    case .terminal: PCTerminalTab(host: host)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .sheet(isPresented: $showEditor) {
                RemoteHostEditor(host: editingHost) { updated, password in
                    model.saveRemoteHost(updated, password: password)
                    showEditor = false
                } onCancel: {
                    showEditor = false
                }
            }
        } else {
            ContentUnavailableView {
                Label("No computer selected", systemImage: "desktopcomputer")
            } description: {
                Text("Add a Windows (RDP) or Linux/Mac (VNC) computer from the sidebar, then select it to screen-share, transfer files, open a terminal, or wake it.")
            }
        }
    }
}

// MARK: - Header

private struct PCDetailHeader: View {
    @Environment(AppModel.self) private var model
    let host: RemoteHost
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: host.os.systemImage)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(host.name).font(.title2).bold()
                    Button(action: onEdit) {
                        Image(systemName: "pencil").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit computer")
                }
                HStack(spacing: 8) {
                    Text(host.subtitle).font(.callout).foregroundStyle(.secondary)
                    Text("\(host.os.label) · \(host.proto == .rdp ? "RDP" : "VNC")")
                        .font(.caption2).bold()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                    reachabilityLabel
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    @ViewBuilder
    private var reachabilityLabel: some View {
        if model.hostsBeingPinged.contains(host.id) {
            ProgressView().controlSize(.small)
        } else if let reachable = model.hostReachability[host.id] {
            Label(reachable ? "Online" : "Offline",
                  systemImage: reachable ? "circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(reachable ? .green : .secondary)
        }
    }
}

// MARK: - Tab bar

private struct PCTabNavBar: View {
    @Binding var selection: AppModel.PCTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppModel.PCTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Label(tab.rawValue, systemImage: tab.systemImage)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(selection == tab ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(selection == tab ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

// MARK: - Screen tab (RDP / VNC)

private struct PCScreenTab: View {
    @Environment(AppModel.self) private var model
    let host: RemoteHost

    private var isConnected: Bool { model.connectedRemoteHostID == host.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PCSectionCard(title: "Screen sharing", systemImage: "display") {
                    HStack(spacing: 10) {
                        if isConnected {
                            Button("Disconnect", role: .destructive) {
                                model.disconnectRemoteHost()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                model.connectRemoteHost(host)
                            } label: {
                                Label("Start screen sharing", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    if host.proto == .rdp {
                        Toggle("Open in fullscreen", isOn: Bindable(model).rdpFullscreen)
                            .toggleStyle(.checkbox)
                        Label("In the RDP window, press ⌃⌥⏎ (Ctrl+Alt+Enter) to toggle fullscreen. Windowed mode scales the remote screen to fit — drag the window edges to resize.",
                              systemImage: "rectangle.expand.vertical")
                            .font(.caption).foregroundStyle(.secondary)

                        Toggle("Use ⌘ (Command) as Ctrl in the session", isOn: Bindable(model).rdpCommandAsCtrl)
                            .toggleStyle(.checkbox)
                        Text("Maps the Mac's Command key to Ctrl inside RDP, so ⌘C / ⌘V / ⌘Tab work like Mac shortcuts. Turn off to use Command as the Windows key instead.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Text(screenHint)
                        .font(.caption).foregroundStyle(.secondary)

                    if host.proto == .rdp && !model.freeRDPInstalled {
                        FreeRDPInstallNote()
                    }
                }

                if host.os == .linux {
                    PCSectionCard(title: "Set up the Linux side", systemImage: "wrench.and.screwdriver") {
                        if host.proto == .rdp {
                            LinuxSetup.remoteDesktop(host)
                        } else {
                            LinuxSetup.vnc(host)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var screenHint: String {
        if host.proto == .vnc {
            return "Opens \(host.name) over VNC in the built-in Screen Sharing app. The remote machine needs a VNC server / Screen Sharing enabled."
        }
        if model.freeRDPInstalled {
            return "Opens \(host.name) over RDP in a native FreeRDP window you can resize and close. The remote screen appears in its own window."
        }
        return "Opens \(host.name) over RDP. Install FreeRDP below for a built-in window; otherwise MimicOS hands the connection to any RDP client you have installed."
    }
}

/// Shown when RDP is selected but no FreeRDP client is installed — points the
/// user at the one-line Homebrew install that gives the best experience.
private struct FreeRDPInstallNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Install FreeRDP for the best RDP experience", systemImage: "arrow.down.circle")
                .font(.caption).bold()
            Text("Run this in Terminal — it's a free, native client (no XQuartz needed):")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text("brew install freerdp")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install freerdp", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy command")
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.top, 4)
    }
}

// MARK: - Files tab (SMB via Finder)

private struct PCFilesTab: View {
    @Environment(AppModel.self) private var model
    let host: RemoteHost

    /// SMB is the one protocol Finder mounts natively on every OS, so the setup
    /// note is per-OS (each enables SMB differently).
    private var filesHint: String {
        let base = "Mounts \(host.name) in Finder over SMB, where you can drag files both ways. Finder prompts for credentials. "
        switch host.os {
        case .windows:
            return base + "Needs File and Printer Sharing enabled on the PC, and the folder shared."
        case .linux:
            return base + "Needs Samba on the Linux box: `sudo apt install samba`, then add a share in /etc/samba/smb.conf and set a Samba password (`sudo smbpasswd -a \(host.username.isEmpty ? "you" : host.username)`)."
        case .mac:
            return base + "Needs File Sharing on the Mac (System Settings ▸ General ▸ Sharing ▸ File Sharing) with SMB enabled."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PCSectionCard(title: "File transfer", systemImage: "folder") {
                    Button {
                        Task { await model.openFiles(host) }
                    } label: {
                        Label("Open files in Finder", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                    Text(filesHint)
                        .font(.caption).foregroundStyle(.secondary)
                }

                if host.os == .linux {
                    PCSectionCard(title: "Set up the Linux side", systemImage: "wrench.and.screwdriver") {
                        LinuxSetup.fileSharing(host)
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Terminal tab (SSH)

private struct PCTerminalTab: View {
    @Environment(AppModel.self) private var model
    let host: RemoteHost

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PCSectionCard(title: "Remote terminal", systemImage: "terminal") {
                    Button {
                        Task { await model.openSSH(host) }
                    } label: {
                        Label("Open SSH in Terminal", systemImage: "terminal.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Text(host.username.isEmpty
                         ? "Opens Terminal.app and runs `ssh \(host.host)`. Add a username to this computer to connect as a specific user. The PC needs an SSH server running (Windows: OpenSSH Server; Linux/Mac: enable Remote Login)."
                         : "Opens Terminal.app and runs `ssh \(host.username)@\(host.host)`. The PC needs an SSH server running (Windows: OpenSSH Server; Linux/Mac: enable Remote Login).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if host.os == .linux {
                    PCSectionCard(title: "Set up the Linux side", systemImage: "wrench.and.screwdriver") {
                        LinuxSetup.ssh(host)
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Shared bits

private struct PCSectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Add / edit computer

/// Add / edit form for a remote computer, shown as a sheet. Used by both the PC
/// sidebar (add) and the PC header (edit).
struct RemoteHostEditor: View {
    let host: RemoteHost?
    let onSave: (RemoteHost, String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var hostAddress: String
    @State private var portText: String
    @State private var username: String
    @State private var password: String
    @State private var os: RemoteOS
    @State private var proto: RemoteDesktop.Kind
    @State private var hadStoredPassword: Bool

    init(host: RemoteHost?,
         onSave: @escaping (RemoteHost, String) -> Void,
         onCancel: @escaping () -> Void) {
        self.host = host
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: host?.name ?? "")
        _hostAddress = State(initialValue: host?.host ?? "")
        _portText = State(initialValue: host?.port.map(String.init) ?? "")
        _username = State(initialValue: host?.username ?? "")
        _password = State(initialValue: "")
        _os = State(initialValue: host?.os ?? .windows)
        _proto = State(initialValue: host?.proto ?? .rdp)
        _hadStoredPassword = State(initialValue: host.map { SecretStore.hasRemotePassword(hostID: $0.idString) } ?? false)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !hostAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// OS + protocol-aware setup guidance shown under the form.
    private var protocolHint: String {
        switch (os, proto) {
        case (.windows, .rdp):
            return "Connects over RDP to a Windows PC with Remote Desktop enabled (Settings ▸ System ▸ Remote Desktop). Best with FreeRDP installed (`brew install freerdp`)."
        case (.windows, .vnc):
            return "Connects over VNC to a Windows PC running a VNC server (e.g. TightVNC, UltraVNC, RealVNC). Opens in the built-in Screen Sharing app."
        case (.linux, .rdp):
            return "Connects over RDP to a Linux machine running an RDP server (xrdp — `sudo apt install xrdp`). Best with FreeRDP installed on this Mac (`brew install freerdp`)."
        case (.linux, .vnc):
            return "Connects over VNC to a Linux machine running a VNC server (e.g. TigerVNC, x11vnc, or the desktop's built-in screen sharing). Opens in the built-in Screen Sharing app."
        case (.mac, .vnc):
            return "Connects over VNC to a Mac with Screen Sharing on (System Settings ▸ General ▸ Sharing ▸ Screen Sharing). Opens in the built-in Screen Sharing app."
        case (.mac, .rdp):
            return "Connects over RDP to a Mac running an RDP server (uncommon — most Macs use VNC/Screen Sharing). Best with FreeRDP installed (`brew install freerdp`)."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(host == nil ? "Add computer" : "Edit computer")
                .font(.title3).bold()
                .padding(.horizontal, 20).padding(.top, 20)

            Form {
                Picker("Operating system", selection: $os) {
                    ForEach(RemoteOS.allCases) { o in
                        Label(o.label, systemImage: o.systemImage).tag(o)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: os) { _, newOS in
                    // Snap to the OS's usual protocol when adding (so picking
                    // Windows defaults to RDP, Linux/Mac to VNC). On edit, respect
                    // the user's existing choice and don't override.
                    if host == nil { proto = newOS.defaultProtocol }
                }

                Picker("Screen-share via", selection: $proto) {
                    ForEach(RemoteDesktop.Kind.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Name", text: $name, prompt: Text(os == .windows ? "Work PC" : os == .linux ? "Home Server" : "iMac"))
                TextField("Host / IP", text: $hostAddress, prompt: Text("192.168.1.50"))
                TextField("Port", text: $portText,
                          prompt: Text("Default: \(proto.defaultPort)"))
                TextField("Username", text: $username,
                          prompt: Text(proto == .rdp ? "Administrator" : "Optional"))
                SecureField("Password",
                            text: $password,
                            prompt: Text(hadStoredPassword ? "•••••• (saved — leave blank to keep)" : "Optional"))
            }
            .formStyle(.grouped)

            Text(protocolHint)
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button(host == nil ? "Add" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding(20)
        }
        .frame(width: 460)
    }

    private func save() {
        var result = host ?? RemoteHost(name: "", host: "", username: "", os: os, proto: proto)
        result.name = name.trimmingCharacters(in: .whitespaces)
        result.host = hostAddress.trimmingCharacters(in: .whitespaces)
        result.port = Int(portText.trimmingCharacters(in: .whitespaces))
        result.username = username.trimmingCharacters(in: .whitespaces)
        result.os = os
        result.proto = proto
        onSave(result, password)
    }
}
