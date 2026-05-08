import SwiftUI
import JetKVMTransport

/// Identifier for a KVM session window. Carries the full set of
/// fields needed to connect (display name + endpoint) so the same
/// shape works for both saved and discovered (mDNS) hosts — the
/// session window doesn't need to look anything up.
///
/// Codable conformance refuses to decode: SwiftUI's macOS-14
/// WindowGroup auto-restores prior windows from Codable values, and
/// we'd rather always launch into HostsView. Encoding still works in
/// case SwiftUI persists state during a runtime session.
/// (`restorationBehavior(.disabled)` would express this more
/// directly but it's macOS 15+.)
struct KVMSessionWindowID: Hashable, Codable {
    let displayName: String
    let host: String
    let port: Int
    let useTLS: Bool

    init(saved: SavedHost) {
        self.displayName = saved.displayName
        self.host = saved.host
        self.port = saved.port
        self.useTLS = saved.useTLS
    }

    init(discovered: DiscoveredHost) {
        self.displayName = discovered.instanceName
        self.host = discovered.host
        self.port = discovered.port
        self.useTLS = discovered.useTLS
    }

    init(from decoder: Decoder) throws {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "KVM session windows are intentionally not restored"
        ))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([displayName, host, "\(port)", "\(useTLS)"])
    }
}

@main
struct JetKVMClientApp: App {
    @State private var hostStore = HostStore()
    @State private var discovery = DeviceDiscovery()

    var body: some Scene {
        // Root window: the saved-hosts list. Single instance — the
        // user always returns here to launch sessions.
        WindowGroup("JetKVM", id: "hosts") {
            HostsView()
                .environment(hostStore)
                .environment(discovery)
                .onAppear { discovery.start() }
        }
        .defaultSize(width: 520, height: 420)

        // One window per connected host. Spawned by openWindow(value:)
        // from HostsView with a KVMSessionWindowID. Each window owns
        // its own Session so multiple hosts can be connected at the
        // same time. The window id carries all the connection info
        // it needs — saved hosts and discovered (mDNS) hosts both
        // route through here without HostStore lookup.
        WindowGroup("JetKVM Session", for: KVMSessionWindowID.self) { $sessionID in
            if let id = sessionID {
                KVMSessionWindow(sessionID: id)
                    // 16:9 video at minWidth=800 wants ~525pt of
                    // video height (plus toolbar / status strip).
                    // The previous minHeight=600 floored the shrink-
                    // resize from KVMVideoView and left letterbox
                    // bars. 400 accommodates 16:9 and most 21:9
                    // ultrawide displays without going absurdly
                    // small.
                    .frame(minWidth: 800, minHeight: 400)
            } else {
                // No valid id — typically a window macOS tried to
                // restore from a previous launch (the system "Reopen
                // windows on logon" path), where our Codable wrapper
                // refused to decode. SwiftUI still spawns the window
                // with a nil binding; self-dismiss it so the user
                // doesn't see an empty session window flash.
                OrphanSessionWindowDismisser()
            }
        }
        .defaultSize(width: 1280, height: 800)
    }
}

private struct OrphanSessionWindowDismisser: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .onAppear { dismissWindow() }
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
