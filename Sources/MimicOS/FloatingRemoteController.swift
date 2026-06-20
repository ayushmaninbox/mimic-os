import Foundation
import AppKit
import SwiftUI

/// A small always-on-top "remote control" window that attaches itself to the
/// edge of scrcpy's mirror window and follows it around — including across
/// Mission Control desktops when pinning is on. Hosts a SwiftUI control strip
/// (power / volume / rotate / pin / screenshot / record).
///
/// scrcpy's window belongs to another process, so we can't dock a real toolbar
/// onto it; instead this panel polls the scrcpy window's frame (via the same AX
/// path the pinner uses) and repositions itself flush against its right edge.
@MainActor
final class FloatingRemoteController {
    private var panel: NSPanel?
    private var follower: Task<Void, Never>?
    private weak var model: AppModel?
    private var trackingTitle: String?
    /// User offset (in screen points) from the auto-docked anchor, if they've
    /// dragged the remote. .zero / nil means docked flush to the phone window.
    private var manualOffset: CGSize?

    /// Width of the control strip in points.
    private let stripWidth: CGFloat = 56

    /// Show the remote and start following the scrcpy window titled `title`.
    func show(model: AppModel, trackingTitle title: String, sticky: Bool) {
        self.model = model
        self.trackingTitle = title
        self.manualOffset = nil

        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: stripWidth, height: 320),
                styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = false   // we handle dragging in-view
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            // The remote should not steal key focus from scrcpy.
            panel.becomesKeyOnlyIfNeeded = true

            let content = RemoteStrip(
                model: model,
                onDrag: { [weak self] delta in self?.dragBy(delta) }
            )
            panel.contentView = NSHostingView(rootView: content)
            self.panel = panel
        }

        // The remote always joins all spaces so it's present on whatever desktop
        // the phone window is currently on — it then shows/hides itself based on
        // whether the phone window is visible on the active space.
        panel?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        startFollowing()
    }

    /// Hide and stop following.
    func hide() {
        follower?.cancel()
        follower = nil
        panel?.orderOut(nil)
        trackingTitle = nil
    }

    /// Pin state is handled by the phone window itself; the remote always rides
    /// all spaces, so there's nothing to toggle here. Kept for call-site symmetry.
    func setSticky(_ sticky: Bool) {}

    /// Let the user nudge the remote; once dragged it keeps a manual offset
    /// relative to the auto-docked anchor (so it still follows the phone window).
    private func dragBy(_ delta: CGSize) {
        guard let panel else { return }
        var frame = panel.frame
        frame.origin.x += delta.width
        frame.origin.y -= delta.height   // AppKit y grows upward; drag delta is screen-down
        panel.setFrameOrigin(frame.origin)
        // Record the offset from the current docked anchor.
        var off = manualOffset ?? .zero
        off.width += delta.width
        off.height -= delta.height
        manualOffset = off
    }

    /// Polls scrcpy's window frame and keeps the strip docked to its right edge
    /// (unless the user dragged it elsewhere).
    private func startFollowing() {
        follower?.cancel()
        follower = Task { [weak self] in
            while !Task.isCancelled {
                self?.reposition()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func reposition() {
        guard let panel else { return }

        // The phone window is only AX-visible when it's on the current space. If
        // we can't find it, it's on another desktop — hide the remote so it never
        // strands itself on the wrong space; it reappears when the phone does.
        guard let phoneFrame = model?.scrcpyWindowFrameForRemote() else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        if !panel.isVisible { panel.orderFrontRegardless() }

        // phoneFrame is in AX/top-left coordinates. Convert to AppKit (bottom-left
        // origin) using the primary screen height.
        guard let screen = NSScreen.screens.first else { return }
        let screenHeight = screen.frame.height
        let phoneAppKitY = screenHeight - phoneFrame.origin.y - phoneFrame.height

        // Match the phone window's height (clamped to a sane range) so the full
        // button column is reachable; the strip scrolls if the window is short.
        let height = min(max(phoneFrame.height, 240), 620)
        // Auto-dock anchor: just off the phone window's right edge, vertically
        // centered. The strip then follows the window from this anchor.
        let dockedX = phoneFrame.origin.x + phoneFrame.width + 6
        let dockedY = phoneAppKitY + (phoneFrame.height - height) / 2

        let offset = manualOffset ?? .zero
        panel.setFrame(NSRect(x: dockedX + offset.width,
                              y: dockedY + offset.height,
                              width: stripWidth, height: height),
                       display: true)
    }
}

// MARK: - SwiftUI content of the floating remote

private struct RemoteStrip: View {
    let model: AppModel
    let onDrag: (CGSize) -> Void

    var body: some View {
        VStack(spacing: 6) {
            // Drag handle — shows a move cursor and lets the user reposition the
            // remote freely.
            DragHandle(onDrag: onDrag)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    // Navigation
                    RemoteButton(systemName: "chevron.left", help: "Back") {
                        Task { await model.pressBack() }
                    }
                    RemoteButton(systemName: "house.fill", help: "Home") {
                        Task { await model.pressHome() }
                    }
                    RemoteButton(systemName: "square.on.square", help: "Recent apps") {
                        Task { await model.pressRecents() }
                    }

                    Divider().frame(width: 28)

                    // Hardware
                    RemoteButton(systemName: "power", help: "Power") {
                        Task { await model.togglePower() }
                    }
                    RemoteButton(systemName: "speaker.wave.2.fill", help: "Volume up") {
                        Task { await model.volumeUp() }
                    }
                    RemoteButton(systemName: "speaker.wave.1.fill", help: "Volume down") {
                        Task { await model.volumeDown() }
                    }
                    RemoteButton(systemName: "rotate.right", help: "Rotate") {
                        Task { await model.rotateScreen() }
                    }
                    RemoteButton(systemName: model.flashlightOn ? "flashlight.on.fill" : "flashlight.off.fill",
                                 help: "Flashlight",
                                 tint: model.flashlightOn ? .yellow : nil) {
                        Task { await model.toggleFlashlight() }
                    }
                    RemoteButton(systemName: model.isFinding ? "bell.fill" : "bell.badge",
                                 help: model.isFinding ? "Stop ringing" : "Find device (ring)",
                                 tint: model.isFinding ? .orange : nil) {
                        Task { await model.toggleFindDevice() }
                    }

                    Divider().frame(width: 28)

                    // Window & capture
                    RemoteButton(systemName: model.settings.pinPhoneWindow ? "pin.fill" : "pin",
                                 help: "Pin to all desktops",
                                 tint: model.settings.pinPhoneWindow ? .accentColor : nil) {
                        model.togglePinPhoneWindow()
                    }
                    RemoteButton(systemName: "camera.fill", help: "Screenshot") {
                        Task { await model.captureScreenshot() }
                    }
                    RemoteButton(systemName: model.isRecording ? "stop.circle.fill" : "record.circle",
                                 help: model.isRecording ? "Stop recording" : "Record",
                                 tint: model.isRecording ? .red : nil) {
                        Task { await model.toggleScreenRecording() }
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .frame(width: 56)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.18), lineWidth: 1))
    }
}

private struct DragHandle: View {
    let onDrag: (CGSize) -> Void
    @State private var last: CGSize = .zero
    @State private var hovering = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 40, height: 20)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear)))
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let delta = CGSize(width: value.translation.width - last.width,
                                           height: value.translation.height - last.height)
                        last = value.translation
                        onDrag(delta)
                    }
                    .onEnded { _ in last = .zero }
            )
            .help("Drag to move the remote")
    }
}

private struct RemoteButton: View {
    let systemName: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .frame(width: 38, height: 32)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(hovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear)))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
