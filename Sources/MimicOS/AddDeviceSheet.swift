import SwiftUI

/// The `+` flow: choose a connection type, then follow a guided path.
///
///   Chooser → USB guide      (plug in, one-time debugging toggle, live detect)
///           → Wireless guide  (one-time Wireless-debugging toggle, scan QR once,
///                              auto-reconnects forever after)
struct AddDeviceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var step: AddDeviceStep = .choose

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case .choose:   ChooserView(step: $step)
                case .usb:      USBGuideView()
                case .hotspot:  HotspotGuideView(step: $step)
                }
            }
            .padding(24)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 520)
        .frame(minHeight: 440)
    }

    private var header: some View {
        ZStack {
            // Centered title, independent of the side buttons' widths.
            Text("Add a device").font(.headline)

            HStack {
                if step != .choose {
                    Button {
                        step = .choose
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .foregroundStyle(.tint)
                    }
                    .buttonStyle(.borderless)
                } else {
                    // Reserve symmetric space so the title stays centered.
                    Color.clear.frame(width: 60, height: 1)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Step 1: chooser

private struct ChooserView: View {
    @Binding var step: AddDeviceStep

    var body: some View {
        VStack(spacing: 16) {
            Text("How is your phone connected to this Mac?")
                .font(.title3).bold()
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                ConnectionCard(
                    title: "USB cable",
                    systemImage: "cable.connector",
                    subtitle: "Plug in. Most reliable, works with the screen off."
                ) { step = .usb }

                ConnectionCard(
                    title: "Hotspot",
                    systemImage: "personalhotspot",
                    subtitle: "No Wi-Fi — phone shares its hotspot. Plug in once, then wireless."
                ) { step = .hotspot }
            }
        }
    }
}

/// The steps of the Add Device flow. File-level so the chooser subview can bind
/// to it (SwiftUI subviews can't reference a private nested enum across types).
enum AddDeviceStep { case choose, usb, hotspot }

private struct ConnectionCard: View {
    let title: String
    let systemImage: String
    let subtitle: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 34))
                    .foregroundStyle(isHovering ? Color.accentColor : Color.primary)
                    .scaleEffect(isHovering ? 1.05 : 1.0)
                
                Text(title).font(.headline)
                
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.9)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
            .padding(12)
            .background(isHovering ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.quaternary.opacity(0.3)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovering ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Step 2a: USB guide

private struct USBGuideView: View {
    @Environment(AppModel.self) private var model

    private var detected: Bool { model.usbDeviceCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Connect over USB", systemImage: "cable.connector").font(.title3).bold()

            GuideStep(number: 1, text: "On the phone, enable USB debugging once: **Settings → About phone →** tap **Build number** 7 times, then **Developer options → USB debugging**.")
            GuideStep(number: 2, text: "Plug the phone into this Mac with a USB cable.")
            GuideStep(number: 3, text: "Tap **Allow** on the phone's “Allow USB debugging?” prompt.")

            Divider()

            HStack(spacing: 8) {
                Image(systemName: detected ? "checkmark.circle.fill" : "magnifyingglass")
                    .foregroundStyle(detected ? .green : .secondary)
                Text(detected
                     ? "Detected — your phone is in the sidebar."
                     : "Waiting for a device…")
                    .foregroundStyle(detected ? .primary : .secondary)
                Spacer()
                Button("Re-scan") { Task { await model.refreshDevices() } }
            }
            Spacer()
        }
    }
}

// MARK: - Step 2c: hotspot (USB once -> wireless TCP/IP)

private struct HotspotGuideView: View {
    @Environment(AppModel.self) private var model
    @Binding var step: AddDeviceStep

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connect over hotspot", systemImage: "personalhotspot").font(.title3).bold()

            Text("Use this when you're on mobile data with no Wi-Fi — Android won't let Wireless debugging turn on, so we flip the phone to wireless over USB instead.")
                .font(.caption).foregroundStyle(.secondary)

            GuideStep(number: 1, text: "Turn on the phone's **hotspot** and join it from this Mac (Wi-Fi menu → the phone's network).")
            GuideStep(number: 2, text: "Enable **USB debugging** once (Developer options), then plug the phone in. On the “Allow USB debugging?” prompt, **check “Always allow from this computer”** and tap **Allow** — this stops it disconnecting later.")
            GuideStep(number: 3, text: "Press the button below. When it says connected, you can **unplug the cable** and keep using the phone wirelessly over the hotspot.")

            Divider()
            phaseView

            HStack {
                Button {
                    step = .choose
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
                .buttonStyle(.borderless)

                Spacer()
                Button {
                    Task { await model.goWirelessOverHotspot() }
                } label: {
                    Label("Go wireless over hotspot", systemImage: "personalhotspot.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
            }
            Spacer()
        }
        .onAppear { model.resetHotspotPhase() }
        // Auto-close the sheet shortly after a successful connection and drop
        // the user straight onto the main app page for that device.
        .onChange(of: isConnected) { _, nowConnected in
            if nowConnected {
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    model.showAddDevice = false
                }
            }
        }
    }

    private var isRunning: Bool {
        if case .working = model.hotspotPhase { return true }
        return false
    }

    private var isConnected: Bool {
        if case .connected = model.hotspotPhase { return true }
        return false
    }

    @ViewBuilder private var phaseView: some View {
        switch model.hotspotPhase {
        case .idle:
            Text("Ready when your phone is plugged in.").font(.callout).foregroundStyle(.secondary)
        case .needsUSB:
            Label("No USB device detected — plug the phone in first.", systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
        case .working(let msg):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(msg).font(.callout) }
        case .connected(let hostPort):
            VStack(alignment: .leading, spacing: 4) {
                Label("Connected at \(hostPort)", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
                Text("You can unplug the USB cable now.").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let why):
            VStack(alignment: .leading, spacing: 4) {
                Label("Failed", systemImage: "xmark.circle.fill").font(.callout).foregroundStyle(.red)
                Text(why).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Shared step row

private struct GuideStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption).bold()
                .frame(width: 20, height: 20)
                .background(Circle().fill(.tint))
                .foregroundStyle(.white)
            Text(.init(text)).font(.callout)
            Spacer(minLength: 0)
        }
    }
}
