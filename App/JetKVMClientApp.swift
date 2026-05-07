import SwiftUI
import JetKVMTransport

@main
struct JetKVMClientApp: App {
    @State private var session = Session()

    var body: some Scene {
        WindowGroup("JetKVM") {
            RootView()
                .environment(session)
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowResizability(.contentSize)
    }
}

struct RootView: View {
    @Environment(Session.self) private var session

    var body: some View {
        switch session.state {
        case .connected, .kicked, .reconnecting:
            // .reconnecting lives in the KVM window so the user keeps
            // their context (and last-frame video, since teardown nils
            // the track) — falling back to ConnectView mid-session would
            // be a jarring UX whiplash for what's usually a 1-2s blip.
            KVMWindowView()
        default:
            // Keep ConnectView alive across .idle / .connecting / .awaitingPassword /
            // .failed transitions so its @State (host, port, password) survives
            // round-trips through the connect flow. Showing a switch over those
            // sub-states here would tear down the form on every transition.
            ConnectView()
        }
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
