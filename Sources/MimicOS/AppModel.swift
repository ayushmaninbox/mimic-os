import Foundation
import Observation
import AppKit
import AVFoundation
import QuickLook
import ApplicationServices

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
        case settings = "Settings"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .control: return "rectangle.on.rectangle"
            case .files: return "folder"
            case .settings: return "gearshape"
            }
        }
    }
    var selectedTab: Tab = .control

    var devices: [Device] = []
    var rawDevices: [Device] = []
    var previousPresentSerials: Set<String> = []
    var selectedSerial: String?
    var info: DeviceInfo?

    /// Human-readable status line shown at the bottom of the window.
    var status: String = "Welcome to MimicOS"

    /// True while a background refresh/command is in flight.
    var isWorking: Bool = false
    /// True while a wireless pairing or connection attempt is in progress.
    var isConnecting: Bool = false

    // MARK: - Tooling readiness

    var adbInstalled: Bool { ADB.isInstalled }
    var scrcpyInstalled: Bool { Scrcpy.isInstalled }
    var toolsReady: Bool { adbInstalled && scrcpyInstalled }

    // MARK: - Mirror options (bound to the UI)

    var turnScreenOff: Bool = false
    var stayAwake: Bool = true
    var useHIDKeyboard: Bool = false
    /// Where the phone's audio plays while mirroring.
    var audioRoute: Scrcpy.AudioRoute = .mac

    // MARK: - Clipboard sync
    //
    // Modern Android (≈13+, confirmed gone on Android 16) removed the
    // `cmd clipboard` shell interface, so there is NO app-free way to read/write
    // the phone clipboard over adb. The working channel is scrcpy's own
    // clipboard sync, which is automatic while a mirror session is focused.
    // This flag just reflects that scrcpy handles it; there's no background
    // poller to run.

    /// Background clipboard sync via a headless scrcpy session. ON by default
    /// per user preference. (Note: on Android 16 the headless session can be
    /// flaky over a fragile wireless link; clipboard always syncs reliably
    /// during real mirroring.)
    var clipboardSyncEnabled: Bool = true {
        didSet {
            updateBackgroundClipboardSync()
        }
    }

    /// Global preferences (capture folder, auto-reconnect, pin, background).
    let settings = AppSettings()

    /// Shared, event-driven tracker for scrcpy's window (drives the floating
    /// remote off live AXObserver callbacks — no polling — and enforces the
    /// window's minimum size).
    @ObservationIgnored private let windowTracker = ScrcpyWindowTracker()

    /// The attached floating remote-control window shown beside the phone screen.
    @ObservationIgnored let floatingRemote = FloatingRemoteController()

    private let scrcpy = Scrcpy()
    private let headlessScrcpy = Scrcpy()
    private var headlessSerial: String?

    /// Stable window title handed to scrcpy so the tracker can find its window.
    private var mirrorWindowTitle: String?

    /// Serial of the device currently being mirrored, or nil. This is observable
    /// (unlike `scrcpy.isRunning`), so the UI updates the moment we start/stop.
    private(set) var mirroringSerial: String?
    var isMirroring: Bool { mirroringSerial != nil }

    /// Drives the "Add Device" sheet opened by the + button.
    var showAddDevice: Bool = false

    var selectedDevice: Device? {
        devices.first { $0.serial == selectedSerial }
    }

    /// Number of currently-connected USB (non-wireless) devices — lets the USB
    /// guide light up "Detected!" the moment a phone is authorized.
    var usbDeviceCount: Int {
        rawDevices.filter { !$0.isWireless && $0.state.isUsable }.count
    }

    // MARK: - Lifecycle

    func onAppear() async {
        guard toolsReady else {
            status = "adb / scrcpy not found — run Scripts/setup.sh first"
            return
        }
        await ADB.startServer()
        await refreshDevices()
        startBackgroundMonitor()
        // Match the OS login-item state to the saved preference.
        LoginItem.sync(desired: settings.launchAtLogin)
    }

    /// Set launch-at-login and reflect the actual OS result back into settings
    /// (registration can fail when running unsigned / as a bare binary).
    func setLaunchAtLogin(_ enabled: Bool) {
        let ok = LoginItem.setEnabled(enabled)
        settings.launchAtLogin = ok ? enabled : LoginItem.isEnabled
        if !ok {
            status = "Couldn't change login item (needs the packaged app)."
        }
    }

    func onDisappear() {
        // Nothing to tear down here; the background monitor and trackers are
        // owned by the model and cleaned up on quit.
    }

    /// Tear down everything that outlives the UI: the scrcpy mirror window, the
    /// headless clipboard session, the floating remote, and any in-flight
    /// recording. Called from the app delegate on quit so no orphan windows or
    /// child processes are left behind.
    func shutdown() {
        if isRecording {
            recorder.interruptRecording()
            recorder.forceStopRecording()
        }
        windowTracker.stop()
        floatingRemote.hide()
        mirroringSerial = nil
        mirrorWindowTitle = nil
        scrcpy.stop()
        headlessScrcpy.stop()
        // Sweep any orphaned scrcpy processes so nothing lingers after quit.
        Scrcpy.killAll()
    }

    // MARK: - Background device monitor (powers auto-reconnect)

    @ObservationIgnored private var monitorTask: Task<Void, Never>?

    /// Serials of wireless devices that were connected and then dropped, so we
    /// know which ones to auto-reconnect when they come back on the network.
    @ObservationIgnored private var droppedWirelessSerials: Set<String> = []

    /// Wireless serials that were usable on the previous refresh, used to detect
    /// the moment one drops off.
    @ObservationIgnored private var previouslyUsableWirelessSerials: Set<String> = []

    /// True for a wireless `ip:port` serial.
    private func isWirelessSerial(_ serial: String) -> Bool {
        serial.contains(":") && serial.split(separator: ":").first.map { $0.contains(".") } == true
    }

    /// On the very first wireless drop, ask the user whether to enable
    /// auto-reconnect (only once — the answer is remembered).
    private func maybePromptAutoReconnect(for serial: String) {
        guard !settings.autoReconnectAsked else { return }
        settings.autoReconnectAsked = true
        autoReconnectPrompt = displayName(for: serial)
    }

    /// Resolve the auto-reconnect prompt with the user's choice.
    func answerAutoReconnectPrompt(enable: Bool) {
        settings.autoReconnect = enable
        autoReconnectPrompt = nil
        status = enable ? "Auto-reconnect on" : "Auto-reconnect off"
    }

    /// Pending request to ask the user whether to enable auto-reconnect. The UI
    /// observes this and shows a one-time prompt on the first wireless drop.
    var autoReconnectPrompt: String?

    /// Periodically refreshes the device list at a low cadence so drops and
    /// returns are noticed even when the window is idle. Lightweight: a single
    /// `adb devices` every few seconds, scaled back when nothing's connected.
    private func startBackgroundMonitor() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                // Idle-friendly cadence: 3s when something is connected (so we
                // catch drops quickly), 6s when nothing is, to stay near-zero CPU.
                let anyConnected = await MainActor.run {
                    self?.devices.contains { $0.state.isUsable } ?? false
                }
                try? await Task.sleep(for: .seconds(anyConnected ? 3 : 6))
                guard let self, !Task.isCancelled else { return }
                await self.monitorTick()
            }
        }
    }

    /// One monitor pass: refresh, then auto-reconnect any wireless device that
    /// had dropped and is now reachable again (if the setting is on).
    private func monitorTick() async {
        guard toolsReady, !isWorking, !isConnecting else { return }
        await refreshDevices()
        await attemptAutoReconnects()
    }

    /// Tracks transitions to offline for wireless devices and tries to bring back
    /// any that have reappeared. Called from the monitor and after each refresh.
    private func attemptAutoReconnects() async {
        guard settings.autoReconnect else { return }

        // Snapshot so we can safely mutate the set inside the loop.
        for serial in Array(droppedWirelessSerials) {
            // If this dropped wireless serial is reachable again, reconnect it.
            let connected = await ADB.connectVerified(hostPort: serial, attempts: 1)
            if connected {
                DeviceStore.connect(serial)
                droppedWirelessSerials.remove(serial)
                await refreshDevices()
                status = "Auto-reconnected \(displayName(for: serial))"
            }
        }
    }

    private func displayName(for serial: String) -> String {
        devices.first { $0.serial == serial }?.displayName ?? serial
    }

    // MARK: - Devices

    func refreshDevices() async {
        guard adbInstalled else { return }
        isWorking = true
        defer { isWorking = false }

        let foundRaw = await ADB.listDevices()
        self.rawDevices = foundRaw
        var found = foundRaw
        let names = DeviceStore.customNames()

        // If a USB device is newly discovered (usable but not in known list yet),
        // do not automatically connect it. Force it to be disconnected at first.
        let known = Set(DeviceStore.knownSerials())
        for index in found.indices {
            let serial = found[index].serial
            let isWireless = serial.contains(":") && serial.split(separator: ":").first.map { $0.contains(".") } == true
            if found[index].state.isUsable && !isWireless && !known.contains(serial) {
                DeviceStore.disconnect(serial)
            }
        }

        let currentlyPresentSerials = Set(found.map(\.serial))

        // Detect wireless devices that just dropped (were usable last refresh,
        // now absent or offline and not deliberately disconnected) so the
        // auto-reconnect monitor can bring them back when they reappear.
        let usableNow = Set(foundRaw.filter { $0.state.isUsable }.map(\.serial))
        let manuallyDisconnected = DeviceStore.disconnectedSerials()
        for serial in previouslyUsableWirelessSerials where !usableNow.contains(serial) {
            guard !manuallyDisconnected.contains(serial) else { continue }
            if droppedWirelessSerials.insert(serial).inserted {
                maybePromptAutoReconnect(for: serial)
            }
        }
        // Remember which wireless serials are usable this pass for next time.
        previouslyUsableWirelessSerials = Set(
            foundRaw.filter { $0.state.isUsable && isWirelessSerial($0.serial) }.map(\.serial)
        )

        previousPresentSerials = currentlyPresentSerials

        // Enrich with friendly model names + custom names, and remember the
        // ones that are connected so they persist when offline. Record a stable
        // hardware fingerprint (serialno prop) so the same phone connected via
        // both USB and Wi-Fi can be collapsed into one row.
        var fingerprintBySerial: [String: String] = [:]
        for index in found.indices {
            let serial = found[index].serial
            
            // Override state to offline if manually disconnected / ignored
            if DeviceStore.disconnectedSerials().contains(serial) {
                found[index] = Device(serial: serial, state: .offline, model: found[index].model, customName: names[serial])
            }

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

        if let serial = mirroringSerial,
           let device = found.first(where: { $0.serial == serial }),
           !device.state.isUsable {
            scrcpy.stop()
            mirroringSerial = nil
            status = "Mirror stopped (device disconnected)"
        }

        // Keep a valid selection.
        if let selectedSerial, !found.contains(where: { $0.serial == selectedSerial }) {
            self.selectedSerial = nil
            self.info = nil
        }
        if selectedSerial == nil, let first = found.first(where: { $0.state.isUsable }) {
            await select(first.serial)
        }
        updateBackgroundClipboardSync()

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
        DeviceStore.connect(device.serial)
        DeviceStore.remember(device.serial)
        guard device.isWireless else {
            await refreshDevices()
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        await connectWireless(hostPort: device.serial)
    }

    /// Drop the connection but keep the device remembered.
    func disconnect(_ device: Device) async {
        DeviceStore.disconnect(device.serial)
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
        if device.isWireless {
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
        updateBackgroundClipboardSync()
        startScreenshotWatch()
    }

    // MARK: - Phone screenshot -> Mac clipboard

    private var screenshotWatchTask: Task<Void, Never>?
    private var lastSeenScreenshot: String?

    /// Whether to mirror phone screenshots onto the Mac's clipboard.
    var copyPhoneScreenshotsToMac: Bool = true {
        didSet { startScreenshotWatch() }
    }

    /// Polls the phone's Screenshots folder; when a new file appears, pulls it
    /// and places the image on the Mac clipboard. (Android 16 blocks reading the
    /// phone clipboard over adb, so we watch the folder instead — the reliable
    /// app-free path.)
    private func startScreenshotWatch() {
        screenshotWatchTask?.cancel()
        guard copyPhoneScreenshotsToMac, let serial = selectedSerial,
              devices.contains(where: { $0.serial == serial && $0.state.isUsable }) else { return }

        screenshotWatchTask = Task { [weak self] in
            // Seed the baseline so we don't grab an old screenshot on connect.
            self?.lastSeenScreenshot = await ADB.latestScreenshotPath(serial)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let latest = await ADB.latestScreenshotPath(serial)
                if let latest, latest != self.lastSeenScreenshot {
                    self.lastSeenScreenshot = latest
                    await self.copyScreenshotToMacClipboard(serial: serial, remotePath: latest)
                }
            }
        }
    }

    private func copyScreenshotToMacClipboard(serial: String, remotePath: String) async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimicOS-shot-\(UUID().uuidString).png")
        let result = await ADB.pull(serial, remotePath: remotePath, localPath: tmp.path)
        guard result.succeeded, let image = NSImage(contentsOf: tmp) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        status = "Phone screenshot copied to Mac clipboard"
    }

    // MARK: - Mirroring

    func toggleMirror() {
        guard let serial = selectedSerial else {
            status = "Select a device first"
            return
        }
        if isMirroring {
            stopMirror()
        } else {
            startMirror(serial: serial, restarting: false)
        }
    }

    /// (Re)start the scrcpy mirror for `serial`. When `restarting` is true we
    /// keep the current window frame (so a live settings change reopens in the
    /// same spot) and don't touch the headless clipboard session.
    private func startMirror(serial: String, restarting: Bool) {
        if !restarting {
            headlessScrcpy.stop()
            headlessSerial = nil
        }

        let title = "MimicOS — \(selectedDevice?.displayName ?? serial)"
        mirrorWindowTitle = title

        var options = Scrcpy.Options()
        options.turnScreenOff = turnScreenOff
        options.stayAwake = stayAwake
        options.useHIDKeyboard = useHIDKeyboard
        options.audio = audioRoute
        options.windowTitle = title
        // Reopen where the user last left the phone window (current frame on a
        // live restart, otherwise the persisted one).
        options.windowFrame = (restarting ? windowTracker.currentFrame : nil) ?? settings.phoneWindowFrame

        // Each start gets a unique token. An exit handler only tears the session
        // down if it's still the current one — so an intentional restart (which
        // bumps the token before the old process's async handler runs) won't kill
        // the fresh session. Race-free, unlike a plain "is restarting" flag.
        mirrorGeneration &+= 1
        let token = mirrorGeneration

        let ok = scrcpy.start(serial: serial, options: options) { [weak self] status, errText in
            Task { @MainActor in
                guard let self, self.mirrorGeneration == token,
                      self.mirroringSerial == serial else { return }
                self.persistPhoneWindowFrame()
                self.mirroringSerial = nil
                self.windowTracker.stop()
                self.floatingRemote.hide()
                self.mirrorWindowTitle = nil
                if status != 0 && !errText.isEmpty {
                    let cleanErr = errText.split(separator: "\n").last.map(String.init) ?? errText
                    self.status = "Mirror failed: \(cleanErr.trimmingCharacters(in: .whitespacesAndNewlines))"
                } else {
                    self.status = "Mirror stopped"
                }
                self.updateBackgroundClipboardSync()
            }
        }
        mirroringSerial = ok ? serial : nil
        status = ok
            ? (turnScreenOff ? "Mirroring (phone screen off)" : "Mirroring")
            : "Failed to start scrcpy"

        if ok { beginWindowTracking(title: title) }
    }

    /// Bumped on every scrcpy (re)start; old exit handlers compare against it.
    @ObservationIgnored private var mirrorGeneration = 0

    /// Apply mirror-affecting settings (screen-off, awake, UHID, audio) to the
    /// live session by restarting scrcpy in place. No-op when not mirroring.
    func applyMirrorSettingsLive() {
        guard isMirroring, let serial = mirroringSerial else { return }
        // Capture the current frame so the new window reopens in the same place.
        if let frame = windowTracker.currentFrame { settings.phoneWindowFrame = frame }
        windowTracker.stop()
        // startMirror bumps the generation token, so the old process's exit
        // handler is ignored when it fires.
        scrcpy.stop()
        startMirror(serial: serial, restarting: true)
        status = "Updated mirror settings"
    }

    /// Stop mirroring and tear down tracking / floating remote, saving the
    /// window's last frame first.
    private func stopMirror() {
        persistPhoneWindowFrame()
        mirroringSerial = nil
        windowTracker.stop()
        floatingRemote.hide()
        mirrorWindowTitle = nil
        scrcpy.stop()
        status = "Mirror stopped"
        updateBackgroundClipboardSync()
    }

    /// Hook the shared window tracker so move/resize events drive the floating
    /// remote with zero polling lag (and enforce the window's minimum size).
    private func beginWindowTracking(title: String) {
        if settings.showSidebar, !AXIsProcessTrusted() {
            // The sidebar follows scrcpy's window via the Accessibility API.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            status = "Grant MimicOS Accessibility access (System Settings ▸ Privacy) so the sidebar can follow the phone window."
        }

        windowTracker.onAppear = { [weak self] frame in
            guard let self else { return }
            if self.settings.showSidebar {
                self.floatingRemote.show(model: self)
                self.floatingRemote.update(for: frame, phoneWindowID: self.windowTracker.windowID)
            }
        }
        windowTracker.onFrameChange = { [weak self] frame in
            guard let self else { return }
            if self.settings.showSidebar {
                self.floatingRemote.update(for: frame, phoneWindowID: self.windowTracker.windowID)
            }
        }
        windowTracker.onDisappear = { [weak self] in
            self?.floatingRemote.hideTemporarily()
        }
        windowTracker.onRaise = { [weak self] in
            guard let self, self.settings.showSidebar else { return }
            self.floatingRemote.raiseWithPhoneWindow(self.windowTracker.windowID)
        }

        windowTracker.start(windowTitle: title)
    }

    /// Save the scrcpy window's current frame so the next session restores it.
    private func persistPhoneWindowFrame() {
        if let frame = windowTracker.currentFrame {
            settings.phoneWindowFrame = frame
        }
    }

    /// Toggle the floating sidebar's visibility (live, persisted).
    func setSidebarVisible(_ visible: Bool) {
        settings.showSidebar = visible
        floatingRemote.setEnabled(visible)
        if visible, isMirroring, let frame = windowTracker.currentFrame {
            floatingRemote.show(model: self)
            floatingRemote.update(for: frame, phoneWindowID: windowTracker.windowID)
        }
    }

    func updateBackgroundClipboardSync() {
        guard clipboardSyncEnabled && toolsReady else {
            if headlessSerial != nil {
                headlessScrcpy.stop()
                headlessSerial = nil
            }
            return
        }

        guard let serial = selectedSerial,
              let device = selectedDevice,
              device.state.isUsable,
              !isMirroring else {
            if headlessSerial != nil {
                headlessScrcpy.stop()
                headlessSerial = nil
            }
            return
        }

        if headlessSerial == serial {
            return
        }

        headlessScrcpy.stop()

        let ok = headlessScrcpy.startHeadless(serial: serial) { [weak self] in
            Task { @MainActor in
                self?.headlessSerial = nil
            }
        }

        if ok {
            headlessSerial = serial
        } else {
            headlessSerial = nil
        }
    }

    // MARK: - Wireless

    /// Connects to an already-paired / TCP-IP device at host:port.
    func connectWireless(hostPort: String) async {
        isConnecting = true
        isWorking = true
        defer {
            isWorking = false
            isConnecting = false
        }
        let result = await ADB.connect(hostPort: hostPort)
        status = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        await refreshDevices()
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
        await refreshDevices()
        guard let usb = rawDevices.first(where: { !$0.isWireless && $0.state.isUsable }) else {
            hotspotPhase = .needsUSB
            status = "Plug the phone in via USB first."
            return
        }

        // Use the same logic as the "usb way" - connect and remember the USB device
        DeviceStore.connect(usb.serial)
        DeviceStore.remember(usb.serial)
        await refreshDevices()

        isConnecting = true
        defer { isConnecting = false }

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

        // `adb tcpip` restarts the phone's daemon, so it's unreachable for a few
        // seconds. Retry the connect until it actually comes back as "device".
        let hostPort = "\(ip):5555"
        hotspotPhase = .working("Connecting to \(hostPort)… (the phone is switching to wireless)")
        let connected = await ADB.connectVerified(hostPort: hostPort)

        guard connected else {
            hotspotPhase = .failed("The phone didn't come back on Wi-Fi. Make sure the Mac is joined to the phone's hotspot, then try again.")
            return
        }

        // Success. Disconnect the USB transport so scrcpy/adb don't see the same
        // phone twice (the dual-transport race caused the EOF/disconnect errors).
        // The phone keeps its wireless connection over the hotspot.
        DeviceStore.remember(hostPort)
        DeviceStore.connect(hostPort)
        await refreshDevices()
        await select(hostPort)

        hotspotPhase = .connected(hostPort)
        status = "Wireless over hotspot — you can unplug the USB cable now."
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

    var activePreviewURL: URL? = nil
    var activePreviewFilePath: String?
    var thumbnailLoadedTrigger: Bool = false
    @ObservationIgnored private var activeDownloads: Set<String> = []

    enum FileSortKey: String, CaseIterable {
        case name = "Name"
        case size = "Size"
        case date = "Date Modified"
    }

    enum FileSortOrder: String {
        case ascending
        case descending
    }

    enum FileViewMode: String {
        case list
        case grid
    }

    enum FileSearchScope: String {
        case current = "Current Folder"
        case entireDevice = "Entire Phone"
    }

    var fileViewMode: FileViewMode = .list
    var sortKey: FileSortKey? = nil
    var sortOrder: FileSortOrder = .ascending
    var sizeWidth: Double = 120.0
    var dateWidth: Double = 160.0

    var fileSearchText: String = ""
    var fileSearchScope: FileSearchScope = .current
    var isDeepSearching: Bool = false

    /// Current directory shown in the in-app file browser.
    var browsePath: String = "/sdcard/"
    var browseFiles: [ADB.RemoteFile] = []
    var isBrowsing: Bool = false

    /// Lazily-computed folder sizes (path -> bytes), filled after a listing so
    /// the list shows instantly and sizes fill in as `du` returns.
    var folderSizes: [String: Int64] = [:]

    /// Serials selected for bulk actions in the file browser.
    var selectedFiles: Set<String> = []   // RemoteFile.path values

    /// In-flight / recent file transfers, shown as progress bars in the UI.
    struct Transfer: Identifiable {
        let id = UUID()
        let name: String
        let direction: Direction
        var totalBytes: Int64?       // known up front for the source file
        var bytesTransferred: Int64 = 0
        var fraction: Double = 0     // 0...1, computed by polling the dest size
        var done: Bool = false
        var failed: Bool = false
        var cancelled: Bool = false
        enum Direction { case toPhone, toMac }

        var isDeterminate: Bool { (totalBytes ?? 0) > 0 }
        var inProgress: Bool { !done }
    }
    var transfers: [Transfer] = []

    /// Live process + cleanup info per transfer, kept outside the observable
    /// array (Process isn't observable/Sendable-friendly).
    private struct TransferControl {
        weak var process: Process?
        let remotePathToCleanup: String?   // delete this on cancel (uploads)
    }
    private var controls: [UUID: TransferControl] = [:]

    private func addTransfer(_ name: String, _ dir: Transfer.Direction, totalBytes: Int64?) -> UUID {
        let t = Transfer(name: name, direction: dir, totalBytes: totalBytes)
        transfers.append(t)
        return t.id
    }

    private func updateProgress(_ id: UUID, bytesTransferred: Int64, fraction: Double) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[idx].bytesTransferred = bytesTransferred
        transfers[idx].fraction = max(transfers[idx].fraction, min(fraction, 0.995))
    }

    private func finishTransfer(_ id: UUID, failed: Bool) {
        controls[id] = nil
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        if transfers[idx].cancelled { return }   // cancel path owns the UI state
        transfers[idx].done = true
        transfers[idx].failed = failed
        if !failed, let total = transfers[idx].totalBytes {
            transfers[idx].bytesTransferred = total
        }
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
        controls[id] = nil
    }

    /// Cancel an in-flight transfer: kill the adb process and, for uploads,
    /// delete the partial file left on the phone.
    func cancelTransfer(_ id: UUID) async {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[idx].cancelled = true
        transfers[idx].done = true
        transfers[idx].failed = true

        let control = controls[id]
        control?.process?.terminate()
        controls[id] = nil

        // Clean up a partially-written file on the phone (uploads only).
        if let remote = control?.remotePathToCleanup, let serial = selectedSerial {
            _ = await ADB.delete(serial, path: remote)
            await loadFiles()
        }
        status = "Transfer cancelled"
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
                if let now = await currentBytes(), total > 0 {
                    let fraction = Double(now) / Double(total)
                    if !fraction.isNaN && !fraction.isInfinite {
                        await MainActor.run { self?.updateProgress(id, bytesTransferred: now, fraction: fraction) }
                    }
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// True once we're somewhere below the starting root, so "up" makes sense.
    var canGoUp: Bool { browsePath != "/" && browsePath != "/sdcard/" }

    func loadFiles(path: String? = nil) async {
        guard let serial = selectedSerial else { return }
        if let path { 
            browsePath = path 
            fileSearchText = ""
            isDeepSearching = false
        }
        
        if isDeepSearching {
            await performSearch()
            return
        }
        
        activePreviewURL = nil
        activePreviewFilePath = nil
        lastClickedFilePath = nil

        isBrowsing = true
        defer { isBrowsing = false }
        selectedFiles.removeAll()
        folderSizes.removeAll()
        browseFiles = await ADB.listFiles(serial, path: browsePath)
        // Fill folder sizes lazily so the list appears immediately.
        let folders = browseFiles.filter { $0.isDirectory }
        Task { [weak self, serial] in
            for folder in folders {
                if Task.isCancelled { return }
                if let size = await ADB.directorySize(serial, path: folder.path) {
                    await MainActor.run { self?.folderSizes[folder.path] = size }
                }
            }
        }
    }

    func performSearch() async {
        guard let serial = selectedSerial else { return }
        let query = fileSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        
        activePreviewURL = nil
        activePreviewFilePath = nil
        lastClickedFilePath = nil

        isBrowsing = true
        isDeepSearching = true
        defer { isBrowsing = false }
        selectedFiles.removeAll()
        folderSizes.removeAll()
        
        let searchRoot = (fileSearchScope == .current) ? browsePath : "/sdcard/"
        browseFiles = await ADB.searchFiles(serial, underPath: searchRoot, query: query)
    }

    // MARK: - File multi-select & bulk actions

    var lastClickedFilePath: String?

    func selectFile(_ file: ADB.RemoteFile, shiftPressed: Bool, commandPressed: Bool) {
        if commandPressed {
            toggleSelection(file)
            lastClickedFilePath = file.path
        } else if shiftPressed, let last = lastClickedFilePath,
                  let lastIdx = sortedFiles.firstIndex(where: { $0.path == last }),
                  let curIdx = sortedFiles.firstIndex(where: { $0.path == file.path }) {
            let start = min(lastIdx, curIdx)
            let end = max(lastIdx, curIdx)
            let rangeFiles = sortedFiles[start...end]
            selectedFiles.formUnion(rangeFiles.map(\.path))
        } else {
            selectedFiles = [file.path]
            lastClickedFilePath = file.path
        }
    }

    func toggleSelection(_ file: ADB.RemoteFile) {
        if selectedFiles.contains(file.path) { selectedFiles.remove(file.path) }
        else { selectedFiles.insert(file.path) }
    }

    func copySelectedFilesToClipboard() {
        let selected = selectedRemoteFiles
        guard !selected.isEmpty else { return }
        
        status = "Copying \(selected.count) item(s)..."
        
        Task {
            var localURLs: [URL] = []
            for file in selected {
                if let localURL = await stageForDragOut(file) {
                    localURLs.append(localURL)
                }
            }
            guard !localURLs.isEmpty else {
                status = "Failed to copy files"
                return
            }
            
            #if os(macOS)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(localURLs.map { $0 as NSURL })
            #endif
            status = "Copied \(localURLs.count) item(s) to Mac clipboard"
        }
    }

    func pasteFilesFromClipboard() {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            status = "No files on Mac clipboard to paste"
            return
        }
        let filePaths = urls.filter { $0.isFileURL }.map { $0.path }
        guard !filePaths.isEmpty else { return }
        
        status = "Pasting \(filePaths.count) item(s) from Mac..."
        Task {
            await uploadToCurrentFolder(localPaths: filePaths)
        }
        #endif
    }

    var hasSelection: Bool { !selectedFiles.isEmpty }

    func clearSelection() { selectedFiles.removeAll() }

    private var selectedRemoteFiles: [ADB.RemoteFile] {
        browseFiles.filter { selectedFiles.contains($0.path) }
    }

    /// Copy all selected items to a chosen Mac folder.
    func downloadSelected(toLocalDir dir: String) async {
        let items = selectedRemoteFiles
        clearSelection()
        for item in items { await downloadFromPhone(item, toLocalDir: dir) }
    }

    /// Delete all selected items from the phone.
    func deleteSelected() async {
        let items = selectedRemoteFiles
        clearSelection()
        for item in items {
            guard let serial = selectedSerial else { break }
            _ = await ADB.delete(serial, path: item.path)
        }
        status = "Deleted \(items.count) item(s)"
        await loadFiles()
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

    /// Copy a file/folder from the phone to a chosen Mac folder (cancellable, with progress).
    func downloadFromPhone(_ file: ADB.RemoteFile, toLocalDir localDir: String) async {
        guard let serial = selectedSerial else { return }
        // Folders report no size in the listing; fetch it so the bar is real.
        var total = file.sizeBytes
        if file.isDirectory {
            if let cached = folderSizes[file.path] {
                total = cached
            } else {
                total = await ADB.directorySize(serial, path: file.path)
            }
        }

        // Poll the growing local destination (a file, or a dir for folders).
        let localDest = URL(fileURLWithPath: (localDir as NSString).appendingPathComponent(file.name))
        
        // Delete local destination before pulling so progress starts at 0 bytes
        try? FileManager.default.removeItem(at: localDest)

        let id = addTransfer(file.name, .toMac, totalBytes: total)

        var poller: Task<Void, Never>?
        if let total, total > 0 {
            poller = pollProgress(id: id, total: total) { [localDest, file] in
                localBytes(at: localDest, isDirectory: file.isDirectory)
            }
        }

        let result = await ADB.pullCancellable(serial, remotePath: file.path, localPath: localDir) { [weak self] proc in
            Task { @MainActor in self?.controls[id] = TransferControl(process: proc, remotePathToCleanup: nil) }
        }
        poller?.cancel()
        finishTransfer(id, failed: !result.succeeded)
        if result.succeeded { status = "Copied \(file.name) to Mac" }
    }

    /// Copy one or more Mac files into the directory currently shown (cancellable, with progress).
    func uploadToCurrentFolder(localPaths: [String]) async {
        guard let serial = selectedSerial else { return }
        for localPath in localPaths {
            let name = (localPath as NSString).lastPathComponent
            let isDir = (try? FileManager.default.contentsOfDirectory(atPath: localPath)) != nil
            let total = localBytes(at: URL(fileURLWithPath: localPath), isDirectory: isDir)

            let base = browsePath.hasSuffix("/") ? browsePath : browsePath + "/"
            let remoteDest = base + name

            // Delete remote destination before pushing so progress starts at 0 bytes
            _ = await ADB.delete(serial, path: remoteDest)

            let id = addTransfer(name, .toPhone, totalBytes: total)

            // Poll the growing destination on the phone (file size, or du for dirs).
            var poller: Task<Void, Never>?
            if let total, total > 0 {
                poller = pollProgress(id: id, total: total) { [serial, remoteDest, isDir] in
                    isDir ? await ADB.directorySize(serial, path: remoteDest)
                          : await ADB.fileSize(serial, path: remoteDest)
                }
            }

            let result = await ADB.pushCancellable(serial, localPath: localPath, remotePath: browsePath) { [weak self] proc in
                Task { @MainActor in self?.controls[id] = TransferControl(process: proc, remotePathToCleanup: remoteDest) }
            }
            poller?.cancel()
            finishTransfer(id, failed: !result.succeeded)
            if !result.succeeded && !(transfers.first(where: { $0.id == id })?.cancelled ?? false) {
                status = "Copy failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
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
            .appendingPathComponent("MimicOS-dragout", isDirectory: true)
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

    /// Stages every currently-selected file into one temp folder and returns
    /// that folder, so a single drag drops all of them onto the Mac. (SwiftUI's
    /// per-row `.onDrag` can only carry one item, so we bundle the selection
    /// into a folder rather than losing all but the grabbed file.)
    func stageSelectedForDragOut() async -> URL? {
        guard let serial = selectedSerial else { return nil }
        let items = selectedRemoteFiles
        guard items.count > 1 else {
            // Single selection — drop the file itself, not a folder.
            return items.first.map { _ in nil } ?? nil
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimicOS-\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let totalBytes = items.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
        let id = addTransfer("\(items.count) items", .toMac, totalBytes: totalBytes > 0 ? totalBytes : nil)

        var ok = true
        for item in items {
            let r = await ADB.pull(serial, remotePath: item.path, localPath: folder.path)
            if !r.succeeded { ok = false }
        }
        finishTransfer(id, failed: !ok)
        return ok ? folder : nil
    }

    var sortedFiles: [ADB.RemoteFile] {
        let baseFiles: [ADB.RemoteFile]
        let query = fileSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isDeepSearching && !query.isEmpty {
            baseFiles = browseFiles.filter { $0.name.localizedCaseInsensitiveContains(query) }
        } else {
            baseFiles = browseFiles
        }

        if sortKey == nil {
            return baseFiles.sorted {
                if $0.isDirectory != $1.isDirectory {
                    return $0.isDirectory && !$1.isDirectory
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        
        return baseFiles.sorted { f1, f2 in
            if f1.isDirectory != f2.isDirectory {
                return f1.isDirectory && !f2.isDirectory
            }
            
            let isAsc = sortOrder == .ascending
            switch sortKey! {
            case .name:
                let cmp = f1.name.localizedCaseInsensitiveCompare(f2.name)
                return isAsc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
            case .size:
                if f1.isDirectory {
                    let sz1 = folderSizes[f1.path] ?? 0
                    let sz2 = folderSizes[f2.path] ?? 0
                    if sz1 == sz2 {
                        return f1.name.localizedCaseInsensitiveCompare(f2.name) == .orderedAscending
                    }
                    return isAsc ? (sz1 < sz2) : (sz1 > sz2)
                } else {
                    let sz1 = f1.sizeBytes ?? 0
                    let sz2 = f2.sizeBytes ?? 0
                    if sz1 == sz2 {
                        return f1.name.localizedCaseInsensitiveCompare(f2.name) == .orderedAscending
                    }
                    return isAsc ? (sz1 < sz2) : (sz1 > sz2)
                }
            case .date:
                let d1 = f1.modified ?? ""
                let d2 = f2.modified ?? ""
                if d1 == d2 {
                    return f1.name.localizedCaseInsensitiveCompare(f2.name) == .orderedAscending
                }
                return isAsc ? (d1 < d2) : (d1 > d2)
            }
        }
    }

    func cycleSort(for key: FileSortKey) {
        if sortKey != key {
            sortKey = key
            sortOrder = .ascending
        } else if sortOrder == .ascending {
            sortOrder = .descending
        } else {
            sortKey = nil
        }
    }

    func selectAllFiles() {
        let allPaths = browseFiles.map(\.path)
        selectedFiles = Set(allPaths)
    }

    func deselectAllFiles() {
        selectedFiles.removeAll()
    }

    func previewFile(_ file: ADB.RemoteFile) async {
        guard let serial = selectedSerial else { return }
        
        activePreviewURL = nil
        activePreviewFilePath = file.path
        
        let previewDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimicOS-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
        
        let localDest = previewDir.appendingPathComponent(file.name)
        try? FileManager.default.removeItem(at: localDest)
        
        var total = file.sizeBytes
        if file.isDirectory {
            if let cached = folderSizes[file.path] {
                total = cached
            } else {
                total = await ADB.directorySize(serial, path: file.path)
            }
        }
        
        let totalBytes = total ?? 0
        
        let poller = Task { [weak self, localDest, totalBytes, filePath = file.path] in
            while !Task.isCancelled {
                guard self?.activePreviewFilePath == filePath else { return }
                let isDir = (try? FileManager.default.contentsOfDirectory(atPath: localDest.path)) != nil
                if let now = localBytes(at: localDest, isDirectory: isDir), totalBytes > 0 {
                    let pct = Int(round(Double(now) / Double(totalBytes) * 100))
                    let nowMB = Double(now) / 1_048_576.0
                    let totalMB = Double(totalBytes) / 1_048_576.0
                    await MainActor.run {
                        self?.status = String(format: "Downloading preview: %.1f MB / %.1f MB (%d%%)", nowMB, totalMB, pct)
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        
        status = "Downloading preview of \(file.name)..."
        let result = await ADB.pull(serial, remotePath: file.path, localPath: previewDir.path)
        poller.cancel()
        
        guard activePreviewFilePath == file.path else { return }
        
        if result.succeeded {
            status = "Opening preview of \(file.name)"
            activePreviewURL = localDest
        } else {
            status = "Failed to download preview: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    func selectNextFile() {
        let files = sortedFiles
        guard !files.isEmpty else { return }
        let currentPath = selectedFiles.first
        let index = files.firstIndex(where: { $0.path == currentPath }) ?? -1
        let nextIndex = min(files.count - 1, index + 1)
        let nextFile = files[nextIndex]
        selectedFiles = [nextFile.path]
        lastClickedFilePath = nextFile.path
        
        if activePreviewURL != nil {
            Task {
                await previewFile(nextFile)
            }
        }
    }

    func selectPreviousFile() {
        let files = sortedFiles
        guard !files.isEmpty else { return }
        let currentPath = selectedFiles.first
        let index = files.firstIndex(where: { $0.path == currentPath }) ?? 0
        let prevIndex = max(0, index - 1)
        let prevFile = files[prevIndex]
        selectedFiles = [prevFile.path]
        lastClickedFilePath = prevFile.path
        
        if activePreviewURL != nil {
            Task {
                await previewFile(prevFile)
            }
        }
    }

    func getThumbnail(for file: ADB.RemoteFile) -> URL? {
        let ext = (file.name as NSString).pathExtension.lowercased()
        let isImg = ["jpg", "jpeg", "png", "webp", "heic", "gif"].contains(ext)
        let isVid = ["mp4", "mkv", "mov", "avi", "3gp"].contains(ext)
        guard isImg || isVid else { return nil }
        
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimicOS-thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        let hash = file.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        let localURL = cacheDir.appendingPathComponent("\(hash).jpg")
        
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }
        
        triggerThumbnailDownload(file: file, localURL: localURL, isVideo: isVid)
        return nil
    }

    private func triggerThumbnailDownload(file: ADB.RemoteFile, localURL: URL, isVideo: Bool) {
        guard let serial = selectedSerial else { return }
        guard !activeDownloads.contains(file.path) else { return }
        activeDownloads.insert(file.path)
        
        Task {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MimicOS-thumb-temp", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            let ext = (file.name as NSString).pathExtension
            let tempDest = tempDir.appendingPathComponent(UUID().uuidString + ".\(ext)")
            let result = await ADB.pull(serial, remotePath: file.path, localPath: tempDest.path)
            
            if result.succeeded {
                if isVideo {
                    await Task.detached(priority: .background) {
                        saveVideoThumbnail(from: tempDest, to: localURL)
                    }.value
                } else {
                    await Task.detached(priority: .background) {
                        saveScaledImage(from: tempDest, to: localURL)
                    }.value
                }
            }
            try? FileManager.default.removeItem(at: tempDest)
            
            self.activeDownloads.remove(file.path)
            self.thumbnailLoadedTrigger.toggle()
        }
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

    /// Opens the recent-apps / "all tabs" overview (KEYCODE_APP_SWITCH).
    func pressRecents() async {
        guard let serial = selectedSerial else { return }
        await ADB.keyEvent(serial, keycode: 187)
        status = "Recent apps"
    }

    func togglePower() async {
        guard let serial = selectedSerial else { return }
        await ADB.keyEvent(serial, keycode: 26)
        status = "POWER"
    }

    /// Android keycodes for the hardware volume keys.
    func volumeUp() async {
        guard let serial = selectedSerial else { return }
        await ADB.keyEvent(serial, keycode: 24)   // KEYCODE_VOLUME_UP
        status = "Volume up"
    }

    func volumeDown() async {
        guard let serial = selectedSerial else { return }
        await ADB.keyEvent(serial, keycode: 25)   // KEYCODE_VOLUME_DOWN
        status = "Volume down"
    }

    /// Rotate the phone display 90° clockwise.
    func rotateScreen() async {
        guard let serial = selectedSerial else {
            status = "Select a device first"
            return
        }
        await ADB.rotateDisplay(serial)
        status = "Rotated screen"
    }

    // MARK: - Screenshot & screen recording (to the user's capture folder)

    /// Captures a phone screenshot straight into the configured capture folder
    /// and reveals it in Finder. Works with or without an active mirror.
    func captureScreenshot() async {
        guard let serial = selectedSerial,
              selectedDevice?.state.isUsable == true else {
            status = "Select a connected device first"
            return
        }
        let folder = settings.ensureCaptureFolderExists()
        let name = "Screenshot-\(Self.timestamp()).png"
        let dest = folder.appendingPathComponent(name)
        status = "Taking screenshot…"
        if let url = await ADB.screenshot(serial, to: dest) {
            status = "Saved \(name)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            status = "Screenshot failed"
        }
    }

    /// True while a phone screen recording is in progress.
    private(set) var isRecording = false
    /// Dedicated scrcpy session used purely for recording (separate from the
    /// mirror session so the two don't interfere).
    @ObservationIgnored private let recorder = Scrcpy()
    @ObservationIgnored private var recordDest: URL?

    /// Start or stop a screen recording, saved to the capture folder on stop.
    func toggleScreenRecording() async {
        if isRecording {
            await stopScreenRecording()
        } else {
            startScreenRecording()
        }
    }

    private func startScreenRecording() {
        guard let serial = selectedSerial,
              selectedDevice?.state.isUsable == true else {
            status = "Select a connected device first"
            return
        }
        let folder = settings.ensureCaptureFolderExists()
        let name = "Recording-\(Self.timestamp()).mp4"
        let dest = folder.appendingPathComponent(name)
        recordDest = dest

        // Record via scrcpy's own H.264 pipeline (no-window session) straight to
        // the Mac. This avoids the device's `screenrecord`, which fails with
        // "Encoder failed (err=-38)" on some phones. No 3-minute cap either.
        let started = recorder.startRecording(serial: serial, to: dest) { [weak self] code in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                // scrcpy exited on its own (device dropped, etc.).
                self.isRecording = false
                if code == 0, FileManager.default.fileExists(atPath: dest.path) {
                    self.status = "Saved \(dest.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                } else {
                    self.status = "Recording stopped unexpectedly"
                }
            }
        }
        if started {
            isRecording = true
            status = "Recording… (tap again to stop)"
        } else {
            status = "Couldn't start recording"
            recordDest = nil
        }
    }

    private func stopScreenRecording() async {
        guard let dest = recordDest else { isRecording = false; return }
        isRecording = false
        status = "Finalizing recording…"
        // SIGINT lets scrcpy write the MP4 moov atom; wait (without blocking the
        // main thread) for it to exit, then force-stop if it overstays.
        recorder.interruptRecording()
        for _ in 0..<50 {   // up to ~5s
            if !recorder.isRecordingProcessRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        recorder.forceStopRecording()

        if FileManager.default.fileExists(atPath: dest.path),
           (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int ?? 0) ?? 0 > 0 {
            status = "Saved \(dest.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } else {
            status = "Recording failed to save"
        }
        recordDest = nil
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}

/// Current byte size of a local path on the Mac — a single file's size, or the
/// recursive total for a directory (used for progress on `.app` bundles etc).
/// Free function so it's safe to call from `@Sendable` polling closures.
func localBytes(at url: URL, isDirectory: Bool) -> Int64? {
    let fm = FileManager.default
    if !isDirectory {
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value
    }
    guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
    var total: Int64 = 0
    for case let f as URL in en {
        let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        total += Int64(size)
    }
    return total
}

/// Scaled image saver (runs on background thread).
func saveScaledImage(from sourceURL: URL, to destURL: URL) {
    guard let img = NSImage(contentsOf: sourceURL) else { return }
    let size = img.size
    let ratio = min(120.0 / size.width, 120.0 / size.height)
    let newSize = NSSize(width: size.width * ratio, height: size.height * ratio)
    
    let newImg = NSImage(size: newSize)
    newImg.lockFocus()
    img.draw(in: NSRect(origin: .zero, size: newSize),
             from: NSRect(origin: .zero, size: size),
             operation: .copy,
             fraction: 1.0)
    newImg.unlockFocus()
    
    if let tiff = newImg.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff),
       let jpeg = bitmap.representation(using: .jpeg, properties: [:]) {
        try? jpeg.write(to: destURL)
    }
}

/// Video thumbnail generator (runs on background thread).
func saveVideoThumbnail(from videoURL: URL, to destURL: URL) {
    let asset = AVAsset(url: videoURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    let time = CMTime(seconds: 0.0, preferredTimescale: 600)
    do {
        let imageRef = try generator.copyCGImage(at: time, actualTime: nil)
        let nsImage = NSImage(cgImage: imageRef, size: NSSize(width: 120, height: 120))
        if let tiffData = nsImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let jpegData = bitmap.representation(using: .jpeg, properties: [:]) {
            try jpegData.write(to: destURL)
        }
    } catch {
        print("Failed to generate video thumbnail: \(error)")
    }
}
