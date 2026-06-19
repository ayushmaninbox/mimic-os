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

    // MARK: - Wireless discovery & pairing

    /// Live mDNS discovery of wireless-debugging phones on the LAN.
    let browser = BonjourBrowser()
    /// Convenience passthrough so views can read the discovered list.
    var discoveredPhones: [DiscoveredPhone] { browser.phones }

    /// Auto-discovered "host:port" of a phone showing its pairing screen, so the
    /// user only has to type the 6-digit code. nil until mDNS resolves one.
    var pairingHostPort: String? { browser.pairingHostPort }

    /// The active QR pairing session, if the user has opened the QR sheet.
    var pairingSession: QRPairing.Session?

    /// Drives the "Add Device" sheet opened by the + button.
    var showAddDevice: Bool = false

    var selectedDevice: Device? {
        devices.first { $0.serial == selectedSerial }
    }

    /// Number of currently-connected USB (non-wireless) devices — lets the USB
    /// guide light up "Detected!" the moment a phone is authorized.
    var usbDeviceCount: Int {
        devices.filter { !$0.isWireless && $0.state.isUsable }.count
    }

    // MARK: - Lifecycle

    func onAppear() async {
        guard toolsReady else {
            status = "adb / scrcpy not found — run Scripts/setup.sh first"
            return
        }
        await ADB.startServer()
        browser.start()
        await refreshDevices()
    }

    func onDisappear() {
        browser.stop()
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

    /// One-click connect to a phone that mDNS discovered. If the discovered
    /// service is a "connect" endpoint with a resolved address, we can connect
    /// straight away; a "pairing"-only endpoint means the user still needs to
    /// pair first (open the QR sheet or enter the code).
    func connect(to phone: DiscoveredPhone) async {
        switch phone.kind {
        case .connect:
            guard let hostPort = phone.hostPort else {
                status = "\(phone.name) found but not resolved yet — try again in a moment"
                return
            }
            await connectWireless(hostPort: hostPort)
        case .pairing:
            status = "\(phone.name) needs pairing first — show the QR or enter the code"
        }
    }

    /// Pairs using the 6-digit code, then immediately connects so the device
    /// becomes usable in one step. Host:port comes from mDNS autofill when
    /// available, otherwise from what the user typed.
    /// Returns true on a successful pair.
    @discardableResult
    func pairAndConnect(hostPort: String, code: String) async -> Bool {
        isWorking = true
        defer { isWorking = false }

        let pairResult = await ADB.pair(hostPort: hostPort, code: code)
        guard pairResult.succeeded else {
            status = "Pairing failed: \(pairResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) \(pairResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            return false
        }

        // After pairing, the connect port differs from the pairing port. mDNS
        // usually surfaces a `_adb-tls-connect._tcp` entry we can use; fall back
        // to the same host on the default 5555 if not yet discovered.
        status = "Paired. Connecting…"
        if let connectPhone = browser.phones.first(where: { $0.kind == .connect && $0.hostPort != nil }),
           let connectHostPort = connectPhone.hostPort {
            await connectWireless(hostPort: connectHostPort)
        } else {
            await connectWireless(hostPort: hostPort)
        }
        return true
    }

    // MARK: - QR pairing

    /// State machine for the QR pairing UI.
    enum QRPhase: Equatable {
        case showing          // QR is up, waiting for the phone to scan
        case pairing          // phone scanned; running adb pair
        case success
        case failed(String)
    }

    var qrPhase: QRPhase = .showing
    private var qrPollingTask: Task<Void, Never>?

    /// Opens a fresh QR pairing session and starts watching for the phone to
    /// scan it. Once the phone advertises our service name over mDNS, we pair.
    func startQRPairing() {
        qrPollingTask?.cancel()
        let session = QRPairing.newSession()
        pairingSession = session
        qrPhase = .showing
        status = "Scan the QR with the phone's 'Pair device with QR code'"
        qrPollingTask = Task { await self.watchForScan(session: session) }
    }

    /// Polls `adb mdns services` until the phone advertises a pairing service
    /// whose instance name matches our QR session, then runs `adb pair`.
    private func watchForScan(session: QRPairing.Session) async {
        // Poll for up to ~60s (the phone's QR screen times out around there).
        for _ in 0..<60 {
            if Task.isCancelled { return }

            let services = await ADB.mdnsServices()
            // The phone advertises a pairing service after scanning. Match our
            // service name when present; otherwise take any pairing service that
            // appeared (phones often append a suffix to the advertised name).
            let match = services.first { $0.isPairing && $0.instanceName.contains(session.serviceName) }
                ?? services.first { $0.isPairing }

            if let match {
                qrPhase = .pairing
                status = "Phone scanned — pairing…"
                let result = await ADB.pair(hostPort: match.hostPort, code: session.code)
                if result.succeeded {
                    qrPhase = .success
                    status = "Paired via QR. Connecting…"
                    await connectAfterPairing(pairingHostPort: match.hostPort)
                } else {
                    let detail = (result.stdout + " " + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                    qrPhase = .failed(detail.isEmpty ? "Pairing failed" : detail)
                    status = "QR pairing failed"
                }
                return
            }

            try? await Task.sleep(for: .seconds(1))
        }
        if !Task.isCancelled {
            qrPhase = .failed("Timed out waiting for the phone to scan the code.")
        }
    }

    /// After a successful pair, find the connect service and connect.
    private func connectAfterPairing(pairingHostPort: String) async {
        let services = await ADB.mdnsServices()
        if let connect = services.first(where: { $0.isConnect }) {
            await connectWireless(hostPort: connect.hostPort)
        } else {
            // Fall back to the same host on the default connect port.
            let host = pairingHostPort.split(separator: ":").first.map(String.init) ?? pairingHostPort
            await connectWireless(hostPort: "\(host):5555")
        }
    }

    func cancelQRPairing() {
        qrPollingTask?.cancel()
        qrPollingTask = nil
        pairingSession = nil
        qrPhase = .showing
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
