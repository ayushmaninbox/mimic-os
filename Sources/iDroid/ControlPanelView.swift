import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The main detail pane: everything you can do with the selected device.
struct ControlPanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.selectedDevice == nil {
            ContentUnavailableView("No device selected",
                                   systemImage: "iphone",
                                   description: Text("Pick a device from the sidebar, or connect one over USB."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    MirrorSection()
                    Divider()
                    AutomationSection()
                    Divider()
                    FilesSection()
                    Divider()
                    NotificationsSection()
                }
                .padding(20)
            }
        }
    }
}

// MARK: - Mirror

private struct MirrorSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SectionCard(title: "Mirror & Control", systemImage: "rectangle.on.rectangle") {
            Toggle("Turn phone screen off while mirroring", isOn: $model.turnScreenOff)
            Toggle("Keep device awake", isOn: $model.stayAwake)
            Button {
                model.toggleMirror()
            } label: {
                Label(model.isMirroring ? "Stop mirroring" : "Start mirroring",
                      systemImage: model.isMirroring ? "stop.circle" : "play.circle")
            }
            .buttonStyle(.borderedProminent)
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

// MARK: - Files

private struct FilesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SectionCard(title: "Files & Apps", systemImage: "folder") {
            HStack {
                Button("Push file to phone…") { pickAndPush() }
                Button("Install APK…") { pickAndInstall() }
            }
            Text("Pushed files land in /sdcard/Download/.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pickAndPush() {
        guard let url = openPanel(types: nil) else { return }
        Task { await model.pushFile(localPath: url.path) }
    }

    private func pickAndInstall() {
        let apk = UTType(filenameExtension: "apk") ?? .data
        guard let url = openPanel(types: [apk]) else { return }
        Task { await model.installAPK(localPath: url.path) }
    }

    private func openPanel(types: [UTType]?) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let types { panel.allowedContentTypes = types }
        return panel.runModal() == .OK ? panel.url : nil
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
