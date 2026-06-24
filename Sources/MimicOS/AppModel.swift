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
        case caller = "Caller"
        case contacts = "Contacts"
        case messages = "Messages"
        case files = "Files"
        case settings = "Settings"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .control: return "rectangle.on.rectangle"
            case .caller: return "phone"
            case .contacts: return "person.crop.circle"
            case .messages: return "message"
            case .files: return "folder"
            case .settings: return "gearshape"
            }
        }
    }
    var selectedTab: Tab = .control
    var openMainWindowAction: (() -> Void)?

    /// What the sidebar has selected, and therefore which detail pane to show.
    /// Phones and computers live in one combined sidebar, so the selection can be
    /// either — this drives whether `ControlPanelView` or `PCPanelView` appears.
    /// It's a thin facade over the underlying `selectedSerial` / `selectedHostID`,
    /// which the rest of the model still reads.
    enum Selection: Hashable {
        case phone(String)   // device serial
        case computer(UUID)  // RemoteHost id
    }
    var selection: Selection? {
        get {
            if let id = selectedHostID { return .computer(id) }
            if let serial = selectedSerial { return .phone(serial) }
            return nil
        }
        set {
            switch newValue {
            case .phone(let serial):
                selectedHostID = nil
                Task { await select(serial) }
            case .computer(let id):
                selectedHostID = id
            case nil:
                selectedHostID = nil
            }
        }
    }

    /// True when the current selection is a remote computer.
    var isComputerSelected: Bool { selectedHostID != nil }

    /// Tabs in the PC detail pane (one selected remote computer).
    enum PCTab: String, CaseIterable, Identifiable {
        case screen = "Screen"
        case files = "Files"
        case terminal = "Terminal"
        case settings = "Settings"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .screen: return "display"
            case .files: return "folder"
            case .terminal: return "terminal"
            case .settings: return "gearshape"
            }
        }
    }
    var selectedPCTab: PCTab = .screen

    /// id of the remote host selected in the PC sidebar.
    var selectedHostID: UUID?
    var selectedHost: RemoteHost? {
        remoteHosts.first { $0.id == selectedHostID }
    }

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

    // MARK: - Audio & DND status
    var isSilent: Bool = false
    var isVibrate: Bool = false
    var isDND: Bool = false

    // MARK: - Incoming-call alerts
    //
    // A cellular call's voice path lives in the phone's baseband, unreachable by
    // adb/scrcpy, so this is control-only: detect the ring, then Answer / Decline
    // / Silence over adb. You talk on the physical phone (or hear it on the Mac if
    // mirroring is on).
    // MARK: - Caller tab (call log + contacts + dialer)
    var callLog: [ADB.CallLogEntry] = []
    var contacts: [ADB.Contact] = []
    var isLoadingCallLog = false
    var isLoadingContacts = false
    var dialerInput = ""
    var callerSearch = ""
    var contactSearch = ""

    // MARK: - Messages tab
    var conversations: [ADB.Conversation] = []
    var isLoadingMessages = false
    var messageSearch = ""
    var selectedThreadID: String?

    @ObservationIgnored private let callController = IncomingCallController()
    /// Serial whose call is currently shown, and the last call state we saw for
    /// it, so we only react on transitions (ring → answered/ended).
    @ObservationIgnored private var ringingSerial: String?
    @ObservationIgnored private var lastCallState: ADB.CallState = .idle

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
    @ObservationIgnored let windowTracker = ScrcpyWindowTracker()

    /// The attached floating remote-control window shown beside the phone screen.
    @ObservationIgnored let floatingRemote = FloatingRemoteController()

    @ObservationIgnored private var scrcpySessions: [String: Scrcpy] = [:]
    var mirroringSerials: Set<String> = []
    
    private func scrcpySession(for serial: String) -> Scrcpy {
        if let session = scrcpySessions[serial] {
            return session
        }
        let session = Scrcpy()
        scrcpySessions[serial] = session
        return session
    }

    private let headlessScrcpy = Scrcpy()
    private var headlessSerial: String?

    /// Stable window title handed to scrcpy so the tracker can find its window.
    private var mirrorWindowTitle: String?

    /// Serial of the device currently being mirrored, or nil. This is observable,
    /// and checks if the currently selected phone is mirrored.
    var mirroringSerial: String? {
        if let serial = selectedSerial, mirroringSerials.contains(serial) {
            return serial
        }
        return nil
    }
    var isMirroring: Bool { mirroringSerial != nil }

    @ObservationIgnored private var droppedHostIDs: Set<UUID> = []

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
        loadRemoteHosts()
        setupCallController()
        startBackgroundMonitor()
        startCallPoller()
        startMessagePoller()
        // Match the OS login-item state to the saved preference.
        LoginItem.sync(desired: settings.launchAtLogin)
        
        // Reset and prompt for accessibility if sidebar is enabled but not trusted
        if settings.showSidebar {
            await ensureAccessibilityFreshAndPrompt()
        }
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
        mirroringSerials.removeAll()
        mirrorWindowTitle = nil
        for session in scrcpySessions.values {
            session.stop()
        }
        scrcpySessions.removeAll()
        headlessScrcpy.stop()
        remoteDesktop.stop()
        connectedRemoteHostID = nil
        callPollTask?.cancel()
        callPollTask = nil
        messagePollTask?.cancel()
        messagePollTask = nil
        callController.dismiss()
        // Sweep any orphaned scrcpy / FreeRDP processes so no mirror or remote
        // desktop window lingers after quit.
        Scrcpy.killAll()
        RemoteDesktop.killAll()
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
        await attemptPCAutoReconnects()
    }

    // MARK: - Fast call poller
    //
    // Call detection runs on its own ~1s loop (separate from the 3–6s device
    // monitor) so the panel pops up the instant the phone rings, not several
    // seconds later. The check is cheap: a single grep-filtered `dumpsys telecom`.
    @ObservationIgnored private var callPollTask: Task<Void, Never>?

    private func startCallPoller() {
        guard callPollTask == nil else { return }
        callPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                await self.pollCallState()
            }
        }
    }

    // MARK: - Live message refresh
    //
    // While the Messages tab is open, refresh conversations every few seconds so
    // texts you send (from the phone) and incoming replies appear without a
    // manual refresh. Only runs on that tab to keep adb traffic low.
    @ObservationIgnored private var messagePollTask: Task<Void, Never>?

    private func startMessagePoller() {
        guard messagePollTask == nil else { return }
        messagePollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled else { return }
                let onMessages = await MainActor.run { self.selectedTab == .messages }
                if onMessages { await self.refreshMessages(showLoading: false) }
            }
        }
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

        for serial in mirroringSerials {
            if let device = found.first(where: { $0.serial == serial }),
               !device.state.isUsable {
                stopMirror(serial: serial)
                status = "Mirror stopped for \(device.displayName) (device disconnected)"
            }
        }

        // Keep a valid selection.
        if let selectedSerial, !found.contains(where: { $0.serial == selectedSerial }) {
            self.selectedSerial = nil
            self.info = nil
        }
        // Auto-select the first usable phone only when nothing is selected — never
        // steal the selection from a remote computer the user picked.
        if selectedSerial == nil, selectedHostID == nil,
           let first = found.first(where: { $0.state.isUsable }) {
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
        if mirroringSerials.contains(device.serial) {
            stopMirror(serial: device.serial)
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
        if mirroringSerials.contains(device.serial) {
            stopMirror(serial: device.serial)
        }
        DeviceStore.forget(device.serial)
        if selectedSerial == device.serial { selectedSerial = nil; info = nil }
        await refreshDevices()
        status = "Removed \(device.displayName)"
    }

    func select(_ serial: String) async {
        if selectedSerial != serial {
            browsePath = "/sdcard/"
        }
        selectedHostID = nil          // selecting a phone deselects any computer
        selectedSerial = serial
        info = await ADB.info(serial)
        
        // Update window tracker for the newly selected device
        windowTracker.stop()
        floatingRemote.hide()
        if mirroringSerials.contains(serial) {
            let title = "MimicOS — \(devices.first(where: { $0.serial == serial })?.displayName ?? serial)"
            let pid = scrcpySessions[serial]?.processPID
            beginWindowTracking(title: title, pid: pid)
        }
        
        updateBackgroundClipboardSync()
        startScreenshotWatch()
        await refreshRingerAndDNDStatus()
    }

    func openSection(_ tab: Tab) {
        selectedTab = tab
        if let serial = mirroringSerial {
            Task {
                await select(serial)
            }
        }
        openMainWindowAction?()
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
        if mirroringSerials.contains(serial) {
            stopMirror(serial: serial)
        } else {
            startMirror(serial: serial, restarting: false)
        }
    }

    /// (Re)start the scrcpy mirror for `serial`. When `restarting` is true we
    /// keep the current window frame (so a live settings change reopens in the
    /// same spot) and don't touch the headless clipboard session.
    private func startMirror(serial: String, restarting: Bool) {
        if !restarting && mirroringSerials.contains(serial) {
            status = "Device is already mirroring"
            return
        }

        if !restarting {
            if headlessSerial == serial {
                headlessScrcpy.stop()
                headlessSerial = nil
            }
        }

        let title = "MimicOS — \(devices.first(where: { $0.serial == serial })?.displayName ?? serial)"
        mirrorWindowTitle = title

        var options = Scrcpy.Options()
        options.turnScreenOff = turnScreenOff
        options.stayAwake = stayAwake
        options.useHIDKeyboard = useHIDKeyboard
        options.audio = audioRoute
        options.windowTitle = title
        options.alwaysOnTop = settings.alwaysOnTop
        // Reopen where the user last left the phone window (current frame on a
        // live restart, otherwise the persisted one).
        options.windowFrame = (restarting ? windowTracker.currentFrame : nil) ?? settings.phoneWindowFrame

        // Each start gets a unique token. An exit handler only tears the session
        let session = scrcpySession(for: serial)
        let ok = session.start(serial: serial, options: options) { [weak self] status, errText in
            Task { @MainActor in
                guard let self else { return }
                if self.mirroringSerials.contains(serial) {
                    self.persistPhoneWindowFrame()
                    self.mirroringSerials.remove(serial)
                    if self.selectedSerial == serial {
                        self.windowTracker.stop()
                        self.floatingRemote.hide()
                    }
                }
                
                if status != 0 && !errText.isEmpty {
                    let cleanErr = errText.split(separator: "\n").last.map(String.init) ?? errText
                    self.status = "Mirror failed for \(serial): \(cleanErr.trimmingCharacters(in: .whitespacesAndNewlines))"
                } else {
                    self.status = "Mirror stopped for \(serial)"
                }
                self.updateBackgroundClipboardSync()
            }
        }
        if ok {
            mirroringSerials.insert(serial)
            status = turnScreenOff ? "Mirroring (phone screen off)" : "Mirroring"
            if selectedSerial == serial {
                beginWindowTracking(title: title, pid: session.processPID)
            }
        } else {
            status = "Failed to start scrcpy"
        }
    }


    /// Apply mirror-affecting settings (screen-off, awake, UHID, audio) to the
    /// live session by restarting scrcpy in place. No-op when not mirroring.
    func applyMirrorSettingsLive() {
        guard let serial = selectedSerial, mirroringSerials.contains(serial) else { return }
        // Capture the current frame so the new window reopens in the same place.
        if let frame = windowTracker.currentFrame { settings.phoneWindowFrame = frame }
        windowTracker.stop()
        // startMirror bumps the generation token, so the old process's exit
        // handler is ignored when it fires.
        scrcpySessions[serial]?.stop()
        startMirror(serial: serial, restarting: true)
        status = "Updated mirror settings"
    }

    /// Stop mirroring and tear down tracking / floating remote, saving the
    /// window's last frame first.
    private func stopMirror(serial: String) {
        persistPhoneWindowFrame()
        mirroringSerials.remove(serial)
        if selectedSerial == serial {
            windowTracker.stop()
            floatingRemote.hide()
            mirrorWindowTitle = nil
        }
        scrcpySessions[serial]?.stop()
        status = "Mirror stopped"
        updateBackgroundClipboardSync()
    }

    func ensureAccessibilityFreshAndPrompt() async {
        if !AXIsProcessTrusted() {
            // Permission is missing or signature hash has changed. Reset tcc Accessibility cache for com.ayushman.mimicos.
            _ = await Shell.run("/usr/bin/tccutil", ["reset", "Accessibility", "com.ayushman.mimicos"])
            // Prompt user with System settings modal
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            status = "Grant MimicOS Accessibility access (System Settings ▸ Privacy) so the sidebar can follow the phone window."
        }
    }

    /// Hook the shared window tracker so move/resize events drive the floating
    /// remote with zero polling lag (and enforce the window's minimum size).
    private func beginWindowTracking(title: String, pid: pid_t?) {
        if settings.showSidebar {
            Task {
                await ensureAccessibilityFreshAndPrompt()
            }
        }

        windowTracker.onAppear = { [weak self] frame in
            guard let self, let serial = self.selectedSerial else { return }
            if let pid = self.scrcpySessions[serial]?.processPID, let app = NSRunningApplication(processIdentifier: pid) {
                app.activate(options: [])
            }
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

        windowTracker.start(windowTitle: title, scrcpyPID: pid)
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
        if visible {
            Task {
                await ensureAccessibilityFreshAndPrompt()
            }
        }
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

    // MARK: - Remote Desktop (Windows RDP / Linux VNC)
    //
    // Like scrcpy, the client opens its own native window — we don't embed the
    // remote framebuffer. RDP is driven by FreeRDP's `xfreerdp`; VNC hands off to
    // the system Screen Sharing app. Hosts the user saves persist on the Mac;
    // their passwords live in the Keychain.

    @ObservationIgnored private let remoteDesktop = RemoteDesktop()

    /// Drives the universal (app-wide) settings sheet.
    var showUniversalSettings = false

    /// Saved connections shown in the Remote Desktop tab.
    var remoteHosts: [RemoteHost] = []

    /// Setup confirmation per host and tab: true = setup has been completed/confirmed.
    var hostSetupConfirmed: [UUID: [String: Bool]] = [:]

    /// id of the host whose RDP session is currently running (nil if none, or if
    /// the active session is VNC, which the OS owns).
    private(set) var connectedRemoteHostID: UUID?

    /// Bumped whenever a remote host's saved password changes, so password-state
    /// views re-read the Keychain.
    var remoteSecretsRevision = 0

    /// True if FreeRDP's `xfreerdp` is installed. Not required for RDP — without
    /// it we hand a `.rdp` file to the user's native RDP client — but its presence
    /// changes the experience (an owned window we can stop in-app).
    var freeRDPInstalled: Bool { RemoteDesktop.freeRDPInstalled }

    func loadRemoteHosts() {
        remoteHosts = RemoteHostStore.all()
        loadLinuxSetupFlags()
        // Drop a stale selection if its host was removed.
        if let id = selectedHostID, !remoteHosts.contains(where: { $0.id == id }) {
            selectedHostID = nil
        }
        
        // Load setup confirmations from UserDefaults
        for host in remoteHosts {
            hostSetupConfirmed[host.id] = UserDefaults.standard.dictionary(forKey: "MimicOS.setupConfirmed.\(host.id)") as? [String: Bool] ?? [:]
        }
        
        Task {
            await refreshAllHostReachability()
        }
    }

    /// Save (or update) a host. If a non-empty password is supplied, it's stored
    /// in the Keychain; an empty password clears any existing password in the Keychain.
    func saveRemoteHost(_ host: RemoteHost, password: String) {
        RemoteHostStore.upsert(host)
        if password.isEmpty {
            SecretStore.clearRemotePassword(hostID: host.idString)
        } else {
            SecretStore.setRemotePassword(password, hostID: host.idString)
        }
        remoteSecretsRevision += 1
        loadRemoteHosts()
    }

    func isSetupConfirmed(for host: RemoteHost, tab: PCTab) -> Bool {
        hostSetupConfirmed[host.id]?[tab.rawValue] ?? false
    }

    func setSetupConfirmed(_ confirmed: Bool, for host: RemoteHost, tab: PCTab) {
        if hostSetupConfirmed[host.id] == nil {
            hostSetupConfirmed[host.id] = [:]
        }
        hostSetupConfirmed[host.id]?[tab.rawValue] = confirmed
        UserDefaults.standard.set(hostSetupConfirmed[host.id], forKey: "MimicOS.setupConfirmed.\(host.id)")
    }

    func deleteRemoteHost(_ host: RemoteHost) {
        if connectedRemoteHostID == host.id {
            remoteDesktop.stop()
            connectedRemoteHostID = nil
        }
        RemoteHostStore.remove(host)
        remoteSecretsRevision += 1
        loadRemoteHosts()
    }

    func hasRemotePassword(_ host: RemoteHost) -> Bool {
        SecretStore.hasRemotePassword(hostID: host.idString)
    }

    /// Set when a connect fails because the saved password was rejected — the PC
    /// view observes this and shows a password re-entry prompt.
    var passwordReentryHost: RemoteHost?

    /// True if FreeRDP's output indicates the credentials were rejected (as
    /// opposed to a network / cert / generic failure).
    static func isAuthFailure(_ errText: String) -> Bool {
        let t = errText.lowercased()
        return t.contains("logon_failure")
            || t.contains("0x00020014")            // ERRCONNECT_LOGON_FAILURE
            || t.contains("0x00020009")            // ERRCONNECT_AUTHENTICATION_FAILED
            || t.contains("account_locked_out")
            || t.contains("authentication failure")
            || t.contains("invalid credentials")
            || (t.contains("logon") && t.contains("fail"))
    }

    /// Save a corrected password for the host (replacing the rejected one) and
    /// reconnect. Called from the password re-entry prompt.
    func retryWithNewPassword(_ host: RemoteHost, password: String) {
        SecretStore.setRemotePassword(password, hostID: host.idString)
        remoteSecretsRevision += 1
        passwordReentryHost = nil
        connectRemoteHost(host)   // already authorized by the user just typing it
    }

    /// User-initiated connect. If a password is saved for this host, require Touch
    /// ID first (so the user types the password once, at setup, and just uses a
    /// fingerprint afterwards), then connect. Auto-reconnect uses
    /// `connectRemoteHost` directly and is never gated.
    func userConnectRemoteHost(_ host: RemoteHost) async {
        // RDP needs a password. If none is saved, ask for it (our own prompt)
        // rather than launching FreeRDP with an empty one, which makes FreeRDP pop
        // its own "Credentials required" dialog.
        if host.proto == .rdp,
           (SecretStore.remotePassword(hostID: host.idString) ?? "").isEmpty {
            passwordReentryHost = host
            status = "Enter the password for \(host.name)"
            return
        }

        if SecretStore.hasRemotePassword(hostID: host.idString) {
            let ok = await Biometrics.authenticate(reason: "connect to \(host.name)")
            guard ok else {
                status = "Touch ID cancelled — \(host.name) not connected"
                return
            }
        }
        connectRemoteHost(host)
    }

    /// Opens a saved host: launches a FreeRDP client (RDP) or Screen Sharing
    /// (VNC). The password, if saved, is read from the Keychain.
    func connectRemoteHost(_ host: RemoteHost) {
        droppedHostIDs.remove(host.id)

        let password = SecretStore.remotePassword(hostID: host.idString) ?? ""
        let connection = RemoteDesktop.Connection(
            host: host.host,
            port: host.port,
            username: host.username,
            password: password,
            proto: host.proto,
            commandAsCtrl: host.rdpCommandAsCtrl,
            redirectClipboard: host.redirectClipboard)

        let ok = remoteDesktop.connect(connection) { [weak self] code, errText in
            Task { @MainActor in
                guard let self, self.connectedRemoteHostID == host.id else { return }
                self.connectedRemoteHostID = nil

                // The FreeRDP window exited. Whether the user closed it (red
                // button) or it crashed, we do NOT mark it for auto-reconnect
                // here — closing the window means the session is over. Auto-
                // reconnect only fires when the *machine* drops off the network
                // while connected (detected by ping in refreshAllHostReachability),
                // so closing the window can't trigger a reconnect loop.
                self.droppedHostIDs.remove(host.id)

                // If FreeRDP rejected the credentials, the saved password is wrong
                // — ask the user for the correct one (don't just unlock the bad one
                // again with Touch ID next time).
                if Self.isAuthFailure(errText) {
                    self.passwordReentryHost = host
                    self.status = "Wrong password for \(host.name) — enter the correct one"
                } else if code != 0 && !errText.isEmpty {
                    let clean = errText.split(separator: "\n").last.map(String.init) ?? errText
                    self.status = "\(host.name) disconnected: \(clean.trimmingCharacters(in: .whitespacesAndNewlines))"
                } else {
                    self.status = "\(host.name) disconnected"
                }
            }
        }

        if ok {
            // Only a process we actually own (the FreeRDP client window) can be
            // stopped from here, so only that marks the host as "connected". VNC
            // and the .rdp-file handoff are fire-and-forget — the OS owns Screen
            // Sharing / whatever RDP client opened.
            connectedRemoteHostID = remoteDesktop.isRunning ? host.id : nil
            status = "Connecting to \(host.name)…"
            if host.os == .linux { streamConnectStatus(host) }
        } else {
            connectedRemoteHostID = nil
            status = "Couldn't start \(host.proto == .rdp ? "RDP" : "VNC") session for \(host.name)"
        }
    }

    /// Stops the active owned (RDP) session.
    func disconnectRemoteHost() {
        if let hostID = connectedRemoteHostID {
            droppedHostIDs.remove(hostID)
        }
        remoteDesktop.stop()
        connectedRemoteHostID = nil
        status = "Remote session stopped"
    }

    // MARK: - PC: one-click Linux setup (gnome-remote-desktop over SSH)

    /// True while `setupLinux` is running, so the UI can disable the button and
    /// show a spinner.
    var isSettingUpLinux = false

    /// Live, line-by-line console output of the last/in-flight setup, shown in a
    /// small terminal view so the user can watch it run.
    var setupLog: [String] = []

    /// Hosts that have completed a one-click setup at least once — drives whether
    /// the always-on "Reset connection" control appears. Persisted in UserDefaults.
    var linuxSetUpHostIDs: Set<UUID> = []

    /// Live status readout streamed from the box on connect (Screen tab preview).
    var remoteTerminalLog: [String] = []
    var isStreamingRemoteTerminal = false

    private func appendSetupLog(_ line: String) {
        let clean = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        setupLog.append(clean)
        if setupLog.count > 500 { setupLog.removeFirst(setupLog.count - 500) }
    }

    private func appendRemoteTerminalLog(_ line: String) {
        let clean = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard !clean.isEmpty else { return }
        remoteTerminalLog.append(clean)
        if remoteTerminalLog.count > 200 { remoteTerminalLog.removeFirst(remoteTerminalLog.count - 200) }
    }

    func hasLinuxSetup(_ host: RemoteHost) -> Bool { linuxSetUpHostIDs.contains(host.id) }

    private func loadLinuxSetupFlags() {
        let ids = UserDefaults.standard.stringArray(forKey: "MimicOS.linuxSetUpHostIDs") ?? []
        linuxSetUpHostIDs = Set(ids.compactMap(UUID.init))
    }
    private func markLinuxSetUp(_ host: RemoteHost) {
        linuxSetUpHostIDs.insert(host.id)
        UserDefaults.standard.set(linuxSetUpHostIDs.map(\.uuidString), forKey: "MimicOS.linuxSetUpHostIDs")
    }

    /// Configures (or, with `reset: true`, tears down and re-configures)
    /// gnome-remote-desktop on an Ubuntu host over SSH, so RDP shares the user's
    /// real desktop. Streams progress into `setupLog`, then verifies port 3389 is
    /// actually listening before marking the host set up.
    ///
    /// Why gnome-remote-desktop and not xrdp: on modern Ubuntu (23.10+/GNOME), the
    /// built-in gnome-remote-desktop already owns RDP port 3389 — xrdp can't even
    /// bind it (EADDRINUSE) — and it mirrors the *live* Wayland desktop, which xrdp
    /// can't do. We disable xrdp if present, then drive `grdctl`.
    ///
    /// Needs `sshpass` on the Mac and the saved login password (also the RDP
    /// password grdctl stores). SSH uses port 22; the host's saved port is its RDP
    /// port, not SSH.
    func setupLinux(_ host: RemoteHost, reset: Bool = false) async {
        guard host.os == .linux else { return }
        guard RemotePC.sshpassAvailable else {
            status = "One-click setup needs sshpass — run `brew install sshpass`, then try again."
            return
        }
        let password = SecretStore.remotePassword(hostID: host.idString) ?? ""
        guard !password.isEmpty else {
            passwordReentryHost = host
            status = "Enter the Linux login password first — it's needed to set up Remote Desktop."
            return
        }
        guard !host.username.isEmpty else {
            status = "Add the Linux username to this computer first (Settings tab)."
            return
        }

        isSettingUpLinux = true
        setupLog = []
        defer { isSettingUpLinux = false }

        appendSetupLog("$ Connecting to \(host.username)@\(host.host):\(RemotePC.sshPort)…")
        status = reset
            ? "Resetting Remote Desktop on \(host.name)…"
            : "Setting up Remote Desktop on \(host.name)…"

        // The login password is the first stdin line (consumed by `read PW`), then
        // reused for `sudo -S` and as the RDP credential grdctl stores. Single
        // quotes around "$PW" keep any special characters literal.
        let resetBlock = reset ? """
        echo ">>> Resetting — clearing existing Remote Desktop config…"
        grdctl rdp disable 2>/dev/null || true
        grdctl rdp clear-credentials 2>/dev/null || true
        echo "$PW" | sudo -S -p '' systemctl disable --now xrdp 2>/dev/null || true

        """ : ""

        let script = """
        read -r PW
        set -u
        \(resetBlock)echo ">>> Checking the desktop environment…"
        if ! command -v grdctl >/dev/null 2>&1; then
          echo ">>> Installing gnome-remote-desktop…"
          echo "$PW" | sudo -S -p '' DEBIAN_FRONTEND=noninteractive apt-get update -y
          echo "$PW" | sudo -S -p '' DEBIAN_FRONTEND=noninteractive apt-get install -y gnome-remote-desktop
        fi

        echo ">>> Freeing RDP port 3389 (disabling xrdp if installed)…"
        echo "$PW" | sudo -S -p '' systemctl disable --now xrdp 2>/dev/null || true

        echo ">>> Configuring GNOME Remote Desktop (RDP)…"
        grdctl rdp set-credentials "\(host.username)" "$PW"
        grdctl rdp disable-view-only || true
        grdctl rdp enable

        echo ">>> Enabling the Remote Desktop service…"
        systemctl --user enable --now gnome-remote-desktop.service 2>/dev/null || true
        # Make sure it keeps serving when you're logged in; allow the port through ufw.
        echo "$PW" | sudo -S -p '' ufw allow 3389/tcp 2>/dev/null || true
        echo "$PW" | sudo -S -p '' ufw allow 22/tcp 2>/dev/null || true

        echo ">>> Verifying it's listening on 3389…"
        sleep 2
        if (command -v ss >/dev/null && ss -tln | grep -q ':3389') || (command -v grdctl >/dev/null && grdctl status 2>/dev/null | grep -qi 'Status:.*enabled'); then
          echo "MIMICOS_RDP_OK"
          grdctl status 2>/dev/null | sed 's/^/    /' || true
        else
          echo "MIMICOS_RDP_NOTUP — current status:"
          grdctl status 2>/dev/null | sed 's/^/    /' || true
        fi
        echo "MIMICOS_SETUP_DONE"
        """

        var sawDone = false
        let code = await RemotePC.runUserScriptStreaming(
            host: host.host, username: host.username, port: RemotePC.sshPort,
            password: password, script: script) { [weak self] line in
                guard let self else { return }
                // Swallow the sudo password prompt echo if any leaks through.
                if line.contains("[sudo]") { return }
                self.appendSetupLog(line)
                if line.contains("MIMICOS_SETUP_DONE") { sawDone = true }
            }

        appendSetupLog(">>> Checking that the Mac can reach Remote Desktop…")
        let rdpPort = host.port ?? RemoteDesktop.Kind.rdp.defaultPort
        let reachable = await RemotePC.isPortOpen(host.host, port: rdpPort)

        if reachable {
            markLinuxSetUp(host)
            appendSetupLog("✓ Done — GNOME Remote Desktop is serving your live desktop on port \(rdpPort). Hit Start screen sharing.")
            status = "\(host.name) is set up. Screen sharing now shows your real Linux desktop over RDP."
            await pingHost(host)
        } else if code == 0 && sawDone {
            // The box reports configured but the Mac can't reach the port. The
            // user-session service only serves while you're logged in at the Linux
            // console — the usual cause. Mark it set up so the Reset button shows.
            markLinuxSetUp(host)
            appendSetupLog("⚠︎ Configured, but the Mac can't reach port \(rdpPort) yet.")
            appendSetupLog("   GNOME Remote Desktop only accepts connections while you're logged in at the Linux screen. Log in there, then try Start screen sharing.")
            status = "\(host.name): configured — make sure you're logged in at the Linux screen, then connect."
        } else {
            appendSetupLog("✗ Setup didn't finish (exit \(code)). See the log above.")
            status = "Setup didn't finish on \(host.name) — check the setup log."
        }
    }

    /// On connecting to a Linux host, stream a short status readout from the box
    /// into the Screen tab's in-app preview. No Mac Terminal window opens.
    private func streamConnectStatus(_ host: RemoteHost) {
        let password = SecretStore.remotePassword(hostID: host.idString) ?? ""
        guard !password.isEmpty, !host.username.isEmpty, RemotePC.sshpassAvailable else { return }
        remoteTerminalLog = []
        isStreamingRemoteTerminal = true
        let statusCommand = """
        echo "=== $(hostname) ==="; echo "user: $(whoami)"; uptime; \
        echo "--- remote desktop ---"; grdctl status 2>/dev/null | grep -iE 'status|port|view-only' || echo "grdctl: n/a"
        """
        Task { [weak self] in
            let code = await RemotePC.runUserScriptStreaming(
                host: host.host, username: host.username, port: RemotePC.sshPort,
                password: password, script: "read -r PW\n" + statusCommand) { [weak self] line in
                    if line.contains("[sudo]") { return }
                    self?.appendRemoteTerminalLog(line)
                }
            await MainActor.run {
                guard let self else { return }
                if code != 0 && self.remoteTerminalLog.isEmpty {
                    self.appendRemoteTerminalLog("✗ Couldn't read status over SSH (exit \(code)).")
                }
                self.isStreamingRemoteTerminal = false
            }
        }
    }

    // MARK: - PC: reachability (ping)

    /// Per-host reachability: nil = unknown/never checked, true = online.
    var hostReachability: [UUID: Bool] = [:]
    /// Hosts with an in-flight ping (so the UI can show a spinner).
    var hostsBeingPinged: Set<UUID> = []

    /// Pings every saved host and records whether it replied.
    func refreshAllHostReachability() async {
        await withTaskGroup(of: Void.self) { group in
            for host in remoteHosts {
                group.addTask {
                    await self.pingHost(host)
                    await MainActor.run {
                        if self.connectedRemoteHostID == host.id && self.hostReachability[host.id] == false {
                            self.connectedRemoteHostID = nil
                            self.droppedHostIDs.insert(host.id)
                            self.status = "\(host.name) went offline"
                        }
                    }
                }
            }
        }
    }

    private func attemptPCAutoReconnects() async {
        for host in remoteHosts {
            guard host.autoReconnect else { continue }
            if droppedHostIDs.contains(host.id) {
                let alive = await RemotePC.ping(host.host)
                hostReachability[host.id] = alive
                if alive {
                    droppedHostIDs.remove(host.id)
                    connectRemoteHost(host)
                    status = "Auto-reconnected computer \(host.name)"
                }
            }
        }
    }

    func pingHost(_ host: RemoteHost) async {
        hostsBeingPinged.insert(host.id)
        let alive = await RemotePC.ping(host.host)
        hostsBeingPinged.remove(host.id)
        hostReachability[host.id] = alive
    }

    // MARK: - PC: SSH terminal

    /// Opens Terminal.app with an SSH session to the host.
    func openSSH(_ host: RemoteHost) async {
        let ok = await RemotePC.openSSH(host: host.host, username: host.username, port: nil)
        status = ok ? "Opened SSH to \(host.name) in Terminal" : "Couldn't open Terminal for SSH"
    }

    // MARK: - PC: file transfer

    /// Opens the host's file share in Finder over SMB — the one network protocol
    /// Finder mounts natively on all three OSes (Windows File Sharing, Linux
    /// Samba, macOS File Sharing). Finder prompts for credentials. (Finder can't
    /// mount SFTP, so SMB is the universal path; the host must have SMB sharing
    /// enabled.)
    func openFiles(_ host: RemoteHost) async {
        let ok = await RemotePC.openFileShare(scheme: "smb",
                                              host: host.host,
                                              username: host.username)
        // `open smb://…` succeeds once it hands off to Finder; the actual mount
        // happens (and may fail) asynchronously inside Finder, so we can't detect
        // that here. If it errors, it's almost always because SMB sharing isn't
        // set up on the host — the Files tab's setup guide covers that.
        if ok {
            status = host.os == .linux
                ? "Opening \(host.name) in Finder… (if it can't connect, set up Samba — see the guide below)"
                : "Opening \(host.name)'s files in Finder…"
        } else {
            status = "Couldn't open file share for \(host.name)"
        }
    }

    /// Copy files to remote PC using scp (optimized for speed)
    func transferFilesToPC(_ filePaths: [String], toHost host: RemoteHost) async {
        let username = host.username
        let hostname = host.host
        let portArg = host.port.map { ["-P", "\($0)"] } ?? []
        let portArgSSH = host.port.map { ["-p", "\($0)"] } ?? []
        let target = username.isEmpty ? hostname : "\(username)@\(hostname)"
        let dest = host.destFolder
        
        status = "Transferring to \(host.name)..."
        
        let mkdirCmd = "/usr/bin/ssh"
        let mkdirArgs = portArgSSH + [target, "mkdir -p \"\(dest)\""]
        _ = await Shell.run(mkdirCmd, mkdirArgs)
        
        // Single command, optimized cipher, no compression, recursive
        var scpArgs = portArg + ["-o", "Compression=no", "-c", "aes128-gcm@openssh.com", "-r"]
        scpArgs.append(contentsOf: filePaths)
        scpArgs.append("\(target):\"\(dest)\"")
        
        let result = await Shell.run("/usr/bin/scp", scpArgs)
        let succeeded = (result.exitCode == 0)
        
        if succeeded {
            status = "Successfully transferred \(filePaths.count) files to \(host.name): \(dest)"
        } else {
            status = "Failed to transfer files to \(host.name). Make sure SSH/Samba is configured and SSH keys are set up."
        }
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

    /// All currently-connected, usable phones — what the menu bar lists and what
    /// a file drop can target.
    var usableDevices: [Device] {
        devices.filter { $0.state.isUsable }
    }

    func transferFilesFromDragDrop(_ filePaths: [String]) async {
        // If no device is selected, try to refresh first to see if any are connected
        if selectedSerial == nil {
            await refreshDevices()
        }

        // If still nil, try to pick the first connected/usable one
        if selectedSerial == nil {
            if let firstUsable = devices.first(where: { $0.state.isUsable }) {
                await select(firstUsable.serial)
            }
        }

        guard let serial = selectedSerial else {
            status = "No connected device available for file transfer."
            return
        }
        await transferFiles(filePaths, toSerial: serial)
    }

    /// Transfer dropped files to a specific device by serial (used by the menu
    /// bar's drop-target picker). Selects that device, navigates to its transfer
    /// folder, and uploads.
    func transferFiles(_ filePaths: [String], toSerial serial: String) async {
        guard devices.contains(where: { $0.serial == serial && $0.state.isUsable }) else {
            status = "That device is no longer connected."
            return
        }
        if selectedSerial != serial { await select(serial) }

        // Ensure the destination folder exists on the phone
        let dest = settings.phoneDestFolder
        _ = await ADB.makeDirectory(serial, path: dest)

        // Open/select the files tab and navigate there
        selectedTab = .files
        browsePath = dest

        // Upload the files
        await uploadToCurrentFolder(localPaths: filePaths)
    }

    // MARK: - Menu-bar per-device actions
    //
    // The screenshot / record / mirror logic operates on the currently-selected
    // device (and owns a single recorder/mirror session). To act on a specific
    // device from the menu bar, select it first, then run the existing action —
    // reusing all the session-management logic without duplicating it.

    func menuBarScreenshot(serial: String) async {
        if selectedSerial != serial { await select(serial) }
        await captureScreenshot()
    }

    func menuBarToggleRecording(serial: String) async {
        if selectedSerial != serial { await select(serial) }
        await toggleScreenRecording()
    }

    func menuBarToggleMirror(serial: String) async {
        if selectedSerial != serial { await select(serial) }
        toggleMirror()
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

    // MARK: - Unlock & autofill (Touch ID-gated)

    /// True if this Mac can prompt for Touch ID (else it falls back to the Mac
    /// password). Drives whether the UI shows a fingerprint affordance.
    var biometricsAvailable: Bool { Biometrics.isAvailable }

    /// Whether a lock PIN/password is saved for the selected device.
    var hasSavedLockPIN: Bool {
        guard let serial = selectedSerial else { return false }
        return SecretStore.hasLockPIN(serial: serial)
    }

    /// Bumped after any secret-store mutation so SwiftUI re-reads `hasSavedLockPIN`
    /// (Keychain isn't observable on its own).
    var secretsRevision = 0

    /// Store (or replace) the lock-screen PIN for the selected device. The value
    /// goes into the Keychain behind Touch ID — we never keep a plaintext copy.
    func saveLockPIN(_ pin: String) {
        guard let serial = selectedSerial else { return }
        let trimmed = pin.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if SecretStore.setLockPIN(trimmed, serial: serial) {
            status = "Lock PIN saved (Touch ID required to use it)"
        } else {
            status = "Couldn't save the lock PIN to the Keychain"
        }
        secretsRevision += 1
    }

    func clearLockPIN() {
        guard let serial = selectedSerial else { return }
        SecretStore.clearLockPIN(serial: serial)
        status = "Saved lock removed"
        secretsRevision += 1
    }

    /// One-click unlock: Touch ID → read the saved PIN → wake, dismiss the lock
    /// curtain, type the PIN, and submit. No secret is touched before the
    /// fingerprint is verified. (PIN/password only — patterns can't be replayed
    /// without root.)
    func unlockPhone() async {
        guard let serial = selectedSerial,
              selectedDevice?.state.isUsable == true else {
            status = "Select a connected device first"
            return
        }
        guard SecretStore.hasLockPIN(serial: serial) else {
            status = "Set your phone's lock PIN first"
            return
        }

        // Gate on Touch ID before any secret is read.
        guard await Biometrics.authenticate(reason: "unlock your phone") else {
            status = "Unlock cancelled"
            return
        }
        guard let pin = SecretStore.lockSecret(serial: serial,
                                               reason: "Unlock your phone") else {
            status = "Couldn't read the saved PIN"
            return
        }

        status = "Unlocking…"
        await ADB.wakeAndPrepareLockScreen(serial)
        await ADB.submitLockPIN(serial, pin: pin)
        status = "Unlock sent"
    }

    func refreshRingerAndDNDStatus() async {
        guard let serial = selectedSerial,
              selectedDevice?.state.isUsable == true else { return }
        let ringer = await ADB.getRingerMode(serial)
        let zen = await ADB.getZenMode(serial)
        isSilent = (ringer == 0)
        isVibrate = (ringer == 1)
        isDND = (zen != nil && zen! > 0)
    }

    func toggleSilent() async {
        guard let serial = selectedSerial,
              selectedDevice?.state.isUsable == true else { return }
        let targetMode = isSilent ? "NORMAL" : "SILENT"
        isSilent = !isSilent
        if isSilent { isVibrate = false }
        status = isSilent ? "Silent mode ON" : "Silent mode OFF"
        _ = await ADB.setRingerMode(serial, mode: targetMode)
        await refreshRingerAndDNDStatus()
    }

    func toggleVibrate() async {
        guard let serial = selectedSerial,
              selectedDevice?.state.isUsable == true else { return }
        let targetMode = isVibrate ? "NORMAL" : "VIBRATE"
        isVibrate = !isVibrate
        if isVibrate { isSilent = false }
        status = isVibrate ? "Vibrate mode ON" : "Vibrate mode OFF"
        _ = await ADB.setRingerMode(serial, mode: targetMode)
        await refreshRingerAndDNDStatus()
    }

    func toggleDND() async {
        guard let serial = selectedSerial,
              selectedDevice?.state.isUsable == true else { return }
        let targetActive = !isDND
        isDND = targetActive
        status = isDND ? "Do Not Disturb ON" : "Do Not Disturb OFF"
        _ = await ADB.setDND(serial, enabled: targetActive)
        await refreshRingerAndDNDStatus()
    }

    // MARK: - Incoming-call alerts

    /// Wire the floating call panel's buttons to adb actions. Called once at
    /// startup.
    private func setupCallController() {
        callController.onAnswer = { [weak self] in
            Task { await self?.answerIncomingCall() }
        }
        callController.onDecline = { [weak self] in
            Task { await self?.declineIncomingCall() }
        }
        callController.onSilence = { [weak self] in
            Task { await self?.silenceIncomingCall() }
        }
        callController.onIgnore = { [weak self] in
            Task { await self?.ignoreIncomingCall() }
        }
        callController.onMute = { [weak self] in
            Task { await self?.toggleCallMute() }
        }
        callController.onClose = { [weak self] in
            self?.hideCallPanel()
        }
    }

    /// Hides the call panel at the user's request (the ✕ on an active call)
    /// without touching the call itself — it stays connected on the phone. Keeps
    /// the panel suppressed for the rest of this call so the poller won't re-pop
    /// it on the next state refresh.
    private func hideCallPanel() {
        panelHiddenForCall = currentCallNumber ?? ""
        callController.dismiss()
    }

    /// Number of the active call whose panel the user dismissed with ✕, so the
    /// poller stays quiet until that call ends. nil means nothing is suppressed.
    @ObservationIgnored private var panelHiddenForCall: String?

    /// One poll of the selected device's call state. Shows the panel for an
    /// incoming ring OR an outgoing call, keeps it up (relabeled) once connected,
    /// and dismisses it when the call ends.
    private func pollCallState() async {
        guard settings.callAlerts,
              let serial = selectedSerial,
              selectedDevice?.state.isUsable == true else {
            // No usable device or alerts disabled — make sure nothing is stuck up.
            if ringingSerial != nil { dismissCallPanel() }
            return
        }

        guard let status = await ADB.callStatus(serial) else { return }
        let previous = lastCallState
        lastCallState = status.state

        switch status.state {
        case .ringing, .dialing, .active:
            // If the user tapped Ignore for this exact call, stay hidden until it
            // ends (so the panel doesn't keep nagging).
            if let ignored = ignoredCallNumber, ignored == (status.number ?? "") {
                return
            }
            // If the user dismissed the active-call panel with ✕, keep it hidden
            // for the rest of this call (the call itself is unaffected).
            if let hidden = panelHiddenForCall, hidden == (status.number ?? "") {
                return
            }
            let phase: IncomingCallController.Phase =
                status.state == .ringing ? .incoming
                : status.state == .dialing ? .outgoing
                : .active
            // (Re)show on a state change so we don't re-pop the same panel every
            // tick, but do refresh the label as the phase advances.
            if ringingSerial != serial || previous != status.state {
                ringingSerial = serial
                currentCallNumber = status.number
                // Resolve the caller's contact name (best-effort; falls back to
                // the number on the card if there's no match).
                var name: String?
                if let number = status.number, !number.isEmpty {
                    name = await ADB.contactName(serial, number: number)
                }
                callController.show(name: name,
                                    number: status.number,
                                    deviceName: displayName(for: serial),
                                    phase: phase)
            }
        case .idle:
            // Declined, hung up, or ended → take the panel down and clear the
            // per-call ignore/hide so the next call shows normally.
            ignoredCallNumber = nil
            panelHiddenForCall = nil
            if ringingSerial != nil { dismissCallPanel() }
        }
    }

    /// Number of a call the user chose to Ignore, so the poller won't re-show its
    /// panel until that call ends. Empty string matches a withheld number.
    @ObservationIgnored private var ignoredCallNumber: String?
    /// The number currently shown, so Mute/Ignore can act on the right call.
    @ObservationIgnored private var currentCallNumber: String?

    /// The ringer mode the phone was in before the user tapped Silence, so we can
    /// restore it once the call ends. nil means Silence wasn't used this call.
    @ObservationIgnored private var ringerModeBeforeSilence: Int?

    private func dismissCallPanel() {
        // If we silenced the ringer just for this call, put the phone back the way
        // it was (NORMAL/VIBRATE/SILENT) now that the call is over.
        if let serial = ringingSerial, let mode = ringerModeBeforeSilence {
            ringerModeBeforeSilence = nil
            Task { [serial, mode] in
                await ADB.setRingerMode(serial, mode: Self.ringerModeName(mode))
                await self.refreshRingerAndDNDStatus()
            }
        }
        callController.dismiss()
        ringingSerial = nil
    }

    /// Maps a numeric ringer mode (0/1/2) to the string `set-ringer-mode` wants.
    private static func ringerModeName(_ mode: Int) -> String {
        switch mode {
        case 0: return "SILENT"
        case 1: return "VIBRATE"
        default: return "NORMAL"
        }
    }

    func answerIncomingCall() async {
        guard let serial = ringingSerial else { return }
        await ADB.answerCall(serial)
        status = "Call answered — audio is on the phone"
        dismissCallPanel()
    }

    func declineIncomingCall() async {
        guard let serial = ringingSerial else { return }
        await ADB.declineCall(serial)
        status = "Call declined"
        dismissCallPanel()
    }

    func silenceIncomingCall() async {
        guard let serial = ringingSerial else { return }
        // Remember the phone's current ringer mode (once) so we can restore it
        // when the call ends — Silence should mute just this call, not leave the
        // phone silent afterwards.
        if ringerModeBeforeSilence == nil {
            ringerModeBeforeSilence = await ADB.getRingerMode(serial) ?? 2
        }
        await ADB.silenceRinger(serial)
        callController.markSilenced()
        status = "Ringer silenced for this call"
        await refreshRingerAndDNDStatus()
    }

    /// Dismisses the panel for the current call without rejecting it — the call
    /// keeps ringing on the phone but stops nagging you on the Mac. Also silences
    /// the ringer (temporarily, restored when the call ends) so it's not annoying.
    func ignoreIncomingCall() async {
        guard let serial = ringingSerial else { return }
        if ringerModeBeforeSilence == nil {
            ringerModeBeforeSilence = await ADB.getRingerMode(serial) ?? 2
        }
        await ADB.silenceRinger(serial)
        // Remember this call so the poller won't re-show it until it ends.
        ignoredCallNumber = currentCallNumber ?? ""
        status = "Call ignored"
        // Take the panel down but keep the ringer-restore pending; clear ringingSerial
        // last so dismissCallPanel restores the ringer when the call truly ends —
        // here we only hide the panel, restore happens on idle.
        callController.dismiss()
        await refreshRingerAndDNDStatus()
    }

    /// Toggles the microphone mute on the active call, then reads back the real
    /// mic state so the button always reflects what the phone actually did.
    func toggleCallMute() async {
        guard let serial = ringingSerial else { return }
        await ADB.toggleCallMute(serial)
        // Give the phone a moment to apply, then sync the button to reality.
        try? await Task.sleep(for: .milliseconds(400))
        let muted = await ADB.isMicMuted(serial) ?? false
        callController.setMuted(muted)
        status = muted ? "Call mic muted" : "Call mic unmuted"
    }

    // MARK: - Caller tab (call log + dialer)

    /// Filtered call log honoring the search box (matches name or number).
    var filteredCallLog: [ADB.CallLogEntry] {
        let q = callerSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return callLog }
        return callLog.filter {
            ($0.name?.lowercased().contains(q) ?? false) || $0.number.lowercased().contains(q)
        }
    }

    /// Loads the recent call log AND all contacts for the selected device.
    func refreshCallLog() async {
        guard let serial = selectedSerial,
              selectedDevice?.state.isUsable == true else {
            callLog = []; contacts = []
            return
        }
        isLoadingCallLog = true
        defer { isLoadingCallLog = false }
        async let log = ADB.callLog(serial, limit: 50)
        async let cts = ADB.contacts(serial)
        callLog = await log
        contacts = await cts
    }

    /// All contacts filtered by the Contacts-tab search box (name or number).
    var filteredContacts: [ADB.Contact] {
        let q = contactSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return contacts }
        return contacts.filter {
            $0.name.lowercased().contains(q) ||
            $0.number.filter(\.isNumber).contains(q.filter(\.isNumber))
        }
    }

    /// Loads contacts for the Contacts tab (separate so it can load on its own).
    func refreshContacts() async {
        guard let serial = selectedSerial,
              selectedDevice?.state.isUsable == true else {
            contacts = []
            return
        }
        isLoadingContacts = true
        defer { isLoadingContacts = false }
        contacts = await ADB.contacts(serial)
    }

    /// Contacts matching whatever is typed in the dialer field (name or number),
    /// so the user sees who they're about to call. Empty when the field is empty.
    var dialerMatches: [ADB.Contact] {
        let raw = dialerInput.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return [] }
        let q = raw.lowercased()
        let digits = raw.filter(\.isNumber)
        return contacts.filter {
            $0.name.lowercased().contains(q) ||
            (!digits.isEmpty && $0.number.filter(\.isNumber).contains(digits))
        }
    }

    /// Dials a number on the phone (from the dialer field or a call-log row).
    func dial(_ number: String) async {
        guard let serial = selectedSerial,
              selectedDevice?.state.isUsable == true else {
            status = "Select a connected device first"
            return
        }
        let n = number.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        await ADB.dial(serial, number: n)
        status = "Calling \(n)…"
    }

    // MARK: - Messages tab

    /// Loads SMS conversations and resolves contact names for each thread.
    /// `showLoading` is false for the background live-refresh so the sidebar
    /// doesn't flash a spinner every few seconds.
    func refreshMessages(showLoading: Bool = true) async {
        guard let serial = selectedSerial,
              selectedDevice?.state.isUsable == true else {
            conversations = []
            return
        }
        if showLoading { isLoadingMessages = true }
        defer { if showLoading { isLoadingMessages = false } }
        var convos = await ADB.conversations(serial)
        // Make sure contacts are loaded so we can name the threads.
        if contacts.isEmpty { contacts = await ADB.contacts(serial) }
        for i in convos.indices {
            convos[i].contactName = contactName(forNumber: convos[i].address)
        }
        // Only reassign if something actually changed, so the UI doesn't redraw
        // (and the chat doesn't re-scroll) on every identical poll.
        if convos != conversations { conversations = convos }
    }

    /// The currently selected conversation in the Messages master-detail view.
    var selectedConversation: ADB.Conversation? {
        guard let id = selectedThreadID else { return nil }
        return conversations.first { $0.threadID == id }
    }

    /// Conversations filtered by the message search box (name, number, or body).
    var filteredConversations: [ADB.Conversation] {
        let q = messageSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return conversations }
        return conversations.filter {
            ($0.contactName?.lowercased().contains(q) ?? false) ||
            $0.address.lowercased().contains(q) ||
            $0.messages.contains { $0.body.lowercased().contains(q) }
        }
    }

    /// Looks up a saved contact name for a number (local match against the loaded
    /// contacts; compares trailing digits to tolerate formatting differences).
    private func contactName(forNumber number: String) -> String? {
        let target = number.filter(\.isNumber)
        guard target.count >= 6 else { return nil }
        let tail = String(target.suffix(10))
        return contacts.first { $0.number.filter(\.isNumber).hasSuffix(tail) }?.name
    }

    /// Opens the Messages tab focused on the existing conversation with `number`
    /// (from a contact's View-messages button) so the user can read the thread on
    /// the Mac. View-only — texting is disabled, so there's nothing to do when no
    /// history exists beyond saying so.
    func openConversation(number: String, name: String?) async {
        selectedTab = .messages
        if conversations.isEmpty { await refreshMessages() }
        // Find an existing thread for this number (compare trailing digits).
        let tail = String(number.filter(\.isNumber).suffix(10))
        messageSearch = ""
        if let convo = conversations.first(where: {
            $0.address.filter(\.isNumber).hasSuffix(tail)
        }) {
            selectedThreadID = convo.threadID
        } else {
            selectedThreadID = nil
            status = "No messages with \(name ?? number)"
        }
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
