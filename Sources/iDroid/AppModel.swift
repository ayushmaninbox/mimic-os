import Foundation
import Observation

/// The app's central state and the bridge between the SwiftUI views and the
/// ADB/scrcpy engine. All UI-facing mutations happen on the main actor.
@MainActor
@Observable
final class AppModel {
    // MARK: - Published state

    var devices: [Device] = []
    var selectedSerial: String?
    var info: DeviceInfo?
    var notifications: [String] = []

    /// Human-readable status line shown at the bottom of the window.
    var status: String = "Welcome to iDroid"

    /// True while a background refresh/command is in flight.
    var isWorking: Bool = false

    // MARK: - Tooling readiness

    var adbInstalled: Bool { ADB.isInstalled }
    var scrcpyInstalled: Bool { Scrcpy.isInstalled }
    var toolsReady: Bool { adbInstalled && scrcpyInstalled }

    // MARK: - Mirror options (bound to the UI)

    var turnScreenOff: Bool = true
    var stayAwake: Bool = true

    private let scrcpy = Scrcpy()
    var isMirroring: Bool { scrcpy.isRunning }

    var selectedDevice: Device? {
        devices.first { $0.serial == selectedSerial }
    }

    // MARK: - Lifecycle

    func onAppear() async {
        guard toolsReady else {
            status = "adb / scrcpy not found — run Scripts/setup.sh first"
            return
        }
        await ADB.startServer()
        await refreshDevices()
    }

    // MARK: - Devices

    func refreshDevices() async {
        guard adbInstalled else { return }
        isWorking = true
        defer { isWorking = false }

        var found = await ADB.listDevices()
        // Enrich with friendly model names.
        for index in found.indices where found[index].state.isUsable {
            found[index].model = await ADB.model(found[index].serial)
        }
        devices = found

        // Keep a valid selection.
        if let selectedSerial, !found.contains(where: { $0.serial == selectedSerial }) {
            self.selectedSerial = nil
            self.info = nil
        }
        if selectedSerial == nil, let first = found.first(where: { $0.state.isUsable }) {
            await select(first.serial)
        }

        status = found.isEmpty
            ? "No devices. Connect via USB with debugging enabled."
            : "\(found.count) device(s) connected"
    }

    func select(_ serial: String) async {
        selectedSerial = serial
        info = await ADB.info(serial)
        notifications = await ADB.notificationSnapshot(serial)
    }

    // MARK: - Mirroring

    func toggleMirror() {
        guard let serial = selectedSerial else {
            status = "Select a device first"
            return
        }
        if scrcpy.isRunning {
            scrcpy.stop()
            status = "Mirror stopped"
        } else {
            var options = Scrcpy.Options()
            options.turnScreenOff = turnScreenOff
            options.stayAwake = stayAwake
            let ok = scrcpy.start(serial: serial, options: options)
            status = ok
                ? (turnScreenOff ? "Mirroring (phone screen off)" : "Mirroring")
                : "Failed to start scrcpy"
        }
    }

    // MARK: - Wireless

    func pairWireless(hostPort: String, code: String) async {
        isWorking = true
        defer { isWorking = false }
        let result = await ADB.pair(hostPort: hostPort, code: code)
        status = result.succeeded ? "Paired \(hostPort)" : "Pair failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    func connectWireless(hostPort: String) async {
        isWorking = true
        defer { isWorking = false }
        let result = await ADB.connect(hostPort: hostPort)
        status = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        await refreshDevices()
    }

    // MARK: - Files

    func pushFile(localPath: String) async {
        guard let serial = selectedSerial else { return }
        isWorking = true
        defer { isWorking = false }
        let result = await ADB.push(serial, localPath: localPath)
        status = result.succeeded ? "Pushed to /sdcard/Download/" : "Push failed"
    }

    func installAPK(localPath: String) async {
        guard let serial = selectedSerial else { return }
        isWorking = true
        defer { isWorking = false }
        let result = await ADB.installAPK(serial, apkPath: localPath)
        status = result.succeeded ? "APK installed" : "Install failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    // MARK: - Automation shortcuts

    func pressHome() async {
        guard let serial = selectedSerial else { return }
        await ADB.keyEvent(serial, keycode: 3)
        status = "HOME"
    }

    func pressBack() async {
        guard let serial = selectedSerial else { return }
        await ADB.keyEvent(serial, keycode: 4)
        status = "BACK"
    }

    func togglePower() async {
        guard let serial = selectedSerial else { return }
        await ADB.keyEvent(serial, keycode: 26)
        status = "POWER"
    }
}
