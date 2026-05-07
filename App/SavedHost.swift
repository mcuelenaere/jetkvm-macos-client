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
}
