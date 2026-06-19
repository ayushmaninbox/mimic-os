import Foundation
import Network
import Observation

/// A phone discovered on the local network via mDNS/Bonjour.
///
/// Android 11+ advertises wireless debugging under two service types:
///   - `_adb-tls-pairing._tcp`  → the device is showing a "Pair with code" screen
///   - `_adb-tls-connect._tcp`  → the device is paired and ready to connect
struct DiscoveredPhone: Identifiable, Hashable {
    let name: String          // mDNS instance name (often "adb-<serial>-<suffix>")
    let kind: Kind
    /// Resolved "host:port", filled in once the endpoint resolves. nil until then.
    var hostPort: String?

    var id: String { name + kind.rawValue }

    enum Kind: String {
        case pairing  = "_adb-tls-pairing._tcp"
        case connect  = "_adb-tls-connect._tcp"
    }
}

/// Listens for wireless-debugging phones on the LAN using `NWBrowser` and keeps
/// an observable, de-duplicated list the UI can render directly.
@MainActor
@Observable
final class BonjourBrowser {
    private(set) var phones: [DiscoveredPhone] = []

    private var browsers: [NWBrowser] = []

    /// Starts browsing for both pairing and connect service types.
    func start() {
        guard browsers.isEmpty else { return }
        browse(.connect)
        browse(.pairing)
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        phones.removeAll()
    }

    /// The first discovered pairing endpoint, resolved to "host:port" — used to
    /// autofill the pairing target so the user only types the 6-digit code.
    var pairingHostPort: String? {
        phones.first { $0.kind == .pairing && $0.hostPort != nil }?.hostPort
    }

    private func browse(_ kind: DiscoveredPhone.Kind) {
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: kind.rawValue, domain: "local.")
        let browser = NWBrowser(for: descriptor, using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.apply(results, kind: kind) }
        }
        browser.start(queue: .main)
        browsers.append(browser)
    }

    /// Reconciles the latest browse results into `phones` for one service kind,
    /// resolving each service to a concrete host:port via a short-lived
    /// `NWConnection` (Bonjour browse results carry the name, not the address).
    private func apply(_ results: Set<NWBrowser.Result>, kind: DiscoveredPhone.Kind) {
        phones.removeAll { $0.kind == kind }

        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            phones.append(DiscoveredPhone(name: name, kind: kind, hostPort: nil))
            resolve(result.endpoint, name: name, kind: kind)
        }
    }

    /// Resolves a Bonjour endpoint to host:port and patches the matching phone.
    private func resolve(_ endpoint: NWEndpoint, name: String, kind: DiscoveredPhone.Kind) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else {
                if case .failed = state { connection.cancel() }
                return
            }
            if let remote = connection.currentPath?.remoteEndpoint,
               case let .hostPort(host, port) = remote {
                let resolved = "\(host):\(port.rawValue)"
                Task { @MainActor in self?.patchHostPort(resolved, name: name, kind: kind) }
            }
            connection.cancel()
        }
        connection.start(queue: .main)
    }

    private func patchHostPort(_ hostPort: String, name: String, kind: DiscoveredPhone.Kind) {
        // NWEndpoint host can carry a "%interface" suffix; strip it for adb.
        let clean = hostPort.split(separator: "%").first.map(String.init) ?? hostPort
        if let index = phones.firstIndex(where: { $0.name == name && $0.kind == kind }) {
            phones[index].hostPort = clean
        }
    }
}
