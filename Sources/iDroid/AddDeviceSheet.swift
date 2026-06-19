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
                case .wireless: WirelessGuideView()
                }
            }
            .padding(24)
        }
        .frame(width: 460)
        .frame(minHeight: 420)
    }

    private var header: some View {
        HStack {
            if step != .choose {
                Button {
                    step = .choose
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Add a device").font(.headline)
            Spacer()
            Button("Done") { dismiss() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

            HStack(spacing: 16) {
                ConnectionCard(
                    title: "USB cable",
                    systemImage: "cable.connector",
                    subtitle: "Plug in. Most reliable, works with the screen off."
                ) { step = .usb }

                ConnectionCard(
                    title: "Wireless",
                    systemImage: "wifi",
                    subtitle: "Scan a QR once. Reconnects automatically after."
                ) { step = .wireless }
            }
        }
    }
}

/// The steps of the Add Device flow. File-level so the chooser subview can bind
/// to it (SwiftUI subviews can't reference a private nested enum across types).
enum AddDeviceStep { case choose, usb, wireless }

private struct ConnectionCard: View {
    let title: String
    let systemImage: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage).font(.system(size: 34))
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .padding(12)
            .background(.quaternary.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
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

// MARK: - Step 2b: wireless guide + QR

private struct WirelessGuideView: View {
    private enum Method: String, CaseIterable, Identifiable {
        case qr = "QR code"
        case code = "Pairing code"
        var id: String { rawValue }
    }
    @State private var method: Method = .qr

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connect wirelessly", systemImage: "wifi").font(.title3).bold()

            GuideStep(number: 1, text: "On the phone, enable it once: **Developer options → Wireless debugging** (turn it ON). Works on the same Wi-Fi *or* when this Mac is joined to the phone's hotspot.")

            Picker("Method", selection: $method) {
                ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch method {
            case .qr:   QRPairView()
            case .code: CodePairView()
            }
            Spacer()
        }
    }
}

// MARK: - QR pairing (phone scans the Mac's QR)

private struct QRPairView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            GuideStep(number: 2, text: "On the phone tap **Pair device with QR code**, then point the camera at this code:")

            ZStack {
                if let session = model.pairingSession,
                   let image = QRPairing.qrImage(for: session) {
                    Image(nsImage: image)
                        .interpolation(.none).resizable()
                        .frame(width: 180, height: 180)
                        .padding(8).background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .opacity(isBusy ? 0.3 : 1)
                } else {
                    ProgressView().frame(width: 180, height: 180)
                }
                phaseOverlay
            }

            phaseLabel
        }
        .onAppear { model.startQRPairing() }
    }

    private var isBusy: Bool {
        if case .pairing = model.qrPhase { return true }
        if case .success = model.qrPhase { return true }
        return false
    }

    @ViewBuilder private var phaseOverlay: some View {
        switch model.qrPhase {
        case .pairing: ProgressView()
        case .success: Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
        default: EmptyView()
        }
    }

    @ViewBuilder private var phaseLabel: some View {
        switch model.qrPhase {
        case .showing:
            Text("Waiting for the phone to scan…").font(.callout).foregroundStyle(.secondary)
        case .pairing:
            Text("Pairing…").font(.callout).foregroundStyle(.secondary)
        case .success:
            Text("Paired! Reconnects automatically from now on.").font(.callout).foregroundStyle(.green)
        case .failed(let why):
            VStack(spacing: 6) {
                Text("Pairing failed").font(.callout).foregroundStyle(.red)
                Text(why).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again") { model.startQRPairing() }
            }
        }
    }
}

// MARK: - Pairing-code entry (typed)

private struct CodePairView: View {
    @Environment(AppModel.self) private var model
    @State private var hostPort = ""
    @State private var code = ""
    @State private var hostWasAutofilled = false

    private var canPair: Bool { !hostPort.isEmpty && code.count >= 6 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideStep(number: 2, text: "On the phone tap **Pair device with pairing code**. It shows an address and a 6-digit code.")

            HStack(spacing: 8) {
                if model.pairingHostPort != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Phone detected — address filled in").font(.caption)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Looking for your phone… (or type the address)").font(.caption).foregroundStyle(.secondary)
                }
            }

            LabeledField(label: "Address", placeholder: "192.168.1.5:37000 (or hotspot 192.168.43.1:…)",
                         text: $hostPort, autofilled: hostWasAutofilled)
            LabeledField(label: "6-digit code", placeholder: "123456", text: $code, autofilled: false)

            HStack {
                Spacer()
                Button {
                    Task { await model.pairAndConnect(hostPort: hostPort, code: code) }
                } label: {
                    Label("Pair & connect", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canPair || model.isWorking)
            }
        }
        .onChange(of: model.pairingHostPort) { _, newValue in
            if let newValue, hostPort.isEmpty { hostPort = newValue; hostWasAutofilled = true }
        }
        .onAppear {
            if hostPort.isEmpty, let discovered = model.pairingHostPort { hostPort = discovered; hostWasAutofilled = true }
        }
    }
}

private struct LabeledField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let autofilled: Bool

    var body: some View {
        HStack {
            Text(label).font(.callout).frame(width: 90, alignment: .leading)
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
            if autofilled {
                Text("auto").font(.caption2).foregroundStyle(.green)
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
