import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
        .overlay(alignment: .bottom) { StatusBar() }
    }
}

// MARK: - Sidebar: device list

struct DeviceListView: View {
    @Environment(AppModel.self) private var model
    @State private var renameTarget: String?   // serial being renamed
    @State private var renameText: String = ""

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
        .alert("Rename device", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let serial = renameTarget { model.rename(serial, to: renameText) }
                renameTarget = nil
            }
        } message: {
            Text("Choose a name shown only in iDroid (stored on this Mac).")
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
            renameText = device.customName ?? device.displayName
            renameTarget = device.serial
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

// MARK: - Status bar

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if model.isWorking { ProgressView().controlSize(.small) }
            Text(model.status).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
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
