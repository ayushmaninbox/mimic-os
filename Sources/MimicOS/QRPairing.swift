import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// Generates the QR code that Android's "Pair device with QR code" screen scans.
///
/// Android encodes wireless-debug pairing as a Wi-Fi-style payload:
///
///     WIFI:T:ADB;S:<service_name>;P:<pairing_code>;;
///
/// where `service_name` is the mDNS instance the Mac advertises for pairing and
/// `pairing_code` is a shared secret. When the phone scans this, it connects to
/// the advertised pairing service and authenticates with the code — no typing.
///
/// NOTE: For the QR path to fully work, MimicOS must *advertise* a matching
/// `_adb-tls-pairing._tcp` service (a small NWListener) so the phone has
/// something to connect to. That advertiser is a follow-up; this type owns the
/// payload + image generation and the `adb pair` fallback for the typed-code
/// flow, which works today.
enum QRPairing {

    /// A freshly generated pairing session: the service name + code that the QR
    /// encodes. Keep this around until the phone has paired.
    struct Session {
        let serviceName: String
        let code: String

        /// The exact string Android's QR scanner expects.
        var payload: String { "WIFI:T:ADB;S:\(serviceName);P:\(code);;" }
    }

    /// Creates a new pairing session.
    ///
    /// The QR flow uses a random alphanumeric *password* (not the 6-digit code
    /// used for typed pairing) and a unique service name. When the phone scans
    /// the QR it starts advertising `_adb-tls-pairing._tcp` under this exact
    /// service name; MimicOS then finds that service via `adb mdns services` and
    /// runs `adb pair <host:port> <password>`, which performs the handshake.
    static func newSession() -> Session {
        let suffix = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let password = randomPassword(length: 12)
        return Session(serviceName: "studio-\(suffix)", code: password)
    }

    /// adb's QR pairing accepts an alphanumeric password; keep it URL/QR-safe.
    private static func randomPassword(length: Int) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    /// Renders the session payload to a crisp QR image for display in SwiftUI.
    static func qrImage(for session: Session, scale: CGFloat = 10) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(session.payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width,
                                                      height: scaled.extent.height))
    }

    /// The typed-code fallback: runs `adb pair host:port code`. This is what the
    /// "Pair device with pairing code" screen on the phone gives you, and it
    /// works without any advertiser on the Mac side.
    static func pairWithCode(hostPort: String, code: String) async -> ProcessResult {
        await ADB.pair(hostPort: hostPort, code: code)
    }
}
