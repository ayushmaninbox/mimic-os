import Foundation
import AppKit
import SwiftUI

/// A small always-on-top "remote control" strip that stays docked to the side of
/// scrcpy's mirror window and follows it perfectly smoothly — driven by live
/// `AXObserver` callbacks (no polling), so there's no lag. It auto-picks the side
/// (right, or left when there's no room on the right) and can't be dragged.
@MainActor
final class FloatingRemoteController {
    private var panel: NSPanel?
    private weak var model: AppModel?
    private let stripWidth: CGFloat = 56
    private let gap: CGFloat = 6
    private var enabled = true

    /// Position the strip flush to the phone window for the given frame, which is
    /// supplied live by the window tracker. `frame` is top-left-origin screen
    /// coordinates (AX convention). `phoneWindowID` lets us keep the strip in the
    /// same z-layer as the phone window (just above it), instead of floating over
    /// every app.
    func update(for frame: CGRect, phoneWindowID: CGWindowID?) {
        guard enabled, let panel else { return }

        // Convert the AX (top-left) frame to AppKit (bottom-left) coordinates,
        // choosing the screen the phone window is actually on.
        let screen = screenContaining(axFrame: frame) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let screenTop = (NSScreen.screens.first?.frame.height ?? screen.frame.maxY)
        let phoneAppKitY = screenTop - frame.origin.y - frame.height

        let height = min(max(frame.height, 240), 700)
        let y = phoneAppKitY + (frame.height - height) / 2

        // Auto side: prefer the right edge; flip to the left if the strip would
        // run off the screen on the right.
        let rightX = frame.origin.x + frame.width + gap
        let fitsRight = rightX + stripWidth <= screen.frame.maxX
        let x = fitsRight ? rightX : (frame.origin.x - gap - stripWidth)

        panel.setFrame(NSRect(x: x, y: y, width: stripWidth, height: height), display: false)

        // Keep the strip directly above the phone window in the stacking order, so
        // it rises and sinks WITH the phone window instead of floating over other
        // apps. If we don't know the window number yet, just make it visible.
        if let wid = phoneWindowID {
            panel.order(.above, relativeTo: Int(wid))
        } else if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    /// Show the remote and start hosting the controls for `model`.
    func show(model: AppModel) {
        self.model = model
        guard enabled else { return }
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: stripWidth, height: 320),
                styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            // Normal window level so the strip shares the phone window's z-order
            // (it doesn't float above other apps) — we keep it just above the
            // scrcpy window via `order(.above:)` in `update(for:)`.
            panel.level = .normal
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovable = false
            panel.isMovableByWindowBackground = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            // Always on every space so it accompanies the phone window across desktops.
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: RemoteStrip(model: model))
            self.panel = panel
        }
        panel?.orderFront(nil)
    }

    /// Hide the strip (e.g. when the phone window moves to another space).
    func hideTemporarily() {
        if panel?.isVisible == true { panel?.orderOut(nil) }
    }

    /// Fully tear down.
    func hide() {
        panel?.orderOut(nil)
    }

    /// Turn the remote on/off (the user's visibility setting).
    func setEnabled(_ on: Bool) {
        enabled = on
        if !on { panel?.orderOut(nil) }
        else if let model { show(model: model) }
    }

    private func screenContaining(axFrame frame: CGRect) -> NSScreen? {
        // Use the window's center, converted to AppKit coordinates, to find its
        // screen so multi-monitor docking lands on the right display.
        let screenTop = NSScreen.screens.first?.frame.height ?? 0
        let centerAppKit = CGPoint(x: frame.midX, y: screenTop - frame.midY)
        return NSScreen.screens.first { $0.frame.contains(centerAppKit) }
    }
}

// MARK: - SwiftUI content of the floating remote

private struct RemoteStrip: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    RemoteButton(systemName: "arrowtriangle.left.fill", help: "Back") {
                        Task { await model.pressBack() }
                    }
                    RemoteButton(systemName: "house.fill", help: "Home") {
                        Task { await model.pressHome() }
                    }
                    RemoteButton(systemName: "square.on.square", help: "Recent apps") {
                        Task { await model.pressRecents() }
                    }

                    Divider().frame(width: 28)

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

                    Divider().frame(width: 28)

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
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 56)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.18), lineWidth: 1))
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
