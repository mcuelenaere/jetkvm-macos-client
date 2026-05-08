import SwiftUI
import JetKVMTransport

/// Identifier for a KVM session window. Wraps the host's UUID so the
/// WindowGroup's `for:` slot is a distinct nominal type rather than a
/// raw UUID — and so we can refuse Codable decoding to opt out of
/// SwiftUI's session-window state restoration on relaunch.
///
/// `restorationBehavior(.disabled)` would express the same intent more
/// directly, but it's macOS 15+. Throwing on decode achieves the same
/// effect on macOS 14: SwiftUI tries to restore the previously-open
/// session windows, fails to deserialize the value, and silently drops
/// them. Encoding works (in case SwiftUI persists during runtime), so
/// in-session window-state behaviors keep functioning.
struct KVMSessionWindowID: Hashable, Codable {
    let hostID: SavedHost.ID

    init(_ hostID: SavedHost.ID) {
        self.hostID = hostID
    }

    init(from decoder: Decoder) throws {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "KVM session windows are intentionally not restored"
        ))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hostID)
    }
}

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
        // from HostsView with a KVMSessionWindowID. Each window owns
        // its own Session so multiple hosts can be connected at the
        // same time.
        WindowGroup("JetKVM Session", for: KVMSessionWindowID.self) { $sessionID in
            Group {
                if let id = sessionID, let host = hostStore.find(id: id.hostID) {
                    KVMSessionWindow(host: host)
                } else {
                    // Restoration failure (intentional) or the host
                    // has been deleted: render an empty placeholder
                    // that the user just closes.
                    Color.clear
                }
            }
            .environment(hostStore)
            // 16:9 video at minWidth=800 wants ~525pt of video height
            // (plus toolbar / status strip). The previous minHeight=600
            // floored the shrink-resize from KVMVideoView and left
            // letterbox bars. 400 accommodates 16:9 and most 21:9
            // ultrawide displays without going absurdly small.
            .frame(minWidth: 800, minHeight: 400)
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
