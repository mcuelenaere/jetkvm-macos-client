import SwiftUI
import JetKVMTransport

/// One window per connected host. Owns its own Session so multiple
/// windows for different hosts can coexist. The connection flow runs
/// inline inside the window — ConnectionStatusView until .connected,
/// then crossfade to KVMWindowView.
///
/// On window close (.onDisappear) we tear the session down so the
/// peer connection / signaling WS / cookie state don't leak. The user
/// re-opens by clicking the host again in HostsView.
struct KVMSessionWindow: View {
    let host: SavedHost
    @State private var session = Session()
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ZStack {
            // Always render the KVM view once we've reached .connected
            // so the video track has a stable host across redraws.
            // The status overlay sits on top of it for the brief
            // .connecting / .reconnecting / .failed phases — which
            // matches how a paid RDP client behaves: don't yank the
            // session on a transient blip.
            if isConnectedOrLater {
                KVMWindowView()
            }
            if shouldShowOverlay {
                ConnectionStatusView(
                    host: host,
                    onCancel: { dismissWindow() },
                    onRetry: { Task { await connect() } }
                )
                .transition(.opacity)
            }
        }
        .environment(session)
        .navigationTitle(host.displayName)
        .task {
            // First connection attempt fires on appear. We use .task
            // (not .onAppear) so the connect coroutine is cancelled if
            // the window goes away mid-flight.
            await connect()
        }
        .onDisappear {
            // Session.disconnect is async; fire-and-forget so the
            // window-close path stays synchronous. The session reaches
            // .idle and gets deallocated when this view's @State drops.
            Task { await session.disconnect() }
        }
    }

    private var isConnectedOrLater: Bool {
        switch session.state {
        case .connected, .kicked, .reconnecting:
            return true
        default:
            return false
        }
    }

    private var shouldShowOverlay: Bool {
        // Overlay appears for everything except the steady "we have
        // video and the user is operating the host" state. .kicked
        // and .reconnecting render their own banner inside
        // KVMWindowView, so we suppress the overlay for those.
        switch session.state {
        case .idle, .connecting, .awaitingPassword, .failed:
            return true
        case .connected, .reconnecting, .kicked:
            return false
        }
    }

    private func connect() async {
        let saved = PasswordVault.load(for: host.host)
        await session.connect(endpoint: host.endpoint, password: saved)
    }
}
