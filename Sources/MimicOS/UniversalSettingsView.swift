import SwiftUI
import AppKit

/// App-wide settings, shown as a sheet from the window's title-bar gear and from
/// the menu bar's "Settings" item. Covers Dock / menu-bar visibility, background
/// behaviour, login launch, and the capture folder — the things that aren't tied
/// to any single device.
struct UniversalSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var settings: AppSettings { model.settings }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title2).bold()
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)

            Form {
                Section("Appearance") {
                    Toggle("Hide MimicOS icon in the Dock", isOn: Binding(
                        get: { settings.hideInDock },
                        set: { val in
                            if val && settings.hideInMenuBar { settings.hideInMenuBar = false; syncMenuBar() }
                            settings.hideInDock = val
                            syncDock()
                        }))
                    Toggle("Hide MimicOS item in the Menu Bar", isOn: Binding(
                        get: { settings.hideInMenuBar },
                        set: { val in
                            if val && settings.hideInDock { settings.hideInDock = false; syncDock() }
                            settings.hideInMenuBar = val
                            syncMenuBar()
                        }))
                    Text("At least one must stay visible so you can reach the app.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Background") {
                    Toggle("Keep MimicOS running in the menu bar when the window is closed", isOn: Binding(
                        get: { settings.runInBackground },
                        set: { settings.runInBackground = $0; syncDock() }))
                    Toggle("Launch MimicOS at login", isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }))
                }

                Section("Captures") {
                    HStack {
                        Text(settings.captureFolder.path)
                            .lineLimit(1).truncationMode(.middle)
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([settings.ensureCaptureFolderExists()])
                        }
                        Button("Change…") { chooseCaptureFolder() }
                    }
                    Text("Phone & computer screenshots and recordings are saved here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460, height: 460)
    }

    private func syncDock() {
        (NSApp.delegate as? AppDelegate)?.syncActivationPolicy()
    }
    private func syncMenuBar() {
        (NSApp.delegate as? AppDelegate)?.syncStatusItemVisibility()
    }

    private func chooseCaptureFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.captureFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.captureFolder = url
    }
}
