import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The main detail pane: a top tab navbar with per-tab content.
struct ControlPanelView: View {
    @Environment(AppModel.self) private var model
    @State private var renameRequest: RenameRequest?

    var body: some View {
        if model.selectedDevice == nil {
            ContentUnavailableView("No device selected",
                                   systemImage: "iphone",
                                   description: Text("Pick a device from the sidebar, or connect one over USB."))
        } else {
            @Bindable var model = model
            VStack(spacing: 0) {
                if let device = model.selectedDevice {
                    DeviceDetailHeader(device: device) {
                        renameRequest = RenameRequest(serial: device.serial,
                                                      initialName: device.customName ?? device.displayName)
                    }
                    Divider()
                }
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
            .sheet(item: $renameRequest) { request in
                RenameSheet(initialName: request.initialName) { newName in
                    model.rename(request.serial, to: newName)
                    renameRequest = nil
                } onCancel: {
                    renameRequest = nil
                }
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
                    Toggle("Sync clipboard in background (even when not mirroring)", isOn: $model.clipboardSyncEnabled)
                        .font(.body)
                    Text("When active, iDroid automatically syncs copy/paste between this Mac and your phone in the background using a headless session.\n\nNote: If you start screen mirroring, the full scrcpy session takes over clipboard synchronization seamlessly.")
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

    private var selectedFile: ADB.RemoteFile? {
        model.browseFiles.first { model.selectedFiles.contains($0.path) }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if model.hasSelection { selectionBar; Divider() }
                if model.fileViewMode == .list {
                    columnHeader
                    Divider()
                }
                fileList
            }
            
            FloatingTransferHUD()
                .zIndex(1)

            // Invisible Spacebar shortcut handler
            Button("") {
                if let selected = selectedFile {
                    Task { await model.previewFile(selected) }
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)

            // Invisible arrow key shortcut handlers
            Button("") {
                model.selectPreviousFile()
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
            
            Button("") {
                model.selectNextFile()
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)

            Button("") {
                model.selectPreviousFile()
            }
            .keyboardShortcut(.upArrow, modifiers: [])
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)

            Button("") {
                model.selectNextFile()
            }
            .keyboardShortcut(.downArrow, modifiers: [])
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
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
                .buttonStyle(.bordered)
            Button { Task { await model.loadFiles() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.isBrowsing)
                .buttonStyle(.bordered)

            BreadcrumbBar()
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.isBrowsing { ProgressView().controlSize(.small) }

            // Select All / None Toggle
            Button {
                if model.selectedFiles.count == model.browseFiles.count {
                    model.deselectAllFiles()
                } else {
                    model.selectAllFiles()
                }
            } label: {
                Image(systemName: model.selectedFiles.count == model.browseFiles.count ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .help("Select All / None")
            .buttonStyle(.bordered)

            // Grid/List view mode segmented picker
            Picker("", selection: Bindable(model).fileViewMode) {
                Image(systemName: "list.bullet").tag(AppModel.FileViewMode.list)
                Image(systemName: "square.grid.2x2").tag(AppModel.FileViewMode.grid)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 60)

            Button { showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(.bordered)
            Button { pickAndUpload() } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("\(model.selectedFiles.count) selected").font(.callout)
            Spacer()
            Button("Copy to Mac…") { downloadSelected() }
            Button("Delete", role: .destructive) { Task { await model.deleteSelected() } }
            Button("Clear") { model.deselectAllFiles() }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.tint.opacity(0.08))
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 26)
            
            HeaderColumnButton(title: "Name", key: .name, activeKey: model.sortKey, order: model.sortOrder) {
                model.cycleSort(for: .name)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            ResizeDivider { delta in
                model.sizeWidth = max(60, min(300, model.sizeWidth - Double(delta)))
            }
            
            HeaderColumnButton(title: "Size", key: .size, activeKey: model.sortKey, order: model.sortOrder) {
                model.cycleSort(for: .size)
            }
            .frame(width: CGFloat(model.sizeWidth), alignment: .trailing)
            .padding(.trailing, 8)
            
            ResizeDivider { delta in
                model.dateWidth = max(80, min(400, model.dateWidth - Double(delta)))
            }
            
            HeaderColumnButton(title: "Date Modified", key: .date, activeKey: model.sortKey, order: model.sortOrder) {
                model.cycleSort(for: .date)
            }
            .frame(width: CGFloat(model.dateWidth), alignment: .trailing)
        }
        .font(.caption).bold().foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 24)
        .background(.quaternary.opacity(0.3))
    }

    private func downloadSelected() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Save Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task { await model.downloadSelected(toLocalDir: dir.path) }
    }

    private let gridColumns = [
        GridItem(.adaptive(minimum: 80, maximum: 120), spacing: 12)
    ]

    private var fileList: some View {
        Group {
            if model.fileViewMode == .grid {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        if model.browseFiles.isEmpty && !model.isBrowsing {
                            Text("Empty folder")
                                .foregroundStyle(.secondary).padding(.vertical, 30)
                        } else {
                            ForEach(model.sortedFiles) { file in
                                FileGridTile(file: file)
                            }
                        }
                    }
                    .padding(16)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if model.browseFiles.isEmpty && !model.isBrowsing {
                            Text("Empty folder")
                                .foregroundStyle(.secondary).padding(.vertical, 30)
                        } else {
                            ForEach(model.sortedFiles) { file in
                                FileRow(file: file)
                                Divider()
                            }
                        }
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

private struct ResizeDivider: View {
    let onDrag: (CGFloat) -> Void
    @State private var prevTranslation: CGFloat = 0
    @State private var isHovering = false
    
    var body: some View {
        Rectangle()
            .fill(isHovering ? Color.accentColor : Color.gray.opacity(0.3))
            .frame(width: 2)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .frame(width: 8) // wider hit test area
            .onHover { inside in
                isHovering = inside
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let delta = value.translation.width - prevTranslation
                        prevTranslation = value.translation.width
                        onDrag(delta)
                    }
                    .onEnded { _ in
                        prevTranslation = 0
                    }
            )
    }
}

private struct HeaderColumnButton: View {
    let title: String
    let key: AppModel.FileSortKey
    let activeKey: AppModel.FileSortKey?
    let order: AppModel.FileSortOrder
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption).bold()
                if activeKey == key {
                    Image(systemName: order == .ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
            }
            .foregroundStyle(activeKey == key ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct FileGridTile: View {
    @Environment(AppModel.self) private var model
    let file: ADB.RemoteFile
    @State private var hovering = false

    private var isSelected: Bool { model.selectedFiles.contains(file.path) }

    var body: some View {
        let _ = model.thumbnailLoadedTrigger // register dependency
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.12)) : (hovering ? AnyShapeStyle(.quaternary.opacity(0.3)) : AnyShapeStyle(.clear)))
                    .frame(width: 70, height: 70)
                
                if let thumbURL = model.getThumbnail(for: file),
                   let nsImage = NSImage(contentsOf: thumbURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: file.isDirectory ? "folder.fill" : fileIcon)
                        .font(.system(size: 40))
                        .foregroundStyle(file.isDirectory ? .blue : .secondary)
                }
            }
            
            Text(file.name)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 32, alignment: .top)
                .padding(.horizontal, 4)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.04)) : AnyShapeStyle(Color.clear))
        )
        .onHover { hovering = $0 }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                model.toggleSelection(file)
            } else {
                model.selectedFiles = [file.path]
            }
        }
        .onTapGesture(count: 2) {
            if file.isDirectory {
                Task { await model.openFolder(file) }
            } else {
                Task { await model.previewFile(file) }
            }
        }
        .contextMenu {
            if file.isDirectory {
                Button("Open") { Task { await model.openFolder(file) } }
            } else {
                Button("Preview (Space)") { Task { await model.previewFile(file) } }
            }
            Button("Copy to Mac…") { downloadToMac() }
            Divider()
            Button("Delete", role: .destructive) { Task { await model.deleteFromPhone(file) } }
        }
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
    }

    private var fileIcon: String {
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "apk": return "app.badge"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "mp4", "mkv", "mov", "avi", "3gp": return "video"
        case "mp3", "wav", "m4a", "ogg", "flac": return "music.note"
        case "txt", "md", "json", "xml", "csv": return "doc.text"
        case "zip", "tar", "gz", "rar", "7z": return "doc.zipper"
        default: return "doc"
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
}

private struct FileRow: View {
    @Environment(AppModel.self) private var model
    let file: ADB.RemoteFile
    @State private var hovering = false

    private var isSelected: Bool { model.selectedFiles.contains(file.path) }

    private var sizeText: String {
        if let bytes = file.sizeBytes { return byteString(bytes) }
        if file.isDirectory, let folderBytes = model.folderSizes[file.path] {
            return byteString(folderBytes)
        }
        return file.isDirectory ? "…" : "—"
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                model.toggleSelection(file)
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .opacity(isSelected || hovering || model.hasSelection ? 1 : 0.25)
            }
            .buttonStyle(.plain)
            .frame(width: 26)

            HStack(spacing: 8) {
                Image(systemName: file.isDirectory ? "folder.fill" : fileIcon)
                    .foregroundStyle(file.isDirectory ? .blue : .secondary)
                Text(file.name).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(sizeText)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: CGFloat(model.sizeWidth), alignment: .trailing)
                .padding(.trailing, 8)
            Text(file.modified ?? "—")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: CGFloat(model.dateWidth), alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background((isSelected || hovering) ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.1), value: hovering)
        .animation(.easeInOut(duration: 0.1), value: isSelected)
        .onHover { hovering = $0 }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                model.toggleSelection(file)
            } else {
                model.selectedFiles = [file.path]
            }
        }
        .onTapGesture(count: 2) {
            if file.isDirectory { Task { await model.openFolder(file) } }
            else { Task { await model.previewFile(file) } }
        }
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
            } else {
                Button("Preview (Space)") { Task { await model.previewFile(file) } }
            }
            Button("Copy to Mac…") { downloadToMac() }
            Divider()
            Button("Delete", role: .destructive) { Task { await model.deleteFromPhone(file) } }
        }
    }

    private var fileIcon: String {
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "apk": return "app.badge"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "mp4", "mkv", "mov", "avi", "3gp": return "video"
        case "mp3", "wav", "m4a", "ogg", "flac": return "music.note"
        case "txt", "md", "json", "xml", "csv": return "doc.text"
        case "zip", "tar", "gz", "rar", "7z": return "doc.zipper"
        default: return "doc"
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

// MARK: - Device Detail Header

private struct DeviceDetailHeader: View {
    @Environment(AppModel.self) private var model
    let device: Device
    let onRename: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(device.displayName)
                        .font(.title2)
                        .bold()
                    
                    Button {
                        onRename()
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Rename device")
                }
                
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("•")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(device.serial)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            HStack(spacing: 10) {
                if device.state.isUsable {
                    Button {
                        Task { await model.disconnect(device) }
                    } label: {
                        Label("Disconnect", systemImage: "wifi.slash")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        Task { await model.reconnect(device) }
                    } label: {
                        Label("Connect", systemImage: "link")
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                Button(role: .destructive) {
                    Task { await model.forget(device) }
                } label: {
                    Label("Forget", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.background)
    }

    private var statusColor: Color {
        if device.isOffline { return .secondary }
        return device.state.isUsable ? .green : .orange
    }

    private var statusText: String {
        if device.isOffline { return "Offline" }
        switch device.state {
        case .ready: return device.isWireless ? "Wireless" : "USB"
        case .unauthorized: return "Unauthorized"
        case .offline: return "Offline"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - Breadcrumb Navigation Bar

private struct BreadcrumbBar: View {
    @Environment(AppModel.self) private var model
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let segments = parsePathSegments(model.browsePath)
                ForEach(segments) { segment in
                    if segment.path != segments.first?.path {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    
                    Button {
                        Task { await model.loadFiles(path: segment.path) }
                    } label: {
                        Text(segment.name)
                            .font(.subheadline)
                            .foregroundStyle(segment.path == model.browsePath ? Color.primary : Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(segment.path == model.browsePath ? AnyShapeStyle(.quaternary.opacity(0.3)) : AnyShapeStyle(.clear))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
    
    private func parsePathSegments(_ path: String) -> [PathSegment] {
        var segments: [PathSegment] = []
        
        if path.hasPrefix("/sdcard") {
            segments.append(PathSegment(name: "Internal Storage", path: "/sdcard/"))
            let sub = path.dropFirst("/sdcard".count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !sub.isEmpty {
                let parts = sub.split(separator: "/")
                var accumulated = "/sdcard"
                for part in parts {
                    accumulated += "/" + part
                    segments.append(PathSegment(name: String(part), path: accumulated + "/"))
                }
            }
        } else {
            segments.append(PathSegment(name: "Root", path: "/"))
            let sub = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !sub.isEmpty {
                let parts = sub.split(separator: "/")
                var accumulated = ""
                for part in parts {
                    accumulated += "/" + part
                    segments.append(PathSegment(name: String(part), path: accumulated + "/"))
                }
            }
        }
        return segments
    }
}

struct PathSegment: Identifiable {
    let name: String
    let path: String
    var id: String { path }
}

private struct HUDHeaderButton: View {
    let systemName: String
    let action: () -> Void
    @State private var hovering = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: 20, height: 20)
                .background(hovering ? Color.primary.opacity(0.12) : Color.clear)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct FloatingTransferHUD: View {
    @Environment(AppModel.self) private var model
    @State private var isMinimized = false

    var body: some View {
        if model.transfers.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                if isMinimized {
                    minimizedView
                } else {
                    maximizedView
                }
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 5)
            .padding(16)
            .frame(width: isMinimized ? 220 : 360, height: isMinimized ? 40 : nil)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isMinimized)
        }
    }

    private var activeCount: Int {
        model.transfers.filter { !$0.done }.count
    }

    private var overallFraction: Double {
        let activeTransfers = model.transfers
        guard !activeTransfers.isEmpty else { return 0 }
        let total = activeTransfers.reduce(0.0) { $0 + $1.fraction }
        return total / Double(activeTransfers.count)
    }

    private var minimizedView: some View {
        HStack(spacing: 12) {
            Image(systemName: activeCount > 0 ? "arrow.up.left.and.arrow.down.right.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(activeCount > 0 ? Color.accentColor : Color.green)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 2) {
                if activeCount > 0 {
                    Text("Transferring \(activeCount) file\(activeCount > 1 ? "s" : "")")
                        .font(.caption).bold()
                    Text("\(Int(overallFraction * 100))%")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text("Transfers Complete")
                        .font(.caption).bold()
                }
            }
            Spacer()
            HUDHeaderButton(systemName: "arrow.up.left.and.arrow.down.right") {
                isMinimized = false
            }
            .help("Expand")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var maximizedView: some View {
        VStack(spacing: 0) {
            HStack {
                Label("File Transfers", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .font(.subheadline).bold()
                Spacer()
                
                HStack(spacing: 8) {
                    HUDHeaderButton(systemName: "minus") {
                        isMinimized = true
                    }
                    .help("Minimize")

                    if activeCount == 0 {
                        HUDHeaderButton(systemName: "xmark") {
                            model.transfers.removeAll()
                        }
                        .help("Clear")
                    } else {
                        Button("Cancel All") {
                            Task {
                                for t in model.transfers where !t.done {
                                    await model.cancelTransfer(t.id)
                                }
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            
            Divider().background(.white.opacity(0.1))
            
            if activeCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: overallFraction)
                        .progressViewStyle(.linear)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider().background(.white.opacity(0.1))
            }
            
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.transfers) { t in
                        TransferRowView(transfer: t)
                        if t.id != model.transfers.last?.id {
                            Divider().background(.white.opacity(0.05))
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }
}

private struct TransferRowView: View {
    @Environment(AppModel.self) private var model
    let transfer: AppModel.Transfer

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if transfer.done {
                    Image(systemName: transfer.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(transfer.failed ? .red : .green)
                } else {
                    Image(systemName: transfer.direction == .toPhone ? "arrow.right.to.line.circle.fill" : "arrow.left.to.line.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(transfer.name)
                        .font(.caption)
                        .bold()
                        .lineLimit(1)
                    Spacer()
                    Text(statusLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                
                if transfer.done {
                    ProgressView(value: transfer.failed ? 0.0 : 1.0)
                        .progressViewStyle(.linear)
                } else if transfer.isDeterminate {
                    ProgressView(value: transfer.fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }

            if transfer.inProgress {
                Button {
                    Task { await model.cancelTransfer(transfer.id) }
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var statusLabel: String {
        if transfer.cancelled { return "Cancelled" }
        if transfer.failed { return "Failed" }
        if transfer.done { return "Done" }
        
        let formattedSent = byteString(transfer.bytesTransferred)
        if let total = transfer.totalBytes, total > 0 {
            let formattedTotal = byteString(total)
            return "\(formattedSent) / \(formattedTotal) (\(Int(transfer.fraction * 100))%)"
        }
        return transfer.direction == .toPhone ? "Uploading..." : "Downloading..."
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
