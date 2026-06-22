import Foundation
import Observation
import AppKit

/// App-wide preferences persisted on the Mac via `UserDefaults`. Distinct from
/// `DeviceStore`, which holds per-phone bookkeeping; this is for global toggles
/// and paths the user sets in the Settings tab.
@MainActor
@Observable
final class AppSettings {
    private static let captureFolderKey = "MimicOS.captureFolderBookmark"
    private static let captureFolderPathKey = "MimicOS.captureFolderPath"
    private static let autoReconnectKey = "MimicOS.autoReconnect"
    private static let runInBackgroundKey = "MimicOS.runInBackground"
    private static let alwaysOnTopKey = "MimicOS.alwaysOnTop"
    private static let callAlertsKey = "MimicOS.callAlerts"
    private static let phoneDestFolderKey = "MimicOS.phoneDestFolder"
    private static let hideInDockKey = "MimicOS.hideInDock"
    private static let hideInMenuBarKey = "MimicOS.hideInMenuBar"

    private var defaults: UserDefaults { .standard }

    /// Folder where screenshots and screen recordings are saved. Defaults to
    /// `~/Downloads/MimicOS` and is created on first use.
    var captureFolder: URL {
        didSet { persistCaptureFolder() }
    }

    /// Auto-reconnect wireless devices when they reappear on the network after a
    /// drop (e.g. Wi-Fi or hotspot coming back). Asked about on first drop.
    var autoReconnect: Bool {
        didSet { defaults.set(autoReconnect, forKey: Self.autoReconnectKey) }
    }

    /// True if the user has been asked about auto-reconnect at least once, so we
    /// don't keep prompting.
    var autoReconnectAsked: Bool {
        didSet { defaults.set(autoReconnectAsked, forKey: "MimicOS.autoReconnectAsked") }
    }

    /// Keep MimicOS running in the background (menu-bar agent) when the main
    /// window is closed, instead of quitting.
    var runInBackground: Bool {
        didSet { defaults.set(runInBackground, forKey: Self.runInBackgroundKey) }
    }

    /// Launch MimicOS automatically at login (so it returns after a reboot).
    var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: "MimicOS.launchAtLogin") }
    }

    /// Show the floating control sidebar docked to the phone screen while
    /// mirroring.
    var showSidebar: Bool {
        didSet { defaults.set(showSidebar, forKey: "MimicOS.showSidebar") }
    }

    /// Keep the phone window always on top of other apps.
    var alwaysOnTop: Bool {
        didSet { defaults.set(alwaysOnTop, forKey: Self.alwaysOnTopKey) }
    }

    /// Show a floating panel on the Mac when the phone has an incoming call, with
    /// Answer / Decline / Silence controls. Works without an active mirror.
    var callAlerts: Bool {
        didSet { defaults.set(callAlerts, forKey: Self.callAlertsKey) }
    }

    /// Destination folder on the phone for dropped files.
    var phoneDestFolder: String {
        didSet { defaults.set(phoneDestFolder, forKey: Self.phoneDestFolderKey) }
    }

    /// Hide MimicOS icon in the Dock
    var hideInDock: Bool {
        didSet {
            defaults.set(hideInDock, forKey: Self.hideInDockKey)
            Task { @MainActor in
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.syncActivationPolicy()
                }
            }
        }
    }

    /// Hide MimicOS status menu item in the Menu Bar
    var hideInMenuBar: Bool {
        didSet {
            defaults.set(hideInMenuBar, forKey: Self.hideInMenuBarKey)
            Task { @MainActor in
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.syncStatusItemVisibility()
                }
            }
        }
    }

    private static let phoneWindowFrameKey = "MimicOS.phoneWindowFrame"

    /// Persist the scrcpy mirror window's last frame (top-left origin, points)
    /// so the next mirror session reopens at the same spot and size.
    var phoneWindowFrame: CGRect? {
        get {
            guard let arr = defaults.array(forKey: Self.phoneWindowFrameKey) as? [Double],
                  arr.count == 4 else { return nil }
            return CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
        }
        set {
            if let f = newValue {
                defaults.set([f.origin.x, f.origin.y, f.width, f.height], forKey: Self.phoneWindowFrameKey)
            } else {
                defaults.removeObject(forKey: Self.phoneWindowFrameKey)
            }
        }
    }

    init() {
        // Reference UserDefaults directly here — the `defaults` computed property
        // touches `self`, which isn't allowed until all stored props are set.
        let store = UserDefaults.standard
        autoReconnect = store.object(forKey: Self.autoReconnectKey) as? Bool ?? true
        autoReconnectAsked = store.bool(forKey: "MimicOS.autoReconnectAsked")
        runInBackground = store.object(forKey: Self.runInBackgroundKey) as? Bool ?? true
        launchAtLogin = store.object(forKey: "MimicOS.launchAtLogin") as? Bool ?? true
        showSidebar = store.object(forKey: "MimicOS.showSidebar") as? Bool ?? false
        alwaysOnTop = store.object(forKey: Self.alwaysOnTopKey) as? Bool ?? false
        callAlerts = store.object(forKey: Self.callAlertsKey) as? Bool ?? true
        phoneDestFolder = store.string(forKey: Self.phoneDestFolderKey) ?? "/sdcard/Download/MimicOS"
        hideInDock = store.bool(forKey: Self.hideInDockKey)
        hideInMenuBar = store.bool(forKey: Self.hideInMenuBarKey)

        // Resolve the saved capture folder, falling back to ~/Downloads/MimicOS.
        let fallback = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MimicOS", isDirectory: true)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/MimicOS", isDirectory: true)

        if let bookmark = store.data(forKey: Self.captureFolderKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: [.withSecurityScope],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                captureFolder = url
            } else if let path = store.string(forKey: Self.captureFolderPathKey) {
                captureFolder = URL(fileURLWithPath: path, isDirectory: true)
            } else {
                captureFolder = fallback
            }
        } else if let path = store.string(forKey: Self.captureFolderPathKey) {
            captureFolder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            captureFolder = fallback
        }

        ensureCaptureFolderExists()
    }

    /// Creates the capture folder if it doesn't exist yet. Returns the folder.
    @discardableResult
    func ensureCaptureFolderExists() -> URL {
        try? FileManager.default.createDirectory(at: captureFolder,
                                                 withIntermediateDirectories: true)
        return captureFolder
    }

    private func persistCaptureFolder() {
        defaults.set(captureFolder.path, forKey: Self.captureFolderPathKey)
        // A security-scoped bookmark survives sandboxing/restarts when the user
        // picks a folder outside the app's default location.
        if let bookmark = try? captureFolder.bookmarkData(options: [.withSecurityScope],
                                                          includingResourceValuesForKeys: nil,
                                                          relativeTo: nil) {
            defaults.set(bookmark, forKey: Self.captureFolderKey)
        }
        ensureCaptureFolderExists()
    }
}
