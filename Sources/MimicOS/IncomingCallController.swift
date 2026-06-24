import AppKit
import SwiftUI

/// Manages a floating, native macOS panel that appears when the phone has an
/// incoming call — even with no mirror running. It shows the caller and offers
/// Answer / Decline / Silence, all driven over adb.
///
/// Audio note: a cellular call's voice path lives in the phone's baseband and is
/// inaccessible to adb/scrcpy, so this panel is control-only. You answer here,
/// then talk on the physical phone (or hear it on the Mac if mirroring is on).
@MainActor
final class IncomingCallController {
    /// Which kind of call the panel is showing — drives the label and which
    /// buttons are offered.
    enum Phase {
        case incoming   // ringing: offer Decline / Silence / Answer
        case outgoing   // dialing out: offer Hang up
        case active     // connected: offer Hang up
    }

    private var panel: NSPanel?
    private var hosting: NSHostingView<CallCard>?

    /// Actions wired up by AppModel.
    var onAnswer: (() -> Void)?
    var onDecline: (() -> Void)?
    var onSilence: (() -> Void)?
    var onIgnore: (() -> Void)?
    var onMute: (() -> Void)?
    /// Hides the panel without affecting the call (the call keeps running on the
    /// phone). Wired to the close (✕) button on an active call.
    var onClose: (() -> Void)?

    /// Current call values, kept so a Silence tap can re-render the same call.
    private var name: String?
    private var number: String?
    private var deviceName = ""
    private var phase: Phase = .incoming
    private var silenced = false
    private var muted = false

    /// Shows (or updates) the panel for a call. `name` is the resolved contact
    /// name (if any), `number` the raw number. `deviceName` labels which phone.
    func show(name: String?, number: String?, deviceName: String, phase: Phase) {
        let phaseChanged = self.phase != phase
        // Reset transient toggles when a new call appears or the phase changes.
        if self.number != number || phaseChanged {
            self.silenced = false
            self.muted = false
        }
        self.name = name
        self.number = number
        self.deviceName = deviceName
        self.phase = phase

        let isNew = panel == nil
        if isNew { buildPanel() }
        applyRootView()
        // Pin to the top-right only when the panel first appears or the call
        // advances to a new phase. Once it's an active call, leave it wherever
        // the user dragged it (don't yank it back every refresh).
        if isNew || phaseChanged { positionTopRight() }
        panel?.orderFrontRegardless()
    }

    /// Marks the ringer as silenced (keeps the panel up so the call can still be
    /// answered or declined).
    func markSilenced() {
        silenced = true
        applyRootView()
    }

    /// Sets the displayed mute state on an active call (synced to the phone's
    /// real mic state by the caller).
    func setMuted(_ on: Bool) {
        muted = on
        applyRootView()
    }

    /// Hides and tears down the panel (call ended, answered, or declined).
    func dismiss() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        hosting = nil
        silenced = false
    }

    /// Builds the SwiftUI card from the current values and pushes it into the
    /// hosting view. Rebuilding the rootView each time guarantees the latest
    /// caller/number/phase always shows (no stale observation).
    private func applyRootView() {
        let card = CallCard(
            title: displayTitle(),
            subtitle: subtitleText(),
            glyph: glyph(for: phase),
            phase: phase,
            silenced: silenced,
            muted: muted,
            answer: { [weak self] in self?.onAnswer?() },
            decline: { [weak self] in self?.onDecline?() },
            silence: { [weak self] in self?.onSilence?() },
            ignore: { [weak self] in self?.onIgnore?() },
            mute: { [weak self] in self?.onMute?() },
            close: { [weak self] in self?.onClose?() }
        )
        hosting?.rootView = card
    }

    private func buildPanel() {
        let placeholder = CallCard(title: "", subtitle: "", glyph: "phone.fill",
                                   phase: .incoming, silenced: false, muted: false,
                                   answer: {}, decline: {}, silence: {},
                                   ignore: {}, mute: {}, close: {})
        let host = NSHostingView(rootView: placeholder)
        // Wide enough for four uniform buttons (Decline/Silence/Ignore/Answer).
        let size = NSSize(width: 380, height: 168)

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        // Let the user drag the panel anywhere by grabbing the card itself
        // (it's borderless, so there's no title bar to drag).
        p.isMovableByWindowBackground = true
        // Show above full-screen apps and on every Space, like an alert.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        hosting = host
        panel = p
    }

    // MARK: - Text helpers

    private func displayTitle() -> String {
        if let n = name, !n.isEmpty { return n }
        if let num = number, !num.isEmpty { return num }
        return phase == .incoming ? "Unknown caller" : "Unknown number"
    }

    private func subtitleText() -> String {
        // The status (what the call is doing) plus the device it's on.
        let status: String
        if silenced {
            status = "Silenced"
        } else {
            switch phase {
            case .incoming: status = "Incoming call"
            case .outgoing: status = "Calling…"
            case .active:   status = "On call"
            }
        }
        // Always surface the raw number on the subtitle line — but only when the
        // title is showing a contact name (otherwise the title is already the
        // number and repeating it is noise).
        if let num = number, !num.isEmpty,
           let n = name, !n.isEmpty {
            return "\(num) · \(status) · \(deviceName)"
        }
        return "\(status) · \(deviceName)"
    }

    private func glyph(for phase: Phase) -> String {
        switch phase {
        case .incoming: return "phone.fill"
        case .outgoing: return "phone.arrow.up.right.fill"
        case .active:   return "phone.connection.fill"
        }
    }

    /// Pins the panel to the top-right of the active screen, just under the menu
    /// bar — the conventional spot for an incoming-call banner.
    private func positionTopRight() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let margin: CGFloat = 16
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.maxX - size.width - margin,
            y: frame.maxY - size.height - margin
        )
        panel.setFrameOrigin(origin)
    }
}

/// The glassy call card shown in the floating panel. Built with plain values
/// (reassigned into the hosting view on each update) so it always reflects the
/// current call — no observation timing to get wrong.
struct CallCard: View {
    let title: String
    let subtitle: String
    let glyph: String
    let phase: IncomingCallController.Phase
    let silenced: Bool
    let muted: Bool
    let answer: () -> Void
    let decline: () -> Void
    let silence: () -> Void
    let ignore: () -> Void
    let mute: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: glyph)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.green)
                    .symbolEffect(.pulse, isActive: phase != .active)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                Spacer()
                // On an active call, let the user dismiss the panel without
                // ending the call — it keeps running on the phone.
                if phase == .active {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 22, height: 22)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide this panel (the call stays active on your phone)")
                }
            }

            HStack(spacing: 10) {
                switch phase {
                case .incoming:
                    CallButton(title: "Decline", system: "phone.down.fill",
                               tint: .red, action: decline)
                    CallButton(title: silenced ? "Silenced" : "Silence",
                               system: "bell.slash.fill",
                               tint: .gray, action: silence)
                        .disabled(silenced)
                    CallButton(title: "Ignore", system: "xmark.circle.fill",
                               tint: .orange, action: ignore)
                    CallButton(title: "Answer", system: "phone.fill",
                               tint: .green, action: answer)
                case .active:
                    CallButton(title: muted ? "Muted" : "Mute",
                               system: muted ? "mic.slash.fill" : "mic.fill",
                               tint: muted ? .orange : .gray, action: mute)
                    CallButton(title: "Hang up", system: "phone.down.fill",
                               tint: .red, action: decline)
                case .outgoing:
                    CallButton(title: "Hang up", system: "phone.down.fill",
                               tint: .red, action: decline)
                }
            }
        }
        .padding(16)
        // Solid dark card so the text is always legible — the panel itself is a
        // transparent borderless window, and a translucent material rendered the
        // text invisible against the desktop.
        .background(Color(red: 0.12, green: 0.12, blue: 0.13),
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}

/// A pill-style action button used on the call card.
private struct CallButton: View {
    let title: String
    let system: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: system)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            // Equal width AND height for every button so the row is uniform.
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}
