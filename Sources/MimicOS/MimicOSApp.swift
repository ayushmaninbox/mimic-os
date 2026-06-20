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
                    model.openMainWindowAction = {
                        openWindow(id: "main")
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                    }
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
    private var dragTriggerWindow: DragTriggerWindow?
    private var hideTimer: Timer?
    private let portalDragModel = PortalDragModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func setupStatusItem() {
        guard statusItem == nil else { return }
        
        statusItem = NSStatusBar.system.statusItem(withLength: 48)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "laptopcomputer.and.iphone", accessibilityDescription: "MimicOS")
            
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
        
        // Setup Drag Trigger Window
        let triggerView = DragTriggerView(frame: .zero)
        triggerView.appDelegate = self
        let triggerWindow = DragTriggerWindow(contentView: triggerView)
        self.dragTriggerWindow = triggerWindow
        updateDragTriggerWindowFrame()
        triggerWindow.orderFront(nil)
        
        // Timer to align the trigger window horizontally as status items shift
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateDragTriggerWindowFrame()
            }
        }
        
        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    private func updateDragTriggerWindowFrame() {
        guard let button = statusItem?.button, let window = button.window else { return }
        let buttonFrame = window.frame
        let width: CGFloat = 160
        let height: CGFloat = 80
        let x = buttonFrame.midX - width / 2
        let y = buttonFrame.midY - height / 2
        
        dragTriggerWindow?.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
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

    // MARK: - Portal Window Management
    
    func showPortal(at screenPoint: CGPoint) {
        hideTimer?.invalidate()
        hideTimer = nil
        
        if portalPanel == nil {
            let hostingView = NSHostingView(rootView: PortalView(dragModel: portalDragModel, destinationProvider: { [weak self] in
                self?.model?.settings.phoneDestFolder ?? "Downloads/MimicOS"
            }))
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
        let portalWidth: CGFloat = 260
        let portalHeight: CGFloat = 190
        let x = buttonFrame.midX - portalWidth / 2
        let y = buttonFrame.minY - portalHeight - 4
        
        portalPanel?.setFrame(NSRect(x: x, y: y, width: portalWidth, height: portalHeight), display: true)
        portalPanel?.orderFront(nil)
    }
    
    func updatePortal(at screenPoint: CGPoint) {
        portalPanel?.orderFront(nil)
    }
    
    func hidePortalWithDelay() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor in
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
        
        // Open the app main window
        model.openMainWindowAction?()
        
        // Start transfer
        let paths = urls.map { $0.path }
        Task {
            await model.transferFilesFromDragDrop(paths)
        }
    }

    // MARK: - NSMenuDelegate
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model = model else { return }

        if let device = model.selectedDevice, device.state.isUsable {
            let titleItem = NSMenuItem(title: device.displayName, action: nil, keyEquivalent: "")
            titleItem.isEnabled = false
            menu.addItem(titleItem)
            
            menu.addItem(NSMenuItem.separator())
            
            let screenshotItem = NSMenuItem(title: "Take Screenshot", action: #selector(takeScreenshot), keyEquivalent: "")
            screenshotItem.target = self
            menu.addItem(screenshotItem)
            
            let recordingTitle = model.isRecording ? "Stop Recording" : "Record Screen"
            let recordingItem = NSMenuItem(title: recordingTitle, action: #selector(toggleRecording), keyEquivalent: "")
            recordingItem.target = self
            menu.addItem(recordingItem)
            
            let mirroringTitle = model.isMirroring ? "Stop Mirroring" : "Start Mirroring"
            let mirroringItem = NSMenuItem(title: mirroringTitle, action: #selector(toggleMirroring), keyEquivalent: "")
            mirroringItem.target = self
            menu.addItem(mirroringItem)
            
            let sidebarItem = NSMenuItem(title: "Show Control Sidebar", action: #selector(toggleSidebar), keyEquivalent: "")
            sidebarItem.target = self
            sidebarItem.state = model.settings.showSidebar ? .on : .off
            menu.addItem(sidebarItem)
            
            menu.addItem(NSMenuItem.separator())
        } else {
            let noDeviceItem = NSMenuItem(title: "No device connected", action: nil, keyEquivalent: "")
            noDeviceItem.isEnabled = false
            menu.addItem(noDeviceItem)
            
            menu.addItem(NSMenuItem.separator())
        }
        
        let openItem = NSMenuItem(title: "Open MimicOS", action: #selector(openMimicOS), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        
        let runInBackgroundItem = NSMenuItem(title: "Run in Background", action: #selector(toggleRunInBackground), keyEquivalent: "")
        runInBackgroundItem.target = self
        runInBackgroundItem.state = model.settings.runInBackground ? .on : .off
        menu.addItem(runInBackgroundItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit MimicOS", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    // MARK: - Menu Actions
    
    @objc private func takeScreenshot() {
        guard let model = model else { return }
        Task { await model.captureScreenshot() }
    }
    
    @objc private func toggleRecording() {
        guard let model = model else { return }
        Task { await model.toggleScreenRecording() }
    }
    
    @objc private func toggleMirroring() {
        model?.toggleMirror()
    }
    
    @objc private func toggleSidebar() {
        guard let model = model else { return }
        model.setSidebarVisible(!model.settings.showSidebar)
    }
    
    @objc private func openMimicOS() {
        model?.openMainWindowAction?()
    }
    
    @objc private func toggleRunInBackground() {
        guard let model = model else { return }
        model.settings.runInBackground.toggle()
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - Supporting Views and Classes

final class PortalDragModel: ObservableObject {
    @Published var isDraggingOver = false
}

class DragTriggerWindow: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .statusBar
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.contentView = contentView
        self.ignoresMouseEvents = false
    }
}

class DragTriggerView: NSView {
    weak var appDelegate: AppDelegate?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        let pasteboard = NSPasteboard(name: .drag)
        if pasteboard.types?.contains(.fileURL) == true {
            return self
        }
        return nil
    }
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let location = sender.draggingLocation
        let screenPoint = self.window?.convertToScreen(NSRect(origin: location, size: .zero)).origin ?? .zero
        appDelegate?.showPortal(at: screenPoint)
        return .copy
    }
    
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let location = sender.draggingLocation
        let screenPoint = self.window?.convertToScreen(NSRect(origin: location, size: .zero)).origin ?? .zero
        appDelegate?.updatePortal(at: screenPoint)
        return .copy
    }
    
    override func draggingExited(_ sender: NSDraggingInfo?) {
        appDelegate?.hidePortalWithDelay()
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            appDelegate?.handleDrop(urls: urls)
            return true
        }
        return false
    }
}

class PortalPanel: NSPanel {
    var onDragEntered: ((CGPoint) -> Void)?
    var onDragUpdated: ((CGPoint) -> Void)?
    var onDragExited: (() -> Void)?
    var onPerformDrop: (([URL]) -> Void)?

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 190),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .statusBar
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.contentView = contentView
        self.registerForDraggedTypes([.fileURL])
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let location = sender.draggingLocation
        let screenPoint = self.convertToScreen(NSRect(origin: location, size: .zero)).origin
        onDragEntered?(screenPoint)
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let location = sender.draggingLocation
        let screenPoint = self.convertToScreen(NSRect(origin: location, size: .zero)).origin
        onDragUpdated?(screenPoint)
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited?()
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
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
    @ObservedObject var dragModel: PortalDragModel
    var destinationProvider: () -> String
    
    @State private var isAnimating = false
    @State private var pulseActive = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                // Outer glowing circle
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: dragModel.isDraggingOver 
                                ? [.purple, .pink, .orange] 
                                : [.accentColor, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: dragModel.isDraggingOver ? 3 : 2
                    )
                    .frame(width: 58, height: 58)
                    .scaleEffect(dragModel.isDraggingOver ? (pulseActive ? 1.15 : 1.05) : (isAnimating ? 1.12 : 1.0))
                    .opacity(dragModel.isDraggingOver ? 0.9 : (isAnimating ? 0.4 : 0.8))
                
                // Inner circle background
                Circle()
                    .fill(
                        dragModel.isDraggingOver 
                            ? Color.purple.opacity(0.2) 
                            : Color.accentColor.opacity(0.12)
                    )
                    .frame(width: 48, height: 48)
                
                Image(systemName: dragModel.isDraggingOver ? "arrow.down.circle.fill" : "square.and.arrow.down.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: dragModel.isDraggingOver 
                                ? [.purple, .pink] 
                                : [.accentColor, .purple],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .scaleEffect(dragModel.isDraggingOver ? 1.1 : 1.0)
                    .offset(y: dragModel.isDraggingOver ? (pulseActive ? 2 : -1) : (isAnimating ? 2 : -2))
            }
            .padding(.top, 4)
            
            VStack(spacing: 6) {
                Text(dragModel.isDraggingOver ? "Drop to Transfer!" : "Drop Files Here")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        dragModel.isDraggingOver 
                            ? AnyShapeStyle(LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing))
                            : AnyShapeStyle(Color.primary)
                    )
                
                Text(dragModel.isDraggingOver ? "Release to start copy" : "to copy directly to your phone")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Divider()
                .opacity(0.3)
                .padding(.horizontal, 10)
            
            // Destination path indicator
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(destinationProvider())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(6)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(
                    LinearGradient(
                        colors: dragModel.isDraggingOver
                            ? [.purple, .pink, .orange]
                            : [.white.opacity(0.35), .clear, .white.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: dragModel.isDraggingOver ? 2.5 : 1.5
                )
        )
        .shadow(
            color: dragModel.isDraggingOver 
                ? Color.purple.opacity(0.35) 
                : Color.black.opacity(0.25),
            radius: dragModel.isDraggingOver ? 22 : 15,
            x: 0,
            y: 8
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
        .onChange(of: dragModel.isDraggingOver) { _, newValue in
            if newValue {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    pulseActive = true
                }
            } else {
                pulseActive = false
            }
        }
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

    override func mouseDown(with event: NSEvent) {
        self.superview?.mouseDown(with: event)
    }
}
