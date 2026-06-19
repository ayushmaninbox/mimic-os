import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                DeviceListView()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            } detail: {
                if model.toolsReady {
                    ControlPanelView()
                } else {
                    SetupNeededView()
                }
            }
            Divider()
            StatusBar()
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

struct DeviceListView: View {
    @Environment(AppModel.self) private var model
    @State private var renameRequest: RenameRequest?

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(
            get: { model.selectedSerial },
            set: { newValue in
                if let newValue { Task { await model.select(newValue) } }
            }
        )) {
            Section("Devices") {
                if model.devices.isEmpty {
                    Text("No devices connected")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(model.devices) { device in
                    DeviceRow(device: device)
                        .tag(device.serial)
                        .contextMenu { deviceMenu(device) }
                }
            }

            if !model.discoveredPhones.isEmpty {
                Section("Discovered on Wi-Fi") {
                    ForEach(model.discoveredPhones) { phone in
                        DiscoveredRow(phone: phone)
                    }
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
                    Label("Add device", systemImage: "plus")
                }
            }
            ToolbarItem {
                Button {
                    Task { await model.refreshDevices() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isWorking)
            }
        }
        .sheet(isPresented: Binding(
            get: { model.showAddDevice },
            set: { model.showAddDevice = $0 }
        ), onDismiss: { model.cancelQRPairing() }) {
            AddDeviceSheet()
        }
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
        } label: { Label("Remove from iDroid", systemImage: "trash") }
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
        .opacity(device.isOffline ? 0.55 : 1)
    }

    private var iconColor: Color {
        if device.isOffline { return .secondary }
        return device.state.isUsable ? .green : .orange
    }

    private var stateLabel: String {
        if device.isOffline { return "Saved · tap menu to connect" }
        switch device.state {
        case .ready: return device.isWireless ? "Wireless · ready" : "USB · ready"
        case .unauthorized: return "Unauthorized — accept the prompt on the phone"
        case .offline: return "Offline"
        case .unknown: return "Unknown state"
        }
    }
}

/// A phone found via mDNS that isn't connected yet — one click to connect/pair.
struct DiscoveredRow: View {
    @Environment(AppModel.self) private var model
    let phone: DiscoveredPhone

    var body: some View {
        Button {
            Task { await model.connect(to: phone) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: phone.kind == .connect ? "wifi.circle" : "lock.circle")
                    .foregroundStyle(phone.kind == .connect ? .blue : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(phone.name).font(.body).lineLimit(1)
                    Text(phone.kind == .connect ? "Tap to connect" : "Needs pairing")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Rename sheet

/// A small focused sheet for renaming a device. Sheets give a reliable,
/// editable, auto-focused text field (alert text fields are flaky on macOS).
struct RenameSheet: View {
    @State private var name: String
    @FocusState private var focused: Bool
    let onSave: (String) -> Void
    let onCancel: () -> Void

    init(initialName: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _name = State(initialValue: initialName)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename device").font(.headline)
            Text("Shown only in iDroid, stored on this Mac.")
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
        .onAppear { focused = true }
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
        guard let device = model.selectedDevice else { return .red }
        if device.isOffline { return .secondary }
        return device.state.isUsable ? .green : .orange
    }

    private var connectionStatusText: String {
        if model.isConnecting {
            return "Connecting..."
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
