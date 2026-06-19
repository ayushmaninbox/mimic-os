import Foundation
import Observation

/// The app's central state and the bridge between the SwiftUI views and the
/// ADB/scrcpy engine. All UI-facing mutations happen on the main actor.
@MainActor
@Observable
final class AppModel {
    // MARK: - Published state

    /// Tabs in the main detail navbar.
    enum Tab: String, CaseIterable, Identifiable {
        case control = "Control"
        case files = "Files"
        case notifications = "Notifications"
        case settings = "Settings"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .control: return "rectangle.on.rectangle"
            case .files: return "folder"
            case .notifications: return "bell"
            case .settings: return "gearshape"
            }
        }
    }
    var selectedTab: Tab = .control

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

    var turnScreenOff: Bool = false
    var stayAwake: Bool = true

    // MARK: - Clipboard sync

    private let clipboard = ClipboardSync()
    /// When on, the Mac and phone clipboards stay in sync automatically. On by
    /// default; it activates once a usable device is selected.
    var clipboardSyncEnabled: Bool = true {
        didSet { applyClipboardSync() }
    }

    private func applyClipboardSync() {
        if clipboardSyncEnabled, let serial = selectedSerial,
           devices.contains(where: { $0.serial == serial && $0.state.isUsable }) {
            clipboard.start(serial: serial)
            status = "Clipboard sync on"
        } else {
            clipboard.stop()
        }
    }

    private let scrcpy = Scrcpy()

    /// Serial of the device currently being mirrored, or nil. This is observable
    /// (unlike `scrcpy.isRunning`), so the UI updates the moment we start/stop.
    private(set) var mirroringSerial: String?
    var isMirroring: Bool { mirroringSerial != nil }

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
        let names = DeviceStore.customNames()
        // Enrich with friendly model names + custom names, and remember the
        // ones that are connected so they persist when offline. Record a stable
        // hardware fingerprint (serialno prop) so the same phone connected via
        // both USB and Wi-Fi can be collapsed into one row.
        var fingerprintBySerial: [String: String] = [:]
        for index in found.indices {
            let serial = found[index].serial
            found[index].customName = names[serial]
            if found[index].state.isUsable {
                found[index].model = await ADB.model(serial)
                fingerprintBySerial[serial] = await ADB.getProp(serial, "ro.serialno") ?? serial
                // Only remember stable USB serials. Wireless serials are an
                // ephemeral ip:port (hotspot IPs change), so persisting them
                // just creates stale ghost rows — they're rediscovered via mDNS.
                if !found[index].isWireless {
                    DeviceStore.remember(serial)
                }
            }
        }

        // Collapse duplicates of the same physical phone (USB + wireless show up
        // as two adb serials). Prefer the wireless entry, since it survives
        // unplugging; fall back to the first seen.
        var seenFingerprints: [String: Int] = [:]   // fingerprint -> index kept
        var deduped: [Device] = []
        for device in found {
            guard device.state.isUsable,
                  let fp = fingerprintBySerial[device.serial] else {
                deduped.append(device)
                continue
            }
            if let keptIndex = seenFingerprints[fp] {
                // Already have this phone — keep whichever is wireless.
                if device.isWireless && !deduped[keptIndex].isWireless {
                    deduped[keptIndex] = device
                }
            } else {
                seenFingerprints[fp] = deduped.count
                deduped.append(device)
            }
        }
        found = deduped

        // Append remembered devices that aren't currently connected, as offline
        // entries — but skip any whose custom name already matches a connected
        // device (avoids a ghost row for a phone that reconnected on a new IP).
        let connectedSerials = Set(found.map(\.serial))
        let connectedNames = Set(found.compactMap { $0.customName })
        for serial in DeviceStore.knownSerials() where !connectedSerials.contains(serial) {
            let name = names[serial]
            if let name, connectedNames.contains(name) { continue }
            found.append(Device(serial: serial, state: .offline,
                                model: nil, customName: name, isOffline: true))
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

        let onlineCount = found.filter { $0.state.isUsable }.count
        status = onlineCount == 0
            ? "No devices connected. Use + to add one."
            : "\(onlineCount) device(s) connected"
    }

    // MARK: - Rename / connect / disconnect / forget

    func rename(_ serial: String, to name: String) {
        DeviceStore.setCustomName(name, for: serial)
        if let index = devices.firstIndex(where: { $0.serial == serial }) {
            devices[index].customName = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
        }
    }

    /// Reconnect a remembered wireless device (USB devices reconnect on plug-in).
    func reconnect(_ device: Device) async {
        guard device.isWireless else {
            status = "Plug in \(device.displayName) over USB to reconnect."
            return
        }
        await connectWireless(hostPort: device.serial)
    }

    /// Drop the connection but keep the device remembered.
    func disconnect(_ device: Device) async {
        if mirroringSerial == device.serial {
            scrcpy.stop()
            mirroringSerial = nil
        }
        if device.isWireless {
            _ = await ADB.disconnect(hostPort: device.serial)
        }
        if selectedSerial == device.serial { selectedSerial = nil; info = nil }
        await refreshDevices()
        status = "Disconnected \(device.displayName)"
    }

    /// Disconnect AND forget: remove from the remembered list and clear its name.
    func forget(_ device: Device) async {
        if device.state.isUsable, device.isWireless {
            _ = await ADB.disconnect(hostPort: device.serial)
        }
        if mirroringSerial == device.serial {
            scrcpy.stop()
            mirroringSerial = nil
        }
        DeviceStore.forget(device.serial)
        if selectedSerial == device.serial { selectedSerial = nil; info = nil }
        await refreshDevices()
        status = "Removed \(device.displayName)"
    }

    func select(_ serial: String) async {
        selectedSerial = serial
        info = await ADB.info(serial)
        notifications = await ADB.notificationSnapshot(serial)
        applyClipboardSync()   // re-point sync at the newly selected device
    }

    // MARK: - Mirroring

    func toggleMirror() {
        guard let serial = selectedSerial else {
            status = "Select a device first"
            return
        }
        if isMirroring {
            scrcpy.stop()
            mirroringSerial = nil
            status = "Mirror stopped"
        } else {
            var options = Scrcpy.Options()
            options.turnScreenOff = turnScreenOff
            options.stayAwake = stayAwake
            // Clear our observable state when scrcpy exits on its own (e.g. the
            // user closes the mirror window) so the button flips back to Start.
            let ok = scrcpy.start(serial: serial, options: options) { [weak self] in
                Task { @MainActor in
                    if self?.mirroringSerial == serial {
                        self?.mirroringSerial = nil
                        self?.status = "Mirror stopped"
                    }
                }
            }
            mirroringSerial = ok ? serial : nil
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

    // MARK: - USB -> wireless over hotspot (no Wi-Fi / Wireless-debugging needed)

    /// Phases for the hotspot "go wireless" flow, surfaced to the UI.
    enum HotspotPhase: Equatable {
        case idle
        case needsUSB                 // no USB device detected yet
        case working(String)          // a step is running (message)
        case connected(String)        // now reachable wirelessly at host:port
        case failed(String)
    }

    var hotspotPhase: HotspotPhase = .idle

    /// The one-click flow: requires a USB-connected device. Detects the phone's
    /// reachable IP over USB, flips it to TCP/IP, then connects over the network
    /// so the cable can be unplugged. Works while the phone shares a hotspot.
    func goWirelessOverHotspot() async {
        guard let usb = devices.first(where: { !$0.isWireless && $0.state.isUsable }) else {
            hotspotPhase = .needsUSB
            status = "Plug the phone in via USB first."
            return
        }

        hotspotPhase = .working("Finding the phone's address…")
        let ip = await ADB.wirelessIP(usb.serial)
        guard let ip else {
            hotspotPhase = .failed("Couldn't detect the phone's IP. Make sure the hotspot is on and the Mac is joined to it.")
            return
        }

        hotspotPhase = .working("Switching the phone to wireless…")
        let tcpip = await ADB.enableTcpip(usb.serial, port: 5555)
        guard tcpip.succeeded else {
            hotspotPhase = .failed("Couldn't enable wireless mode: \(tcpip.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            return
        }

        // The daemon needs a moment to restart in TCP/IP mode before it accepts
        // a network connection.
        try? await Task.sleep(for: .seconds(1))

        let hostPort = "\(ip):5555"
        hotspotPhase = .working("Connecting to \(hostPort)…")
        let connect = await ADB.connect(hostPort: hostPort)
        await refreshDevices()

        if devices.contains(where: { $0.serial == hostPort && $0.state.isUsable }) {
            hotspotPhase = .connected(hostPort)
            status = "Wireless over hotspot — you can unplug the USB cable now."
        } else {
            let detail = (connect.stdout + " " + connect.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            hotspotPhase = .failed("Connected command ran but device isn't ready: \(detail)")
        }
    }

    func resetHotspotPhase() { hotspotPhase = .idle }

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

    // MARK: - File browser

    /// Current directory shown in the in-app file browser.
    var browsePath: String = "/sdcard/"
    var browseFiles: [ADB.RemoteFile] = []
    var isBrowsing: Bool = false

    /// In-flight / recent file transfers, shown as progress bars in the UI.
    struct Transfer: Identifiable {
        let id = UUID()
        let name: String
        let direction: Direction
        var totalBytes: Int64?       // known up front for the source file
        var fraction: Double = 0     // 0...1, computed by polling the dest size
        var done: Bool = false
        var failed: Bool = false
        enum Direction { case toPhone, toMac }

        /// True when we can show a determinate bar (we know the total size).
        var isDeterminate: Bool { (totalBytes ?? 0) > 0 }
    }
    var transfers: [Transfer] = []

    private func addTransfer(_ name: String, _ dir: Transfer.Direction, totalBytes: Int64?) -> UUID {
        let t = Transfer(name: name, direction: dir, totalBytes: totalBytes)
        transfers.append(t)
        return t.id
    }

    private func updateProgress(_ id: UUID, fraction: Double) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        // Never go backwards or hit 100% before we mark it done.
        transfers[idx].fraction = max(transfers[idx].fraction, min(fraction, 0.99))
    }

    private func finishTransfer(_ id: UUID, failed: Bool) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[idx].done = true
        transfers[idx].failed = failed
        transfers[idx].fraction = failed ? transfers[idx].fraction : 1
        if !failed {
            let tid = id
            Task {
                try? await Task.sleep(for: .seconds(4))
                transfers.removeAll { $0.id == tid }
            }
        }
    }

    func clearTransfer(_ id: UUID) {
        transfers.removeAll { $0.id == id }
    }

    /// Local file size on the Mac (for source totals and pull progress).
    private func localSize(_ path: String) -> Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value
    }

    /// Polls the destination file's growing size to drive a real progress bar
    /// while the adb transfer runs. Cancelled when the transfer finishes.
    private func pollProgress(id: UUID, total: Int64,
                              currentBytes: @escaping @Sendable () async -> Int64?) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                if let now = await currentBytes() {
                    await MainActor.run { self?.updateProgress(id, fraction: Double(now) / Double(total)) }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// True once we're somewhere below the starting root, so "up" makes sense.
    var canGoUp: Bool { browsePath != "/" && browsePath != "/sdcard/" }

    func loadFiles(path: String? = nil) async {
        guard let serial = selectedSerial else { return }
        if let path { browsePath = path }
        isBrowsing = true
        defer { isBrowsing = false }
        browseFiles = await ADB.listFiles(serial, path: browsePath)
    }

    func openFolder(_ file: ADB.RemoteFile) async {
        guard file.isDirectory else { return }
        await loadFiles(path: file.path + "/")
    }

    func goUp() async {
        var trimmed = browsePath
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        let parent = (trimmed as NSString).deletingLastPathComponent
        await loadFiles(path: parent.isEmpty ? "/" : parent + "/")
    }

    /// Copy a file/folder from the phone to a chosen Mac folder (with progress).
    func downloadFromPhone(_ file: ADB.RemoteFile, toLocalDir localDir: String) async {
        guard let serial = selectedSerial else { return }
        let total = file.sizeBytes
        let id = addTransfer(file.name, .toMac, totalBytes: total)

        // Poll the growing local file to show a real bar (only for plain files).
        let localFile = (localDir as NSString).appendingPathComponent(file.name)
        var poller: Task<Void, Never>?
        if let total, total > 0, !file.isDirectory {
            poller = pollProgress(id: id, total: total) { [localFile] in
                let attrs = try? FileManager.default.attributesOfItem(atPath: localFile)
                return (attrs?[.size] as? NSNumber)?.int64Value
            }
        }

        let result = await ADB.pull(serial, remotePath: file.path, localPath: localDir)
        poller?.cancel()
        finishTransfer(id, failed: !result.succeeded)
        status = result.succeeded ? "Copied \(file.name) to Mac"
            : "Copy failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Copy one or more Mac files into the directory currently shown (with progress).
    func uploadToCurrentFolder(localPaths: [String]) async {
        guard let serial = selectedSerial else { return }
        for localPath in localPaths {
            let name = (localPath as NSString).lastPathComponent
            let total = localSize(localPath)
            let id = addTransfer(name, .toPhone, totalBytes: total)

            // Poll the growing file on the phone to show a real progress bar.
            let base = browsePath.hasSuffix("/") ? browsePath : browsePath + "/"
            let remoteFile = base + name
            var poller: Task<Void, Never>?
            if let total, total > 0 {
                poller = pollProgress(id: id, total: total) { [serial, remoteFile] in
                    await ADB.fileSize(serial, path: remoteFile)
                }
            }

            let result = await ADB.push(serial, localPath: localPath, remotePath: browsePath)
            poller?.cancel()
            finishTransfer(id, failed: !result.succeeded)
            if !result.succeeded {
                status = "Copy failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
        status = "Copied to phone"
        await loadFiles()
    }

    /// Delete a file/folder on the phone.
    func deleteFromPhone(_ file: ADB.RemoteFile) async {
        guard let serial = selectedSerial else { return }
        let result = await ADB.delete(serial, path: file.path)
        status = result.succeeded ? "Deleted \(file.name)" : "Delete failed"
        await loadFiles()
    }

    /// Create a new folder in the current directory.
    func makeFolder(named name: String) async {
        guard let serial = selectedSerial, !name.isEmpty else { return }
        let base = browsePath.hasSuffix("/") ? browsePath : browsePath + "/"
        _ = await ADB.makeDirectory(serial, path: base + name)
        await loadFiles()
    }

    /// Pulls a phone file to a temp dir and returns the local URL, for drag-out
    /// to Finder. Returns nil on failure.
    func stageForDragOut(_ file: ADB.RemoteFile) async -> URL? {
        guard let serial = selectedSerial else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("iDroid-dragout", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let id = addTransfer(file.name, .toMac, totalBytes: file.sizeBytes)
        let staged = tmp.appendingPathComponent(file.name)
        var poller: Task<Void, Never>?
        if let total = file.sizeBytes, total > 0, !file.isDirectory {
            poller = pollProgress(id: id, total: total) { [staged] in
                let attrs = try? FileManager.default.attributesOfItem(atPath: staged.path)
                return (attrs?[.size] as? NSNumber)?.int64Value
            }
        }
        let result = await ADB.pull(serial, remotePath: file.path, localPath: tmp.path)
        poller?.cancel()
        finishTransfer(id, failed: !result.succeeded)
        guard result.succeeded else { return nil }
        return staged
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
