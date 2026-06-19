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
                    DeviceRow(device: device).tag(device.serial)
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
}

struct DeviceRow: View {
    let device: Device

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.isWireless ? "wifi" : "cable.connector")
                .foregroundStyle(device.state.isUsable ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.body)
                Text(stateLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var stateLabel: String {
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
