import SwiftUI
import AppKit

struct HostEditorState: Identifiable {
    let id = UUID()
    let host: RemoteHost?
}

/// The detail pane for the PC section: a header for the selected computer, a tab
/// bar (Screen / Files / Terminal / Power), and the chosen tab's content. Talks
/// to a Windows or Linux/Mac machine over the network — no phone involved.
struct PCPanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if let host = model.selectedHost {
                VStack(spacing: 0) {
                    PCDetailHeader(host: host) {
                        model.selectedPCTab = .settings
                    }
                    Divider()
                    PCTabNavBar(selection: $model.selectedPCTab)
                    Divider()
                    Group {
                        switch model.selectedPCTab {
                        case .screen:   PCScreenTab(host: host)
                        case .files:    PCFilesTab(host: host)
                        case .terminal: PCTerminalTab(host: host)
                        case .settings: PCSettingsTab(host: host)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView {
                    Label("No computer selected", systemImage: "desktopcomputer")
                } description: {
                    Text("Add a Windows (RDP) or Linux/Mac (VNC) computer from the sidebar, then select it to screen-share, transfer files, open a terminal, or wake it.")
                }
            }
        }
        // Wrong / missing password → ask for the correct one, then reconnect.
        .sheet(item: $model.passwordReentryHost) { host in
            PasswordReentrySheet(host: host) { newPassword in
                model.retryWithNewPassword(host, password: newPassword)
            } onCancel: {
                model.passwordReentryHost = nil
            }
        }
    }
}

/// Prompt shown when a saved RDP password is wrong or missing. Re-uses the same
/// styling as the rename sheet for consistency.
private struct PasswordReentrySheet: View {
    let host: RemoteHost
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Password for \(host.name)").font(.headline)
            Text("The saved password didn't work. Enter the correct one — it'll be stored securely and unlocked with Touch ID next time.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if !password.isEmpty { onSubmit(password) } }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { onSubmit(password) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }
}

// MARK: - Header

private struct PCDetailHeader: View {
    @Environment(AppModel.self) private var model
    let host: RemoteHost
    let onEdit: () -> Void

    private var isConnected: Bool { model.connectedRemoteHostID == host.id }
    private var reachable: Bool? { model.hostReachability[host.id] }

    private var iconColor: Color {
        if isConnected { return .green }
        switch reachable {
        case .some(true):  return .green
        case .some(false): return .secondary
        case .none:        return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: host.os.systemImage)
                .font(.system(size: 30))
                .foregroundStyle(iconColor)
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
            
            HStack(spacing: 10) {
                if isConnected {
                    Button {
                        model.disconnectRemoteHost()
                    } label: {
                        Label("Disconnect", systemImage: "wifi.slash")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        Task { await model.pingHost(host) }
                    } label: {
                        Label("Check Connection", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.hostsBeingPinged.contains(host.id))
                }
                
                Button(role: .destructive) {
                    model.deleteRemoteHost(host)
                } label: {
                    Label("Forget", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    @ViewBuilder
    private var reachabilityLabel: some View {
        if model.hostsBeingPinged.contains(host.id) {
            ProgressView().controlSize(.small)
        } else if let reachable = model.hostReachability[host.id] {
            Text(reachable ? "Online" : "Offline")
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
    @State private var confirmReset = false

    private var isConnected: Bool { model.connectedRemoteHostID == host.id }
    private var isLinux: Bool { host.os == .linux }
    private var setUpBefore: Bool { model.hasLinuxSetup(host) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isLinux {
                    linuxSetupCard
                }

                PCSectionCard(title: "Screen sharing", systemImage: "display") {
                    HStack(spacing: 10) {
                        if isConnected {
                            Button("Disconnect", role: .destructive) {
                                model.disconnectRemoteHost()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                Task { await model.userConnectRemoteHost(host) }
                            } label: {
                                Label("Start screen sharing", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            // On Linux, gate the first connect on setup having run;
                            // afterwards it's always available.
                            .disabled(isLinux && !setUpBefore)
                        }
                    }

                    if host.proto == .rdp {
                        Label("In the RDP window, press ⌃⌥⏎ (Ctrl+Alt+Enter) to toggle fullscreen. Windowed mode scales the remote screen to fit — drag the window edges to resize.",
                              systemImage: "rectangle.expand.vertical")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Text(screenHint)
                        .font(.caption).foregroundStyle(.secondary)

                    if host.proto == .rdp && !model.freeRDPInstalled {
                        FreeRDPInstallNote()
                    }
                }
            }
            .padding(20)
        }
    }

    /// The one-click setup card: configures gnome-remote-desktop over SSH, shows a
    /// live console, and (after the first setup) an always-visible Reset button.
    private var linuxSetupCard: some View {
        PCSectionCard(title: "Set up the Linux side", systemImage: "wand.and.stars") {
            Text("One click configures GNOME Remote Desktop on the Ubuntu machine over SSH so RDP shows your real desktop. Uses the saved login password.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !RemotePC.sshpassAvailable {
                sshpassNote
            } else {
                HStack(spacing: 10) {
                    if model.isSettingUpLinux {
                        ProgressView().controlSize(.small)
                        Text("Working…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button {
                            Task { await model.setupLinux(host) }
                        } label: {
                            Label(setUpBefore ? "Re-run setup" : "Set up everything (one click)",
                                  systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)

                        if setUpBefore {
                            Button(role: .destructive) {
                                confirmReset = true
                            } label: {
                                Label("Reset connection", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            // Live setup/reset progress (in-app, not a Mac terminal).
            if model.isSettingUpLinux || !model.setupLog.isEmpty {
                ConsoleLogView(lines: model.setupLog, running: model.isSettingUpLinux, title: "Linux setup")
            } else if isConnected && !model.remoteTerminalLog.isEmpty {
                ConsoleLogView(lines: model.remoteTerminalLog, running: model.isStreamingRemoteTerminal, title: "Linux status")
            }
        }
        .confirmationDialog("Reset \(host.name)'s connection?",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset & reconfigure", role: .destructive) {
                Task { await model.setupLinux(host, reset: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears the existing GNOME Remote Desktop credentials/config (and disables xrdp if present), then sets it up again from scratch.")
        }
    }

    private var sshpassNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("One-click setup needs `sshpass`", systemImage: "exclamationmark.triangle")
                .font(.caption).bold().foregroundStyle(.orange)
            HStack {
                Text("brew install sshpass")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install sshpass", forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy command")
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
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

/// A small terminal-style view that shows live command output, auto-scrolling to
/// the newest line. Used for the one-click setup console and the status readout.
private struct ConsoleLogView: View {
    let lines: [String]
    let running: Bool
    var title: String = "Output"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill").font(.caption2)
                Text(title).font(.caption2).bold()
                Spacer()
                if running { ProgressView().controlSize(.small) }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary.opacity(0.5))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 180)
                .onChange(of: lines.count) { _, count in
                    withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .padding(.top, 4)
    }

    private func color(for line: String) -> Color {
        let l = line.lowercased()
        if line.contains("✓") || line.contains("_OK") { return .green }
        if line.contains("✗") || l.contains("error") || l.contains("fail") { return .red }
        if line.contains("⚠") { return .orange }
        if line.hasPrefix(">>>") || line.hasPrefix("$") { return .cyan }
        return Color(white: 0.85)
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
        let isSetupConfirmed = Binding<Bool>(
            get: { model.isSetupConfirmed(for: host, tab: .files) },
            set: { model.setSetupConfirmed($0, for: host, tab: .files) }
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if host.os == .linux {
                    PCSectionCard(title: "Set up the Linux side", systemImage: "wrench.and.screwdriver") {
                        LinuxSetup.fileSharing(host)
                    }
                }

                PCSectionCard(title: "File transfer", systemImage: "folder") {
                    if host.os == .linux {
                        Toggle("I have completed the Samba file sharing setup steps above", isOn: isSetupConfirmed)
                            .toggleStyle(.checkbox)
                            .padding(.bottom, 4)
                    }

                    Button {
                        Task { await model.openFiles(host) }
                    } label: {
                        Label("Open files in Finder", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(host.os == .linux && !isSetupConfirmed.wrappedValue)

                    Text(filesHint)
                        .font(.caption).foregroundStyle(.secondary)
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
        let isSetupConfirmed = Binding<Bool>(
            get: { model.isSetupConfirmed(for: host, tab: .terminal) },
            set: { model.setSetupConfirmed($0, for: host, tab: .terminal) }
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if host.os == .linux {
                    PCSectionCard(title: "Set up the Linux side", systemImage: "wrench.and.screwdriver") {
                        LinuxSetup.ssh(host)
                    }
                }

                PCSectionCard(title: "Remote terminal", systemImage: "terminal") {
                    if host.os == .linux {
                        Toggle("I have completed the SSH server setup steps above", isOn: isSetupConfirmed)
                            .toggleStyle(.checkbox)
                            .padding(.bottom, 4)
                    }

                    Button {
                        Task { await model.openSSH(host) }
                    } label: {
                        Label("Open SSH in Terminal", systemImage: "terminal.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(host.os == .linux && !isSetupConfirmed.wrappedValue)

                    Text(host.username.isEmpty
                         ? "Opens Terminal.app and runs `ssh \(host.host)`. Add a username to this computer to connect as a specific user. The PC needs an SSH server running (Windows: OpenSSH Server; Linux/Mac: enable Remote Login)."
                         : "Opens Terminal.app and runs `ssh \(host.username)@\(host.host)`. The PC needs an SSH server running (Windows: OpenSSH Server; Linux/Mac: enable Remote Login).")
                        .font(.caption).foregroundStyle(.secondary)
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
    @State private var destFolder: String
    @State private var autoReconnect: Bool

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
        
        let savedPassword = host.map { SecretStore.remotePassword(hostID: $0.idString) ?? "" } ?? ""
        _password = State(initialValue: savedPassword)
        
        _os = State(initialValue: host?.os ?? .windows)
        _proto = State(initialValue: host?.proto ?? .rdp)
        _hadStoredPassword = State(initialValue: host.map { SecretStore.hasRemotePassword(hostID: $0.idString) } ?? false)
        _destFolder = State(initialValue: host?.destFolder ?? "~/Downloads/MimicOS")
        _autoReconnect = State(initialValue: host?.autoReconnect ?? true)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !hostAddress.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
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
                if host == nil {
                    Picker("Operating system", selection: $os) {
                        ForEach(RemoteOS.allCases) { o in
                            Label(o.label, systemImage: o.systemImage).tag(o)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: os) { _, newOS in
                        if host == nil { proto = newOS.defaultProtocol }
                    }

                    Picker("Screen-share via", selection: $proto) {
                        ForEach(RemoteDesktop.Kind.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                } else {
                    LabeledContent("Operating system") {
                        Label(os.label, systemImage: os.systemImage)
                    }
                    LabeledContent("Screen-share via") {
                        Text(proto.label)
                    }
                }

                TextField("Name", text: $name, prompt: Text(os == .windows ? "Work PC" : os == .linux ? "Home Server" : "iMac"))
                TextField("Host / IP", text: $hostAddress, prompt: Text("192.168.1.50"))
                TextField("Port", text: $portText,
                          prompt: Text("Default: \(proto.defaultPort)"))
                TextField("Username", text: $username,
                          prompt: Text(proto == .rdp ? "Administrator" : "Required"))
                SecureField("Password",
                            text: $password,
                            prompt: Text("Required"))
                TextField("MimicOS Target Folder", text: $destFolder, prompt: Text("~/Downloads/MimicOS"))
                
                Toggle("Auto-reconnect when online", isOn: $autoReconnect)
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
        result.destFolder = destFolder.trimmingCharacters(in: .whitespaces).isEmpty ? "~/Downloads/MimicOS" : destFolder.trimmingCharacters(in: .whitespaces)
        result.autoReconnect = autoReconnect
        onSave(result, password)
    }
}

// MARK: - PCSettingsTab

private struct PCSettingsTab: View {
    @Environment(AppModel.self) private var model
    let host: RemoteHost

    @State private var name: String
    @State private var hostAddress: String
    @State private var portText: String
    @State private var username: String
    @State private var password: String
    @State private var destFolder: String
    @State private var autoReconnect: Bool
    @State private var rdpCommandAsCtrl: Bool
    @State private var redirectClipboard: Bool
    @State private var isSaving = false

    init(host: RemoteHost) {
        self.host = host
        _name = State(initialValue: host.name)
        _hostAddress = State(initialValue: host.host)
        _portText = State(initialValue: host.port.map(String.init) ?? "")
        _username = State(initialValue: host.username)

        let savedPassword = SecretStore.remotePassword(hostID: host.idString) ?? ""
        _password = State(initialValue: savedPassword)

        _destFolder = State(initialValue: host.destFolder)
        _autoReconnect = State(initialValue: host.autoReconnect)
        _rdpCommandAsCtrl = State(initialValue: host.rdpCommandAsCtrl)
        _redirectClipboard = State(initialValue: host.redirectClipboard)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !hostAddress.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PCSectionCard(title: "Connection Credentials", systemImage: "key.fill") {
                    Form {
                        TextField("Connection Name", text: $name, prompt: Text(host.os == .windows ? "Work PC" : "Home Server"))
                        TextField("Host / IP Address", text: $hostAddress, prompt: Text("192.168.1.50"))
                        TextField("Port", text: $portText, prompt: Text("Default: \(host.proto.defaultPort)"))
                        TextField("Username", text: $username, prompt: Text("Required"))
                        SecureField("Password", text: $password, prompt: Text("Required"))
                        TextField("MimicOS Target Folder", text: $destFolder, prompt: Text("~/Downloads/MimicOS"))
                    }
                    .formStyle(.grouped)
                    
                    HStack {
                        Spacer()
                        Button(action: saveCredentials) {
                            Text("Save Credentials")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isValid || isSaving)
                    }
                    .padding(.top, 4)
                }

                Divider()

                PCSectionCard(title: "Connection Options", systemImage: "network") {
                    Toggle("Auto-reconnect when online", isOn: Binding(
                        get: { autoReconnect },
                        set: { val in
                            autoReconnect = val
                            saveOption { $0.autoReconnect = val }
                        }))
                        .toggleStyle(.checkbox)

                    if host.proto == .rdp {
                        Toggle("Use ⌘ (Command) as Ctrl in the session", isOn: Binding(
                            get: { rdpCommandAsCtrl },
                            set: { val in
                                rdpCommandAsCtrl = val
                                saveOption { $0.rdpCommandAsCtrl = val }
                            }))
                            .toggleStyle(.checkbox)

                        Toggle("Redirect clipboard (Sync copy/paste with PC)", isOn: Binding(
                            get: { redirectClipboard },
                            set: { val in
                                redirectClipboard = val
                                saveOption { $0.redirectClipboard = val }
                            }))
                            .toggleStyle(.checkbox)
                    }
                }

            }
            .padding(20)
        }
        .onChange(of: host) { _, newHost in
            name = newHost.name
            hostAddress = newHost.host
            portText = newHost.port.map(String.init) ?? ""
            username = newHost.username
            password = SecretStore.remotePassword(hostID: newHost.idString) ?? ""
            destFolder = newHost.destFolder
            autoReconnect = newHost.autoReconnect
            rdpCommandAsCtrl = newHost.rdpCommandAsCtrl
            redirectClipboard = newHost.redirectClipboard
        }
    }

    private func saveCredentials() {
        var updated = host
        updated.name = name.trimmingCharacters(in: .whitespaces)
        updated.host = hostAddress.trimmingCharacters(in: .whitespaces)
        updated.port = Int(portText.trimmingCharacters(in: .whitespaces))
        updated.username = username.trimmingCharacters(in: .whitespaces)
        updated.destFolder = destFolder.trimmingCharacters(in: .whitespaces).isEmpty ? "~/Downloads/MimicOS" : destFolder.trimmingCharacters(in: .whitespaces)
        model.saveRemoteHost(updated, password: password)
        model.status = "Saved credentials for \(updated.name)"
    }

    private func saveOption(_ edit: (inout RemoteHost) -> Void) {
        var updated = host
        edit(&updated)
        let savedPassword = SecretStore.remotePassword(hostID: host.idString) ?? ""
        model.saveRemoteHost(updated, password: savedPassword)
    }
}
