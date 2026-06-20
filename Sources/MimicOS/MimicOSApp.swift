import SwiftUI
import AppKit

@main
struct MimicOSApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("MimicOS", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
                .task {
                    appDelegate.model = model
                    await model.onAppear()
                }
                .onDisappear { model.onDisappear() }
        }
        .windowResizability(.contentMinSize)

        // Black-glyph menu-bar item: keeps MimicOS available while the main
        // window is closed and the app runs quietly in the background.
        MenuBarExtra("MimicOS", systemImage: "iphone.gen3") {
            MenuBarContent(openMainWindow: { openWindow(id: "main") })
                .environment(model)
        }
    }
}

/// Contents of the menu-bar dropdown: quick status, capture actions, and the
/// ways to bring the main window back or quit.
private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    let openMainWindow: () -> Void

    var body: some View {
        @Bindable var settings = model.settings
        return Group {
            if let device = model.selectedDevice, device.state.isUsable {
                Text(device.displayName)
                Divider()
                Button("Take Screenshot") { Task { await model.captureScreenshot() } }
                Button(model.isRecording ? "Stop Recording" : "Record Screen") {
                    Task { await model.toggleScreenRecording() }
                }
                Button(model.isMirroring ? "Stop Mirroring" : "Start Mirroring") {
                    model.toggleMirror()
                }
                Divider()
            } else {
                Text("No device connected")
                Divider()
            }

            Button("Open MimicOS") {
                openMainWindow()
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o")

            Toggle("Run in Background", isOn: $settings.runInBackground)

            Divider()
            Button("Quit MimicOS") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

/// Manages the app's lifecycle so it can keep running in the background as a
/// menu-bar agent. When the main window closes and "Run in Background" is on, we
/// switch to `.accessory` (no Dock icon, no app switcher) instead of quitting.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the App once the model exists, so we can read the user's setting.
    @MainActor weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    /// On quit, stop scrcpy and tear down floating windows so nothing is left
    /// running (the mirror window is a separate process that would otherwise
    /// linger after the app exits).
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }

    /// Don't quit when the last window closes — drop to the menu bar instead
    /// (unless the user turned background mode off).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let runInBackground = MainActor.assumeIsolated { model?.settings.runInBackground ?? true }
        if runInBackground {
            NSApp.setActivationPolicy(.accessory)
            return false
        }
        return true
    }

    /// Clicking the Dock icon (when visible) reopens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}
