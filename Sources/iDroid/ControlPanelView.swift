import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The main detail pane: a top tab navbar with per-tab content.
struct ControlPanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.selectedDevice == nil {
            ContentUnavailableView("No device selected",
                                   systemImage: "iphone",
                                   description: Text("Pick a device from the sidebar, or connect one over USB."))
        } else {
            @Bindable var model = model
            VStack(spacing: 0) {
                TabNavBar(selection: $model.selectedTab)
                Divider()
                Group {
                    switch model.selectedTab {
                    case .control:        ControlTab()
                    case .files:          FilesTab()
                    case .notifications:  NotificationsTab()
                    case .settings:       SettingsTab()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Top tab navbar

private struct TabNavBar: View {
    @Binding var selection: AppModel.Tab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppModel.Tab.allCases) { tab in
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

// MARK: - Control tab (mirror + quick controls)

private struct ControlTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MirrorSection()
                Divider()
                AutomationSection()
            }
            .padding(20)
        }
    }
}

// MARK: - Notifications tab

private struct NotificationsTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                NotificationsSection()
            }
            .padding(20)
        }
    }
}

// MARK: - Settings tab (mirror options + clipboard live here too)

private struct SettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionCard(title: "Mirror options", systemImage: "rectangle.on.rectangle") {
                    Toggle("Turn phone screen off while mirroring", isOn: $model.turnScreenOff)
                    Toggle("Keep device awake", isOn: $model.stayAwake)
                }
                Divider()
                SectionCard(title: "Clipboard", systemImage: "doc.on.clipboard") {
                    Toggle("Sync clipboard automatically", isOn: $model.clipboardSyncEnabled)
                    Text("Copy on either device, paste on the other. Phone→Mac is most reliable while mirroring is focused.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Mirror

private struct MirrorSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SectionCard(title: "Mirror & Control", systemImage: "rectangle.on.rectangle") {
            Button {
                model.toggleMirror()
            } label: {
                Label(model.isMirroring ? "Stop mirroring" : "Start mirroring",
                      systemImage: model.isMirroring ? "stop.circle" : "play.circle")
            }
            .buttonStyle(.borderedProminent)
            Text("Options (screen-off, clipboard sync) are in the Settings tab.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Automation

private struct AutomationSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SectionCard(title: "Quick Controls", systemImage: "hand.tap") {
            HStack {
                Button("Home") { Task { await model.pressHome() } }
                Button("Back") { Task { await model.pressBack() } }
                Button("Power") { Task { await model.togglePower() } }
            }
            Text("Power toggles the screen — handy for the screen-off workflow.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Files tab (Finder-style browser)

private struct FilesTab: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            columnHeader
            Divider()
            fileList
            if !model.transfers.isEmpty {
                Divider()
                TransferStrip()
            }
        }
        .task(id: model.selectedSerial) {
            if model.selectedSerial != nil { await model.loadFiles(path: "/sdcard/") }
        }
        // Drag files in from Finder/Desktop -> upload to the current folder.
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.uploadToCurrentFolder(localPaths: urls.map(\.path)) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.tint, lineWidth: 3)
                    .background(.tint.opacity(0.08))
                    .overlay(Label("Drop to copy onto the phone", systemImage: "square.and.arrow.down")
                        .font(.title3).padding())
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                Task { await model.makeFolder(named: newFolderName); newFolderName = "" }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { Task { await model.goUp() } } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoUp || model.isBrowsing)
            Button { Task { await model.loadFiles() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.isBrowsing)

            Text(model.browsePath)
                .font(.callout.monospaced())
                .lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.isBrowsing { ProgressView().controlSize(.small) }

            Button { showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
            Button { pickAndUpload() } label: { Image(systemName: "square.and.arrow.up") }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Size").frame(width: 90, alignment: .trailing)
            Text("Date Modified").frame(width: 140, alignment: .trailing)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 5)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.browseFiles.isEmpty && !model.isBrowsing {
                    Text("Empty folder")
                        .foregroundStyle(.secondary).padding(.vertical, 30)
                } else {
                    ForEach(model.browseFiles) { file in
                        FileRow(file: file)
                        Divider()
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        Task { await model.uploadToCurrentFolder(localPaths: paths) }
    }
}

private struct FileRow: View {
    @Environment(AppModel.self) private var model
    let file: ADB.RemoteFile
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: file.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(file.isDirectory ? .blue : .secondary)
                Text(file.name).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(file.sizeBytes.map(byteString) ?? "—")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(file.modified ?? "—")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 140, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(hovering ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            if file.isDirectory { Task { await model.openFolder(file) } }
        }
        // Drag a phone file out to Finder/Desktop. We stage it to a temp file
        // first (adb pull), then hand Finder the resulting local URL.
        .onDrag {
            let provider = NSItemProvider()
            provider.suggestedName = file.name
            provider.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier,
                                                 fileOptions: [], visibility: .all) { completion in
                Task {
                    let url = await model.stageForDragOut(file)
                    completion(url, true, nil)
                }
                return nil
            }
            return provider
        }
        .contextMenu {
            if file.isDirectory {
                Button("Open") { Task { await model.openFolder(file) } }
            }
            Button("Copy to Mac…") { downloadToMac() }
            Divider()
            Button("Delete", role: .destructive) { Task { await model.deleteFromPhone(file) } }
        }
    }

    private func downloadToMac() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Save Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task { await model.downloadFromPhone(file, toLocalDir: dir.path) }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Progress bars for in-flight / recent transfers.
private struct TransferStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            ForEach(model.transfers) { t in
                TransferRow(transfer: t)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxHeight: 140)
    }
}

private struct TransferRow: View {
    @Environment(AppModel.self) private var model
    let transfer: AppModel.Transfer

    var body: some View {
        HStack(spacing: 10) {
            // Direction + status icon.
            Group {
                if transfer.done {
                    Image(systemName: transfer.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(transfer.failed ? .red : .green)
                } else {
                    Image(systemName: transfer.direction == .toPhone ? "arrow.down.circle" : "arrow.up.circle")
                        .foregroundStyle(.tint)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(transfer.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
                // Determinate bar when we know the size, indeterminate otherwise.
                if transfer.done {
                    ProgressView(value: transfer.failed ? 0 : 1)
                } else if transfer.isDeterminate {
                    ProgressView(value: transfer.fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }

            if transfer.done {
                Button {
                    model.clearTransfer(transfer.id)
                } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var label: String {
        if transfer.failed { return "Failed" }
        if transfer.done { return "Done" }
        if transfer.isDeterminate { return "\(Int(transfer.fraction * 100))%" }
        return transfer.direction == .toPhone ? "Copying to phone…" : "Copying to Mac…"
    }
}

// MARK: - Notifications

private struct NotificationsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SectionCard(title: "Notifications (snapshot)", systemImage: "bell") {
            if model.notifications.isEmpty {
                Text("No notifications captured. Press Refresh in the sidebar to re-scan.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.notifications.prefix(15).enumerated()), id: \.offset) { _, line in
                    Text("• \(line)").font(.callout)
                }
            }
            Text("App-free snapshot via dumpsys — coarse and not real-time.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Shared card chrome

private struct SectionCard<Content: View>: View {
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
