import Foundation
import JetKVMTransport

/// User-saved host entry. Backs the rows in HostsView. The id is
/// stable across restarts — KVMSessionWindow uses it to re-find the
/// host across launches when SwiftUI restores windows.
struct SavedHost: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var useTLS: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String,
        port: Int = 80,
        useTLS: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.useTLS = useTLS
    }

    /// What to show in the list. Falls back to the host string when
    /// the user didn't pick a nickname so empty rows can't slip in.
    var displayName: String {
        name.isEmpty ? host : name
    }

    /// Convenience for handing the host to Session.connect(...).
    var endpoint: DeviceEndpoint {
        DeviceEndpoint(host: host, port: port, useTLS: useTLS)
    }

    /// Round-trippable URL string for the form's URL field. Drops the
    /// port suffix when it's the scheme default (80/443), so a typed
    /// "jetkvm.local" comes back as "http://jetkvm.local" rather than
    /// "http://jetkvm.local:80".
    var urlString: String {
        let scheme = useTLS ? "https" : "http"
        let usingDefaultPort = (useTLS && port == 443) || (!useTLS && port == 80)
        return usingDefaultPort ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }

    /// Parse user input that's either a URL ("https://kvm.local",
    /// "http://kvm.local:8080") or a bare hostname ("kvm.local",
    /// "kvm.local:8080"). Bare hostnames default to http/80.
    /// Returns nil for unparseable / non-http(s) input.
    static func parse(_ raw: String) -> (host: String, port: Int, useTLS: Bool)? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // URL needs a scheme to parse host/port reliably; prepend
        // http:// when the user didn't include one.
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard
            let url = URL(string: withScheme),
            let host = url.host(percentEncoded: false),
            !host.isEmpty,
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return nil }
        let useTLS = scheme == "https"
        let port = url.port ?? (useTLS ? 443 : 80)
        guard port > 0, port < 65_536 else { return nil }
        return (host, port, useTLS)
    }
}
