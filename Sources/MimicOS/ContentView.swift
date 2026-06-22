import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            } detail: {
                if model.isComputerSelected {
                    PCPanelView()
                } else if model.toolsReady {
                    ControlPanelView()
                } else {
                    SetupNeededView()
                }
            }
            Divider()
            StatusBar()
        }
        .onAppear {
            #if os(macOS)
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.syncActivationPolicy()
            }
            NSApp.activate(ignoringOtherApps: true)
            #endif
        }
        .task {
            model.openMainWindowAction = {
                openWindow(id: "main")
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.syncActivationPolicy()
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

// MARK: - Sidebar: device list

/// Identifiable rename request so we can drive a `.sheet(item:)` (which can
/// coexist with the Add-Device `.sheet(isPresented:)` — two `isPresented`
/// sheets on one view collide and silently break).
struct RenameRequest: Identifiable {
    let serial: String
    let initialName: String
    var id: String { serial }
}

/// The left sidebar: one combined list with a "Devices" section (phones) and a
/// "Computers" section (remote desktops). The `+` toolbar button opens a chooser
/// that branches to either the phone-add flow or the add-computer form.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renameRequest: RenameRequest?
    @State private var editorState: HostEditorState?

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(
            get: { model.selection },
            set: { model.selection = $0 }
        )) {
            Section("Devices") {
                if model.devices.isEmpty {
                    Text("No devices connected")
                        .foregroundStyle(.secondary).font(.callout)
                }
                ForEach(model.devices) { device in
                    DeviceRow(device: device)
                        .tag(AppModel.Selection.phone(device.serial))
                        .contextMenu { deviceMenu(device) }
                }
            }

            Section("Computers") {
                if model.remoteHosts.isEmpty {
                    Text("No computers added")
                        .foregroundStyle(.secondary).font(.callout)
                }
                ForEach(model.remoteHosts) { host in
                    PCSidebarRow(host: host)
                        .tag(AppModel.Selection.computer(host.id))
                        .contextMenu { hostMenu(host) }
                }
            }
        }
        .sheet(item: $renameRequest) { request in
            RenameSheet(initialName: request.initialName) { newName in
                model.rename(request.serial, to: newName)
                renameRequest = nil
            } onCancel: {
                renameRequest = nil
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.showAddDevice = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            ToolbarItem {
                Button {
                    Task {
                        await model.refreshDevices()
                        await model.refreshAllHostReachability()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isWorking)
            }
        }
        // The unified `+` chooser: phone flow OR add-computer form.
        .sheet(isPresented: Binding(
            get: { model.showAddDevice },
            set: { model.showAddDevice = $0 }
        )) {
            AddDeviceSheet(onAddComputer: {
                model.showAddDevice = false
                editorState = HostEditorState(host: nil)
            })
        }
        // Add / edit a computer.
        .sheet(item: $editorState) { state in
            RemoteHostEditor(host: state.host) { host, password in
                model.saveRemoteHost(host, password: password)
                model.selection = .computer(host.id)
                editorState = nil
            } onCancel: {
                editorState = nil
            }
        }
        .task { await model.refreshAllHostReachability() }
    }

    @ViewBuilder
    private func deviceMenu(_ device: Device) -> some View {
        Button {
            renameRequest = RenameRequest(serial: device.serial,
                                          initialName: device.customName ?? device.displayName)
        } label: { Label("Rename…", systemImage: "pencil") }

        if device.state.isUsable {
            Button {
                Task { await model.disconnect(device) }
            } label: { Label("Disconnect", systemImage: "wifi.slash") }
        } else {
            Button {
                Task { await model.reconnect(device) }
            } label: { Label("Connect", systemImage: "link") }
        }

        Divider()

        Button(role: .destructive) {
            Task { await model.forget(device) }
        } label: { Label("Remove from MimicOS", systemImage: "trash") }
    }

    @ViewBuilder
    private func hostMenu(_ host: RemoteHost) -> some View {
        Button {
            model.selection = .computer(host.id)
            model.selectedPCTab = .settings
        } label: { Label("Edit…", systemImage: "pencil") }
        Button {
            Task { await model.pingHost(host) }
        } label: { Label("Check status", systemImage: "wave.3.right") }
        Divider()
        Button(role: .destructive) {
            model.deleteRemoteHost(host)
        } label: { Label("Remove", systemImage: "trash") }
    }
}

struct PCSidebarRow: View {
    @Environment(AppModel.self) private var model
    let host: RemoteHost

    /// Reachability: nil = not yet checked. The OS icon turns green when the host
    /// responds (mirrors how a connected phone's icon goes green).
    private var reachable: Bool? { model.hostReachability[host.id] }
    private var isPinging: Bool { model.hostsBeingPinged.contains(host.id) }
    private var isConnected: Bool { model.connectedRemoteHostID == host.id }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if isPinging {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: host.os.systemImage)
                        .foregroundStyle(iconColor)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).font(.body)
                Text(stateLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .opacity(reachable == false ? 0.55 : 1)
    }

    /// Matches the phone row: green when reachable/connected, grey when offline,
    /// secondary while unknown.
    private var iconColor: Color {
        if isConnected { return .green }
        switch reachable {
        case .some(true):  return .green
        case .some(false): return .secondary
        case .none:        return .secondary
        }
    }

    private var stateLabel: String {
        if isConnected { return "Connected" }
        switch reachable {
        case .some(true):  return "Online · \(host.subtitle)"
        case .some(false): return "Offline · \(host.subtitle)"
        case .none:        return host.subtitle
        }
    }
}

struct DeviceRow: View {
    let device: Device

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.isWireless ? "wifi" : "cable.connector")
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.body)
                Text(stateLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .opacity((device.isOffline || device.state == .offline) ? 0.55 : 1)
    }

    private var iconColor: Color {
        if device.isOffline || device.state == .offline { return .secondary }
        return device.state.isUsable ? .green : .orange
    }

    private var stateLabel: String {
        if device.isOffline || device.state == .offline { return "Disconnected · tap menu to connect" }
        switch device.state {
        case .ready: return device.isWireless ? "Wireless · ready" : "USB · ready"
        case .unauthorized: return "Unauthorized — accept the prompt on the phone"
        case .offline: return "Offline"
        case .unknown: return "Unknown state"
        }
    }
}


// MARK: - Rename sheet

/// A small focused sheet for renaming a device. Sheets give a reliable,
/// editable, auto-focused text field (alert text fields are flaky on macOS).
struct RenameSheet: View {
    let initialName: String
    @State private var name: String = ""
    @FocusState private var focused: Bool
    let onSave: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename device").font(.headline)
            Text("Shown only in MimicOS, stored on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Device name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { onSave(name) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(name) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            name = initialName
            focused = true
        }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            
            if model.isConnecting {
                ProgressView().controlSize(.small)
            }
            Text(connectionStatusText)
                .font(.callout)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            diagnosticsView
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var dotColor: Color {
        if model.isComputerSelected, let host = model.selectedHost {
            let isConnected = model.connectedRemoteHostID == host.id
            let reachable = model.hostReachability[host.id]
            if isConnected { return .green }
            switch reachable {
            case .some(true):  return .green
            case .some(false): return .secondary
            case .none:        return .secondary
            }
        }
        guard let device = model.selectedDevice else { return .red }
        if device.isOffline { return .secondary }
        return device.state.isUsable ? .green : .orange
    }

    private var connectionStatusText: String {
        if model.isConnecting {
            return "Connecting..."
        }
        if model.isComputerSelected, let host = model.selectedHost {
            let isConnected = model.connectedRemoteHostID == host.id
            let reachable = model.hostReachability[host.id]
            if isConnected { return "Connected to \(host.name)" }
            switch reachable {
            case .some(true):  return "\(host.name) Online"
            case .some(false): return "\(host.name) Offline"
            case .none:        return "Checking \(host.name)..."
            }
        }
        guard let device = model.selectedDevice else {
            return "No device connected"
        }
        if device.isOffline {
            return "Offline"
        }
        switch device.state {
        case .ready:
            return device.isWireless ? "Wireless Connected" : "USB Connected"
        case .unauthorized:
            return "Unauthorized"
        case .offline:
            return "Offline"
        case .unknown:
            return "Unknown"
        }
    }

    @ViewBuilder
    private var diagnosticsView: some View {
        if let info = model.info {
            HStack(spacing: 12) {
                if let res = info.resolution {
                    Label(res, systemImage: "macbook.and.iphone")
                }
                if let version = info.androidVersion {
                    Text("Android \(version)")
                }
                if let battery = info.batteryLevel {
                    HStack(spacing: 4) {
                        Image(systemName: info.isCharging == true ? "battery.100.percent.bolt" : "battery.100")
                        Text("\(battery)%")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Setup-needed placeholder

struct SetupNeededView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Tools not found").font(.title2).bold()
            VStack(alignment: .leading, spacing: 6) {
                Label("adb: \(model.adbInstalled ? "found" : "missing")",
                      systemImage: model.adbInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(model.adbInstalled ? .green : .red)
                Label("scrcpy: \(model.scrcpyInstalled ? "found" : "missing")",
                      systemImage: model.scrcpyInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(model.scrcpyInstalled ? .green : .red)
            }
            Text("Run `Scripts/setup.sh` (installs via Homebrew) and relaunch.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}
