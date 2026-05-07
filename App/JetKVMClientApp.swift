import SwiftUI
import JetKVMTransport

@main
struct JetKVMClientApp: App {
    @State private var hostStore = HostStore()

    var body: some Scene {
        // Root window: the saved-hosts list. Single instance — the
        // user always returns here to launch sessions.
        WindowGroup("JetKVM", id: "hosts") {
            HostsView()
                .environment(hostStore)
        }
        .defaultSize(width: 520, height: 420)

        // One window per connected host. Spawned by openWindow(value:)
        // from HostsView with a SavedHost.id. Each window owns its own
        // Session so multiple hosts can be connected at the same time.
        WindowGroup("JetKVM Session", for: SavedHost.ID.self) { $hostID in
            Group {
                if let id = hostID, let host = hostStore.find(id: id) {
                    KVMSessionWindow(host: host)
                } else {
                    // Window restored but the host no longer exists
                    // (deleted between launches). Show a small
                    // explainer instead of a blank window.
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("Saved host not found")
                            .font(.headline)
                        Text("Re-add it from the JetKVM window.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .environment(hostStore)
            .frame(minWidth: 800, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 800)
    }
}

extension Session.State.Phase {
    var label: String {
        switch self {
        case .checkingStatus: return "Checking device…"
        case .authenticating: return "Authenticating…"
        case .signaling: return "Opening signaling channel…"
        case .offering: return "Negotiating WebRTC offer…"
        case .awaitingAnswer: return "Waiting for answer…"
        case .iceGathering: return "Establishing connection…"
        }
    }
}
