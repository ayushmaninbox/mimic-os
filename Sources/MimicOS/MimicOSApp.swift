import SwiftUI
import AppKit

@main
struct MimicOSApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("MimicOS", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
                .task {
                    appDelegate.model = model
                    appDelegate.setupStatusItem()
                    await model.onAppear()
                }
                .onDisappear { model.onDisappear() }
        }
        .windowResizability(.contentMinSize)
    }
}

// MARK: - App Delegate Status Item and Drag-Drop Manager

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Set by the App once the model exists, so we can read the user's setting.
    weak var model: AppModel?
    private var statusItem: NSStatusItem?
    private var portalPanel: PortalPanel?
    private var hideTimer: Timer?
    private let portalDragModel = PortalDragModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        syncActivationPolicy()
    }

    func setupStatusItem() {
        guard statusItem == nil else { return }
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        syncStatusItemVisibility()
        
        if let button = statusItem?.button {
            let config = NSImage.SymbolConfiguration(pointSize: 16.0, weight: .medium)
            button.image = NSImage(systemSymbolName: "laptopcomputer.and.iphone", accessibilityDescription: "MimicOS")?
                .withSymbolConfiguration(config)
            
            // Create and add the drag-and-drop overlay view
            let dragView = DragDropOverlayView(frame: button.bounds)
            dragView.autoresizingMask = [.width, .height]
            dragView.model = model
            dragView.onDragEntered = { [weak self] screenPoint in
                self?.showPortal(at: screenPoint)
            }
            dragView.onDragUpdated = { [weak self] screenPoint in
                self?.updatePortal(at: screenPoint)
            }
            dragView.onDragExited = { [weak self] in
                self?.hidePortalWithDelay()
            }
            dragView.onPerformDrop = { [weak self] urls in
                self?.handleDrop(urls: urls)
            }
            button.addSubview(dragView)
        }
        
        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    func syncActivationPolicy() {
        guard let model = model else { return }
        let hideInDock = model.settings.hideInDock
        
        if hideInDock {
            NSApp.setActivationPolicy(.accessory)
        } else {
            let hasOpenWindows = NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.title != "MimicOS-Portal" && $0.className != "NSStatusBarWindow" }
            if hasOpenWindows {
                NSApp.setActivationPolicy(.regular)
            } else {
                let runInBackground = model.settings.runInBackground
                NSApp.setActivationPolicy(runInBackground ? .accessory : .regular)
            }
        }
    }

    func syncStatusItemVisibility() {
        guard let model = model else { return }
        let hideInMenuBar = model.settings.hideInMenuBar
        statusItem?.isVisible = !hideInMenuBar
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
            syncActivationPolicy()
            return false
        }
        return true
    }

    /// Clicking the Dock icon (when visible) reopens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                window.makeKeyAndOrderFront(nil)
            }
            syncActivationPolicy()
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    // MARK: - Portal Window Management
    
    func showPortal(at screenPoint: CGPoint) {
        hideTimer?.invalidate()
        hideTimer = nil
        
        if portalPanel == nil {
            let hostingView = NSHostingView(rootView: PortalView(dragModel: portalDragModel))
            let panel = PortalPanel(contentView: hostingView)
            panel.onDragEntered = { [weak self] pt in
                self?.hideTimer?.invalidate()
                self?.hideTimer = nil
                self?.portalDragModel.isDraggingOver = true
                self?.showPortal(at: pt)
            }
            panel.onDragUpdated = { [weak self] pt in
                self?.hideTimer?.invalidate()
                self?.hideTimer = nil
                self?.portalDragModel.isDraggingOver = true
                self?.updatePortal(at: pt)
            }
            panel.onDragExited = { [weak self] in
                self?.portalDragModel.isDraggingOver = false
                self?.hidePortalWithDelay()
            }
            panel.onPerformDrop = { [weak self] urls in
                self?.portalDragModel.isDraggingOver = false
                self?.handleDrop(urls: urls)
            }
            portalPanel = panel
        }
        
        guard let button = statusItem?.button, let window = button.window else { return }
        let buttonFrame = window.frame
        // Panel includes the transparent inset margin on every side (so the
        // card's rounded border + shadow aren't clipped); the visible card is
        // ~320×220 inside it.
        let portalWidth: CGFloat = 320 + PortalView.panelInset * 2
        let portalHeight: CGFloat = 220 + PortalView.panelInset * 2
        let x = buttonFrame.midX - portalWidth / 2
        // Position so the *visible card* top sits just below the menu bar. The
        // card is inset by `panelInset` inside the panel, so:
        //   cardTop = y + portalHeight - panelInset
        // We want cardTop at buttonFrame.minY (the menu bar's bottom) minus a
        // couple points so the card clears the menu items above it. The
        // transparent inset still bridges up to the icon for drag continuity.
        let cardTopGap: CGFloat = 2
        let y = buttonFrame.minY - cardTopGap - (portalHeight - PortalView.panelInset)

        portalPanel?.setFrame(NSRect(x: x, y: y, width: portalWidth, height: portalHeight), display: true)
        if portalPanel?.isVisible == false {
            portalPanel?.orderFront(nil)
        }
    }
    
    func updatePortal(at screenPoint: CGPoint) {
        if portalPanel?.isVisible == false {
            portalPanel?.orderFront(nil)
        }
    }
    
    func hidePortalWithDelay() {
        hideTimer?.invalidate()
        // Generous grace period: the cursor needs time to travel from the
        // menu-bar icon down to the portal (and to pause over it) without the
        // panel vanishing underneath. Any drag re-entry invalidates this timer.
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.portalDragModel.isDraggingOver = false
                self?.portalPanel?.orderOut(nil)
            }
        }
    }
    
    private func hidePortal() {
        hidePortalWithDelay()
    }
    
    func handleDrop(urls: [URL]) {
        hideTimer?.invalidate()
        hideTimer = nil
        portalPanel?.orderOut(nil)

        guard let model = model else { return }
        let paths = urls.map { $0.path }
        let active = model.usableDevices
        let computers = model.remoteHosts

        let totalCount = active.count + computers.count
        if totalCount > 1 {
            presentDropTargetPicker(devices: active, computers: computers, paths: paths)
            return
        }

        if let device = active.first {
            model.openMainWindowAction?()
            Task { await model.transferFiles(paths, toSerial: device.serial) }
        } else if let host = computers.first {
            Task { await model.transferFilesToPC(paths, toHost: host) }
        } else {
            model.status = "No connected device or computer available for file transfer."
        }
    }

    /// Pops up a menu under the status item listing the active devices and PCs, so
    /// the user picks which one receives the dropped files. Each row is a rich
    /// SwiftUI view (icon + name + subtitle) hosted in the native menu, so it
    /// looks like the rest of MimicOS while keeping the menu's reliable behaviour.
    private func presentDropTargetPicker(devices: [Device], computers: [RemoteHost], paths: [String]) {
        let menu = NSMenu()

        // Title row.
        let header = NSMenuItem()
        let title = paths.count == 1 ? "Send 1 file to…" : "Send \(paths.count) files to…"
        header.view = hostedMenuRow(DropPickerHeader(title: title), height: 30)
        header.isEnabled = false
        menu.addItem(header)

        func addSection(_ name: String) {
            let s = NSMenuItem()
            s.view = hostedMenuRow(DropPickerSectionHeader(title: name), height: 22)
            s.isEnabled = false
            menu.addItem(s)
        }

        if !devices.isEmpty {
            addSection("Phones")
            for device in devices {
                let item = NSMenuItem()
                item.target = self
                item.action = #selector(dropTargetChosen(_:))
                item.representedObject = DropTarget(serial: device.serial, isPC: false, id: nil, paths: paths)
                item.view = hostedMenuRow(
                    DropTargetRow(icon: "iphone.gen3", name: device.displayName,
                                  subtitle: device.isWireless ? "Wireless" : "USB", item: item),
                    height: 40)
                menu.addItem(item)
            }
        }

        if !computers.isEmpty {
            addSection("Computers")
            for host in computers {
                let item = NSMenuItem()
                item.target = self
                item.action = #selector(dropTargetChosen(_:))
                item.representedObject = DropTarget(serial: nil, isPC: true, id: host.id, paths: paths)
                item.view = hostedMenuRow(
                    DropTargetRow(icon: host.os.systemImage, name: host.name,
                                  subtitle: host.subtitle, item: item),
                    height: 40)
                menu.addItem(item)
            }
        }

        if let button = statusItem?.button {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.height + 4),
                       in: button)
        }
    }

    /// Wraps a SwiftUI row in a fixed-size hosting view for use as `NSMenuItem.view`.
    private func hostedMenuRow<V: View>(_ view: V, height: CGFloat) -> NSView {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        hosting.autoresizingMask = [.width]
        return hosting
    }

    /// Box carrying a drop's target serial/id + file paths through `representedObject`.
    private final class DropTarget: NSObject {
        let serial: String?
        let isPC: Bool
        let id: UUID?
        let paths: [String]
        init(serial: String?, isPC: Bool, id: UUID?, paths: [String]) {
            self.serial = serial
            self.isPC = isPC
            self.id = id
            self.paths = paths
        }
    }

    @objc private func dropTargetChosen(_ sender: NSMenuItem) {
        guard let model = model, let target = sender.representedObject as? DropTarget else { return }
        if target.isPC {
            if let id = target.id, let host = model.remoteHosts.first(where: { $0.id == id }) {
                Task { await model.transferFilesToPC(target.paths, toHost: host) }
            }
        } else if let serial = target.serial {
            model.openMainWindowAction?()
            Task { await model.transferFiles(target.paths, toSerial: serial) }
        }
    }

    // MARK: - NSMenuDelegate

    /// Builds a native macOS menu: each connected phone and each computer is a
    /// real `NSMenuItem` that opens a proper submenu on hover. Native menus size
    /// and scroll themselves — no custom SwiftUI hosting / height juggling, which
    /// was the source of the clipping and sizing bugs.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model = model else { return }

        let devices = model.usableDevices
        let computers = model.remoteHosts

        if devices.isEmpty && computers.isEmpty {
            let empty = NSMenuItem(title: "No devices connected", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            empty.image = NSImage(systemSymbolName: "cable.connector.slash", accessibilityDescription: nil)
            menu.addItem(empty)
        }

        // Phones
        for device in devices {
            let item = NSMenuItem(title: device.displayName, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: nil)
            item.submenu = buildPhoneSubmenu(for: device, model: model)
            menu.addItem(item)
        }

        // Computers
        for host in computers {
            let connected = model.connectedRemoteHostID == host.id
            let reachable = model.hostReachability[host.id] ?? false
            let online = connected || reachable

            let item = NSMenuItem(title: host.name, action: nil, keyEquivalent: "")
            let img = NSImage(systemSymbolName: host.os.systemImage, accessibilityDescription: nil)
            // Tint the icon green when connected/online, like the sidebar.
            if online, let tinted = img?.withSymbolConfiguration(.init(paletteColors: [.systemGreen])) {
                item.image = tinted
            } else {
                item.image = img
            }
            if online {
                item.submenu = buildComputerSubmenu(for: host, connected: connected, model: model)
            } else {
                // Offline: no submenu, dimmed, shows status.
                item.isEnabled = false
                item.title = "\(host.name)  (offline)"
            }
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let open = NSMenuItem(title: "Open MimicOS", action: #selector(openMimicOS), keyEquivalent: "o")
        open.target = self
        open.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)
        menu.addItem(open)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit MimicOS", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)
    }

    private func buildPhoneSubmenu(for device: Device, model: AppModel) -> NSMenu {
        let submenu = NSMenu()
        let serial = device.serial
        let isSelected = model.selectedSerial == serial

        // Mirroring first — it's the primary action.
        let mirroring = model.mirroringSerials.contains(serial)
        let mir = NSMenuItem(title: mirroring ? "Stop Mirroring" : "Start Mirroring", action: #selector(toggleMirroring(_:)), keyEquivalent: "")
        mir.target = self; mir.representedObject = serial
        mir.image = NSImage(systemSymbolName: mirroring ? "stop.circle" : "play.circle", accessibilityDescription: nil)
        submenu.addItem(mir)

        let shot = NSMenuItem(title: "Take Screenshot", action: #selector(takeScreenshot(_:)), keyEquivalent: "")
        shot.target = self; shot.representedObject = serial
        shot.image = NSImage(systemSymbolName: "camera", accessibilityDescription: nil)
        submenu.addItem(shot)

        let recording = isSelected && model.isRecording
        let rec = NSMenuItem(title: recording ? "Stop Recording" : "Record Screen", action: #selector(toggleRecording(_:)), keyEquivalent: "")
        rec.target = self; rec.representedObject = serial
        rec.image = NSImage(systemSymbolName: recording ? "stop.circle" : "record.circle", accessibilityDescription: nil)
        submenu.addItem(rec)

        let sidebar = model.settings.showSidebar
        let side = NSMenuItem(title: sidebar ? "Hide Control Sidebar" : "Show Control Sidebar", action: #selector(toggleSidebar), keyEquivalent: "")
        side.target = self
        side.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
        submenu.addItem(side)

        submenu.addItem(NSMenuItem.separator())

        let settings = NSMenuItem(title: "Device Settings…", action: #selector(openDeviceSettings(_:)), keyEquivalent: "")
        settings.target = self; settings.representedObject = serial
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        submenu.addItem(settings)

        return submenu
    }

    private func buildComputerSubmenu(for host: RemoteHost, connected: Bool, model: AppModel) -> NSMenu {
        let submenu = NSMenu()
        let id = host.idString

        let screen = NSMenuItem(title: connected ? "Disconnect Screen" : "Start Screen Sharing", action: #selector(toggleComputerScreen(_:)), keyEquivalent: "")
        screen.target = self; screen.representedObject = id
        screen.image = NSImage(systemSymbolName: connected ? "wifi.slash" : "display", accessibilityDescription: nil)
        submenu.addItem(screen)

        let files = NSMenuItem(title: "Open Files in Finder", action: #selector(openComputerFiles(_:)), keyEquivalent: "")
        files.target = self; files.representedObject = id
        files.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        submenu.addItem(files)

        let term = NSMenuItem(title: "Open SSH Terminal", action: #selector(openComputerTerminal(_:)), keyEquivalent: "")
        term.target = self; term.representedObject = id
        term.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        submenu.addItem(term)

        submenu.addItem(NSMenuItem.separator())

        let settings = NSMenuItem(title: "Computer Settings…", action: #selector(openComputerSettings(_:)), keyEquivalent: "")
        settings.target = self; settings.representedObject = id
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        submenu.addItem(settings)

        return submenu
    }

    // MARK: - Menu Actions

    private func host(from sender: NSMenuItem) -> RemoteHost? {
        guard let model = model,
              let idString = sender.representedObject as? String,
              let uuid = UUID(uuidString: idString) else { return nil }
        return model.remoteHosts.first { $0.id == uuid }
    }

    @objc private func takeScreenshot(_ sender: NSMenuItem) {
        guard let model = model, let serial = sender.representedObject as? String else { return }
        Task { await model.menuBarScreenshot(serial: serial) }
    }

    @objc private func toggleRecording(_ sender: NSMenuItem) {
        guard let model = model, let serial = sender.representedObject as? String else { return }
        Task { await model.menuBarToggleRecording(serial: serial) }
    }

    @objc private func toggleMirroring(_ sender: NSMenuItem) {
        guard let model = model, let serial = sender.representedObject as? String else { return }
        Task { await model.menuBarToggleMirror(serial: serial) }
    }

    @objc private func toggleSidebar() {
        guard let model = model else { return }
        model.setSidebarVisible(!model.settings.showSidebar)
    }

    @objc private func toggleComputerScreen(_ sender: NSMenuItem) {
        guard let model = model, let host = host(from: sender) else { return }
        if model.connectedRemoteHostID == host.id {
            model.disconnectRemoteHost()
        } else {
            model.selection = .computer(host.id)
            Task { await model.userConnectRemoteHost(host) }
        }
    }

    @objc private func openComputerFiles(_ sender: NSMenuItem) {
        guard let model = model, let host = host(from: sender) else { return }
        model.selection = .computer(host.id)
        Task { await model.openFiles(host) }
    }

    @objc private func openComputerTerminal(_ sender: NSMenuItem) {
        guard let model = model, let host = host(from: sender) else { return }
        model.selection = .computer(host.id)
        Task { await model.openSSH(host) }
    }

    @objc private func openDeviceSettings(_ sender: NSMenuItem) {
        guard let model = model, let serial = sender.representedObject as? String else { return }
        Task {
            await model.select(serial)
            model.openSection(.settings)
        }
    }

    @objc private func openComputerSettings(_ sender: NSMenuItem) {
        guard let model = model, let host = host(from: sender) else { return }
        model.selection = .computer(host.id)
        model.selectedPCTab = .settings
        model.openMainWindowAction?()
    }

    @objc private func openMimicOS() {
        model?.openMainWindowAction?()
    }

    @objc private func openSettings() {
        // The menu-bar "Settings" opens the universal (app-wide) settings.
        model?.showUniversalSettings = true
        model?.openMainWindowAction?()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - Supporting Views and Classes

final class PortalDragModel: ObservableObject {
    @Published var isDraggingOver = false
}



/// Floating glass panel that hosts the SwiftUI `PortalView`. Drag handling
/// lives on its content view (`PortalContentView`) — AppKit routes drag events
/// to a window's *content view*, not the window object, so the panel itself
/// can't intercept them.
class PortalPanel: NSPanel {
    var onDragEntered: ((CGPoint) -> Void)? {
        didSet { dropView.onDragEntered = onDragEntered }
    }
    var onDragUpdated: ((CGPoint) -> Void)? {
        didSet { dropView.onDragUpdated = onDragUpdated }
    }
    var onDragExited: (() -> Void)? {
        didSet { dropView.onDragExited = onDragExited }
    }
    var onPerformDrop: (([URL]) -> Void)? {
        didSet { dropView.onPerformDrop = onPerformDrop }
    }

    private let dropView: PortalContentView

    init(contentView: NSView) {
        let size = NSSize(width: 320 + PortalView.panelInset * 2,
                          height: 220 + PortalView.panelInset * 2)
        dropView = PortalContentView(frame: NSRect(origin: .zero, size: size))
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .statusBar
        self.backgroundColor = .clear
        self.isOpaque = false
        // No window shadow: the panel is transparent and larger than the
        // visible card (it includes the inset margin), so a window shadow would
        // draw a ghost box around the whole panel. The SwiftUI card draws its
        // own shadow instead.
        self.hasShadow = false

        // The SwiftUI view fills the drop view, which is the panel's content
        // view and the actual drag destination.
        contentView.frame = dropView.bounds
        contentView.autoresizingMask = [.width, .height]
        dropView.addSubview(contentView)
        self.contentView = dropView
    }
}

/// Content view for `PortalPanel` that receives the file-drag events. Because
/// it sits in a borderless panel, it converts drag locations back to screen
/// coordinates so the manager can keep the panel pinned under the cursor.
final class PortalContentView: NSView {
    var onDragEntered: ((CGPoint) -> Void)?
    var onDragUpdated: ((CGPoint) -> Void)?
    var onDragExited: (() -> Void)?
    var onPerformDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func screenPoint(for sender: NSDraggingInfo) -> CGPoint {
        let location = sender.draggingLocation
        return window?.convertToScreen(NSRect(origin: location, size: .zero)).origin ?? .zero
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEntered?(screenPoint(for: sender))
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragUpdated?(screenPoint(for: sender))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            onPerformDrop?(urls)
            return true
        }
        return false
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct PortalView: View {
    /// Transparent margin between the visible card and the panel edges, so the
    /// rounded border and drop shadow aren't clipped. The panel dimensions in
    /// `showPortal` / `PortalPanel` add 2× this on each axis.
    static let panelInset: CGFloat = 22

    @ObservedObject var dragModel: PortalDragModel

    @State private var isAnimating = false
    @State private var pulseActive = false

    private var active: Bool { dragModel.isDraggingOver }

    /// Monochrome grey/white palette. On drag-over everything goes bright
    /// white; idle is a clearly-visible light grey (kept high so it reads on
    /// the dark card backing).
    private var monoColors: [Color] {
        active
            ? [.white, .white.opacity(0.9)]
            : [.white.opacity(0.95), Color(white: 0.7)]
    }

    var body: some View {
        // Card content.
        dropZone
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cardBackground)
        .overlay(cardBorder)
        .shadow(
            color: Color.black.opacity(0.18),
            radius: 10,
            x: 0,
            y: 4
        )
        // Transparent margin inside the panel so the rounded border and the
        // drop shadow have room to render instead of being clipped at the
        // panel edges. The panel is sized larger to compensate.
        .padding(PortalView.panelInset)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
        .onChange(of: dragModel.isDraggingOver) { _, newValue in
            if newValue {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulseActive = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { pulseActive = false }
            }
        }
    }

    // MARK: - Drop zone

    /// The dashed ring + icon + labels. This whole region is the visual target
    /// the user drags onto.
    private var dropZone: some View {
        VStack(spacing: 12) {
            ZStack {
                // Soft radial halo that breathes / intensifies on drag-over.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(active ? 0.4 : 0.22), .clear],
                            center: .center,
                            startRadius: 2,
                            endRadius: active ? 48 : 40
                        )
                    )
                    .frame(width: 96, height: 96)
                    .scaleEffect(active ? (pulseActive ? 1.12 : 1.0) : (isAnimating ? 1.06 : 0.96))

                // Animated dashed orbit ring.
                Circle()
                    .stroke(
                        AngularGradient(colors: monoColors + [monoColors.first!], center: .center),
                        style: StrokeStyle(lineWidth: active ? 3 : 2.5, lineCap: .round, dash: [5, 6])
                    )
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.25), radius: 3)
                    .rotationEffect(.degrees(isAnimating ? 360 : 0))
                    .scaleEffect(active && pulseActive ? 1.08 : 1.0)
                    .animation(.linear(duration: 14).repeatForever(autoreverses: false), value: isAnimating)

                // Filled inner disc.
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(active ? 0.28 : 0.18), Color.white.opacity(0.08)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: 50, height: 50)

                Image(systemName: active ? "arrow.down.circle.fill" : "tray.and.arrow.down.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(active ? Color.accentColor : Color.primary)
                    .scaleEffect(active ? (pulseActive ? 1.12 : 1.0) : 1.0)
                    .offset(y: active ? (pulseActive ? 3 : -1) : (isAnimating ? 2 : -2))
            }

            VStack(spacing: 4) {
                Text(active ? "Release to Transfer" : "Drop Files Here")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(active ? "Copying to your device" : "to copy to your device")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .background(
            // A subtle dashed drop-target inset that reads against the menu
            // material without competing with it.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(active ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            active ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.4),
                            style: StrokeStyle(lineWidth: active ? 1.5 : 1, dash: active ? [] : [5, 4])
                        )
                )
        )
    }

    // MARK: - Card chrome (matches the native status-bar menu look)

    /// Corner radius tuned to macOS menus.
    private static let cornerRadius: CGFloat = 11

    /// The same translucent material macOS uses for its menus, with a subtle
    /// accent wash on drag-over.
    private var cardBackground: some View {
        ZStack {
            VisualEffectView(material: .menu, blendingMode: .behindWindow)
            if active {
                Color.accentColor.opacity(0.14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: PortalView.cornerRadius, style: .continuous))
    }

    /// A thin hairline border like a menu's edge — accent-tinted on drag-over.
    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: PortalView.cornerRadius, style: .continuous)
            .strokeBorder(active ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12),
                          lineWidth: active ? 1.5 : 0.75)
    }
}

class DragDropOverlayView: NSView {
    weak var model: AppModel?
    var onDragEntered: ((CGPoint) -> Void)?
    var onDragUpdated: ((CGPoint) -> Void)?
    var onDragExited: (() -> Void)?
    var onPerformDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let location = sender.draggingLocation
        let screenPoint = self.window?.convertToScreen(NSRect(origin: location, size: .zero)).origin ?? .zero
        onDragEntered?(screenPoint)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let location = sender.draggingLocation
        let screenPoint = self.window?.convertToScreen(NSRect(origin: location, size: .zero)).origin ?? .zero
        onDragUpdated?(screenPoint)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            onPerformDrop?(urls)
            return true
        }
        return false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let pasteboard = NSPasteboard(name: .drag)
        if pasteboard.types?.contains(.fileURL) == true {
            return self
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        self.superview?.mouseDown(with: event)
    }
}

// MARK: - Drop-target picker rows (styled SwiftUI inside the native menu)

private struct DropPickerHeader: View {
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct DropPickerSectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// A rich row for a drop target: icon, name, subtitle, with a hover highlight.
/// Clicking it fires the owning menu item's action and dismisses the menu.
private struct DropTargetRow: View {
    let icon: String
    let name: String
    let subtitle: String
    weak var item: NSMenuItem?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(hovering ? Color.white : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(hovering ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(hovering ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(hovering ? Color.white : Color.secondary.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.accentColor : Color.clear)
                .padding(.horizontal, 5)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard let item, let action = item.action, let target = item.target else { return }
            // Close the menu, then perform the item's action.
            item.menu?.cancelTracking()
            NSApp.sendAction(action, to: target, from: item)
        }
    }
}

