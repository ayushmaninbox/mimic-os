import Foundation

/// The remote computer's operating system. Decoupled from the screen-share
/// protocol — e.g. Linux can use RDP (xrdp) or VNC, Windows can use either too.
/// Drives the row icon and the per-OS setup hints in the editor.
enum RemoteOS: String, CaseIterable, Identifiable, Codable {
    case windows
    case linux
    case mac

    var id: String { rawValue }
    var label: String {
        switch self {
        case .windows: return "Windows"
        case .linux:   return "Linux"
        case .mac:     return "Mac"
        }
    }
    var systemImage: String {
        switch self {
        case .windows: return "pc"
        case .linux:   return "terminal"
        case .mac:     return "desktopcomputer"
        }
    }
    /// The protocol most commonly available out of the box for this OS.
    var defaultProtocol: RemoteDesktop.Kind {
        switch self {
        case .windows: return .rdp   // Windows Remote Desktop
        case .linux:   return .vnc   // most Linux desktops ship a VNC server
        case .mac:     return .vnc   // macOS Screen Sharing is VNC
        }
    }
}

/// A saved remote-desktop connection the user can reconnect to with one click.
/// The password is NOT stored here — it lives in the Keychain (`SecretStore`),
/// keyed by `id`. This struct holds only non-secret metadata.
struct RemoteHost: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String                 // friendly label, e.g. "Work PC"
    var host: String                 // hostname or IP
    var port: Int?                   // nil = protocol default
    var username: String
    /// The remote machine's OS. Optional in storage so older saved hosts (which
    /// predate this field) still decode; defaults to Windows when absent.
    var os: RemoteOS = .windows
    var proto: RemoteDesktop.Kind
    var destFolder: String = "~/Downloads/MimicOS"
    var autoReconnect: Bool = true
    var runInBackground: Bool = false
    var rdpCommandAsCtrl: Bool = true
    var redirectClipboard: Bool = true
    /// Turn the remote computer's physical display off while screen sharing, to
    /// save its battery (best effort — Linux: `xset dpms force off`).
    var turnScreenOffWhileSharing: Bool = false

    init(id: UUID = UUID(), name: String, host: String, port: Int? = nil,
         username: String, os: RemoteOS = .windows, proto: RemoteDesktop.Kind,
         destFolder: String = "~/Downloads/MimicOS", autoReconnect: Bool = true, runInBackground: Bool = false,
         rdpCommandAsCtrl: Bool = true, redirectClipboard: Bool = true, turnScreenOffWhileSharing: Bool = false) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.os = os
        self.proto = proto
        self.destFolder = destFolder
        self.autoReconnect = autoReconnect
        self.runInBackground = runInBackground
        self.rdpCommandAsCtrl = rdpCommandAsCtrl
        self.redirectClipboard = redirectClipboard
        self.turnScreenOffWhileSharing = turnScreenOffWhileSharing
    }

    // Custom decoding so hosts saved before `os` existed still load (defaulting
    // to Windows) instead of failing the whole list decode. Any keys from
    // removed fields (e.g. an old `macAddress` / `allowRemoteScreenshots`) are
    // ignored.
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, os, proto, destFolder, autoReconnect, runInBackground, rdpCommandAsCtrl, redirectClipboard, turnScreenOffWhileSharing
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        os = try c.decodeIfPresent(RemoteOS.self, forKey: .os) ?? .windows
        proto = try c.decode(RemoteDesktop.Kind.self, forKey: .proto)
        destFolder = try c.decodeIfPresent(String.self, forKey: .destFolder) ?? "~/Downloads/MimicOS"
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        runInBackground = try c.decodeIfPresent(Bool.self, forKey: .runInBackground) ?? false
        rdpCommandAsCtrl = try c.decodeIfPresent(Bool.self, forKey: .rdpCommandAsCtrl) ?? true
        redirectClipboard = try c.decodeIfPresent(Bool.self, forKey: .redirectClipboard) ?? true
        turnScreenOffWhileSharing = try c.decodeIfPresent(Bool.self, forKey: .turnScreenOffWhileSharing) ?? false
    }

    /// What to show as the connection target, e.g. "user@192.168.1.50".
    var subtitle: String {
        let target = port.map { "\(host):\($0)" } ?? host
        return username.isEmpty ? target : "\(username)@\(target)"
    }

    var idString: String { id.uuidString }
}

/// Local, on-Mac persistence for saved remote-desktop hosts. Metadata lives in
/// `UserDefaults`; passwords live in the Keychain via `SecretStore`, keyed by the
/// host's id. Nothing is written to the remote machine.
enum RemoteHostStore {
    private static let key = "MimicOS.remoteHosts"
    private static var defaults: UserDefaults { .standard }

    static func all() -> [RemoteHost] {
        guard let data = defaults.data(forKey: key),
              let hosts = try? JSONDecoder().decode([RemoteHost].self, from: data) else { return [] }
        return hosts
    }

    /// Inserts a new host or replaces an existing one with the same id.
    static func upsert(_ host: RemoteHost) {
        var hosts = all()
        if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[idx] = host
        } else {
            hosts.append(host)
        }
        persist(hosts)
    }

    /// Removes a host and its stored password.
    static func remove(_ host: RemoteHost) {
        persist(all().filter { $0.id != host.id })
        SecretStore.clearRemotePassword(hostID: host.idString)
    }

    private static func persist(_ hosts: [RemoteHost]) {
        if let data = try? JSONEncoder().encode(hosts) {
            defaults.set(data, forKey: key)
        }
    }
}
