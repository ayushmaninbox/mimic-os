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

    /// Pops up a menu under the status item listing the active devices and PCs, so the
    /// user picks which one receives the dropped files.
    private func presentDropTargetPicker(devices: [Device], computers: [RemoteHost], paths: [String]) {
        let menu = NSMenu()

        let header = NSMenuItem(
            title: paths.count == 1 ? "Send 1 file to…" : "Send \(paths.count) files to…",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if !devices.isEmpty {
            let phoneHeader = NSMenuItem(title: "Phones", action: nil, keyEquivalent: "")
            phoneHeader.isEnabled = false
            menu.addItem(phoneHeader)
            
            for device in devices {
                let item = NSMenuItem(title: device.displayName, action: #selector(dropTargetChosen(_:)), keyEquivalent: "")
                item.target = self
                item.image = NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: "")
                item.representedObject = DropTarget(serial: device.serial, isPC: false, id: nil, paths: paths)
                menu.addItem(item)
            }
        }

        if !computers.isEmpty {
            if !devices.isEmpty {
                menu.addItem(NSMenuItem.separator())
            }
            let pcHeader = NSMenuItem(title: "Computers", action: nil, keyEquivalent: "")
            pcHeader.isEnabled = false
            menu.addItem(pcHeader)
            
            for host in computers {
                let item = NSMenuItem(title: host.name, action: #selector(dropTargetChosen(_:)), keyEquivalent: "")
                item.target = self
                item.image = NSImage(systemSymbolName: host.os.systemImage, accessibilityDescription: "")
                item.representedObject = DropTarget(serial: nil, isPC: true, id: host.id, paths: paths)
                menu.addItem(item)
            }
        }

        // Show the menu anchored to the status item.
        if let button = statusItem?.button {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.height + 4),
                       in: button)
        }
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

    /// Builds the menu's single SwiftUI-hosted item. The hosting view sizes itself
    /// from the SwiftUI content's fitting size (Auto Layout), and AppKit lays the
    /// menu out around it — no manual window-frame juggling, which was the source
    /// of the clipping/jank.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model = model else { return }

        let menuItem = NSMenuItem()
        // `onHeightChanged` is unused now — the hosting view self-sizes.
        let menuBarView = MenuBarView(model: model) { _ in }

        let hostingView = NSHostingView(rootView: menuBarView)
        // Let the hosting view grow/shrink to the SwiftUI content automatically
        // (e.g. when a device row expands). This is the supported self-sizing
        // path on macOS 13+, and AppKit re-lays-out the menu around it — no
        // manual window-frame mutation (which caused the clipping/jank).
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        // Seed a sensible initial frame so the first display isn't zero-sized.
        hostingView.frame = NSRect(x: 0, y: 0, width: 260,
                                   height: max(hostingView.fittingSize.height, 80))

        menuItem.view = hostingView
        menu.addItem(menuItem)
    }

    // MARK: - Menu Actions
    //
    // The menu content is the SwiftUI `MenuBarView`, whose rows call into the
    // model directly. The only AppKit action still needed is the drop-target
    // picker (`dropTargetChosen`, above), which can't be SwiftUI because it's a
    // transient popup menu shown at drop time.
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
            color: Color.black.opacity(active ? 0.34 : 0.28),
            radius: active ? 24 : 16,
            x: 0,
            y: 10
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
                    .foregroundStyle(
                        LinearGradient(colors: monoColors, startPoint: .top, endPoint: .bottom)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                    .scaleEffect(active ? (pulseActive ? 1.12 : 1.0) : 1.0)
                    .offset(y: active ? (pulseActive ? 3 : -1) : (isAnimating ? 2 : -2))
            }

            VStack(spacing: 4) {
                Text(active ? "Release to Transfer" : "Drop Files Here")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 1)

                Text(active ? "Copying straight to your phone" : "to copy directly to your phone")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            // Inner "glass within glass" panel: a faint frosted inset that adds
            // depth without going opaque.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(active ? 0.9 : 0.6)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.white.opacity(active ? 0.1 : 0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(
                            Color.white.opacity(active ? 0.9 : 0.45),
                            style: StrokeStyle(lineWidth: active ? 2 : 1.4, dash: active ? [] : [6, 5])
                        )
                )
        )
    }

    // MARK: - Card chrome

    /// Liquid-glass card surface: a frosted translucent material you can see
    /// through, a faint light tint, a glossy specular highlight across the top,
    /// and a bright rim — the Apple "glassmorphism" look.
    private var cardBackground: some View {
        ZStack {
            // Frosted, blurred backdrop. `.underWindowBackground` reads as light
            // translucent glass rather than the dark slab `.hudWindow` gives.
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)

            // Very light diagonal tint so the glass has body without going
            // opaque — the wallpaper still glows through.
            LinearGradient(
                colors: [
                    Color.white.opacity(active ? 0.22 : 0.16),
                    Color.white.opacity(active ? 0.10 : 0.06)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            // Glossy specular sweep across the upper third — the "wet glass"
            // sheen that catches the light.
            LinearGradient(
                colors: [Color.white.opacity(active ? 0.4 : 0.28), .clear],
                startPoint: .top, endPoint: .center
            )
            .blendMode(.plusLighter)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    /// Two-pass rim: a soft outer stroke plus a bright inner highlight on the
    /// top edge, so light appears to wrap the glass.
    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: active
                        ? [.white.opacity(0.95), .white.opacity(0.4), .white.opacity(0.6)]
                        : [.white.opacity(0.7), .white.opacity(0.15), .white.opacity(0.35)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: active ? 1.6 : 1.2
            )
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

struct HeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct MenuBarView: View {
    let model: AppModel
    let onHeightChanged: (CGFloat) -> Void
    
    @State private var expandedSerials: Set<String> = []
    @State private var expandedPCIDs: Set<UUID> = []
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                let active = model.usableDevices
                let computers = model.remoteHosts
                
                if active.isEmpty && computers.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "cable.connector.slash")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                        Text("No devices connected")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Connect a phone or add a computer in settings")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                } else {
                    // Phones
                    ForEach(active) { device in
                        let isExpanded = expandedSerials.contains(device.serial)
                        let isMirroring = model.mirroringSerials.contains(device.serial)
                        
                        VStack(spacing: 0) {
                            MenuBarRow(
                                title: device.displayName,
                                icon: "iphone",
                                isOnline: true,
                                isExpanded: isExpanded,
                                isMirroring: isMirroring
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if isExpanded {
                                        expandedSerials.remove(device.serial)
                                    } else {
                                        expandedSerials.insert(device.serial)
                                    }
                                }
                            }
                            
                            if isExpanded {
                                VStack(alignment: .leading, spacing: 2) {
                                    MenuBarOptionRow(title: "Take Screenshot", icon: "camera") {
                                        Task {
                                            await model.menuBarScreenshot(serial: device.serial)
                                            dismissMenu()
                                        }
                                    }
                                    
                                    let recording = device.serial == model.selectedSerial && model.isRecording
                                    MenuBarOptionRow(
                                        title: recording ? "Stop Recording" : "Record Screen",
                                        icon: recording ? "stop.circle" : "record.circle"
                                    ) {
                                        Task {
                                            await model.menuBarToggleRecording(serial: device.serial)
                                            dismissMenu()
                                        }
                                    }
                                    
                                    MenuBarOptionRow(
                                        title: isMirroring ? "Stop Mirroring" : "Start Mirroring",
                                        icon: isMirroring ? "stop.circle" : "play.circle"
                                    ) {
                                        Task {
                                            await model.menuBarToggleMirror(serial: device.serial)
                                            dismissMenu()
                                        }
                                    }
                                    
                                    let sidebar = model.settings.showSidebar
                                    MenuBarOptionRow(
                                        title: sidebar ? "Hide Control Sidebar" : "Show Control Sidebar",
                                        icon: "sidebar.right"
                                    ) {
                                        model.setSidebarVisible(!sidebar)
                                        dismissMenu()
                                    }
                                }
                                .padding(.leading, 26)
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    
                    // Computers
                    ForEach(computers) { host in
                        let isConnected = model.connectedRemoteHostID == host.id
                        let reachable = model.hostReachability[host.id] ?? false
                        let isOnline = isConnected || reachable
                        let isExpanded = expandedPCIDs.contains(host.id) && isOnline
                        
                        VStack(spacing: 0) {
                            MenuBarRow(
                                title: host.name,
                                icon: host.os.systemImage,
                                isOnline: isOnline,
                                isExpanded: isExpanded,
                                isConnected: isConnected
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if isExpanded {
                                        expandedPCIDs.remove(host.id)
                                    } else {
                                        expandedPCIDs.insert(host.id)
                                    }
                                }
                            }
                            
                            if isExpanded {
                                VStack(alignment: .leading, spacing: 2) {
                                    MenuBarOptionRow(
                                        title: isConnected ? "Disconnect Screen" : "Start Screen Sharing",
                                        icon: isConnected ? "wifi.slash" : "display"
                                    ) {
                                        if isConnected {
                                            model.disconnectRemoteHost()
                                        } else {
                                            model.selection = .computer(host.id)
                                            model.connectRemoteHost(host)
                                        }
                                        dismissMenu()
                                    }
                                    
                                    MenuBarOptionRow(title: "Open Files in Finder", icon: "folder") {
                                        model.selection = .computer(host.id)
                                        Task {
                                            await model.openFiles(host)
                                            dismissMenu()
                                        }
                                    }
                                    
                                    MenuBarOptionRow(title: "Open SSH Terminal", icon: "terminal") {
                                        model.selection = .computer(host.id)
                                        Task {
                                            await model.openSSH(host)
                                            dismissMenu()
                                        }
                                    }
                                }
                                .padding(.leading, 26)
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            
            Divider()
            
            HStack(spacing: 16) {
                Button {
                    model.openMainWindowAction?()
                    dismissMenu()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "laptopcomputer")
                        Text("Open MimicOS")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Button {
                    model.openSection(.settings)
                    dismissMenu()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")
                
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Quit MimicOS")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.01))
        }
        .frame(width: 260)
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: HeightPreferenceKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(HeightPreferenceKey.self) { newHeight in
            onHeightChanged(newHeight)
        }
    }
    
    private func dismissMenu() {
        NSApp.sendAction(#selector(NSMenu.cancelTracking), to: nil, from: nil)
    }
}

struct MenuBarOptionRow: View {
    let title: String
    let icon: String
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.9))
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover in
            isHovered = hover
        }
    }
}

struct MenuBarRow: View {
    let title: String
    let icon: String
    let isOnline: Bool
    let isExpanded: Bool
    var isMirroring: Bool = false
    var isConnected: Bool = false
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isMirroring || isConnected ? .green : (isOnline ? .primary : .secondary))
                    .frame(width: 18)
                
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(isOnline ? .primary : .secondary)
                
                Spacer()
                
                if isOnline {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary.opacity(0.7))
                } else {
                    Text("Offline")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered && isOnline ? Color.primary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isOnline)
        .onHover { hover in
            if isOnline {
                isHovered = hover
            }
        }
    }
}
