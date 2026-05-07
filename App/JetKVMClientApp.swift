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
        case .idle, .awaitingPassword, .failed:
            ConnectView()
        case .connecting(let phase):
            ConnectingView(phase: phase)
        case .connected, .kicked:
            KVMWindowView()
        }
    }
}

struct ConnectingView: View {
    let phase: Session.State.Phase

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(label(for: phase))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func label(for phase: Session.State.Phase) -> String {
        switch phase {
        case .checkingStatus: return "Checking device…"
        case .authenticating: return "Authenticating…"
        case .signaling: return "Opening signaling channel…"
        case .offering: return "Negotiating WebRTC offer…"
        case .awaitingAnswer: return "Waiting for answer…"
        case .iceGathering: return "Establishing connection…"
        }
    }
}
