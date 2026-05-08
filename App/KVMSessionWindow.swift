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
        // VStack(ZStack(KVM + overlay), StatusStrip): the StatusStrip
        // sits BELOW the overlay-stacked region so it remains visible
        // during the ConnectionStatusView "Receiving video stream…"
        // phase. The overlay only covers the video area, not the
        // status bar — gives the user FPS/RTT/etc. as soon as they're
        // available.
        VStack(spacing: 0) {
            ZStack {
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
            if isConnectedOrLater {
                StatusStrip()
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
        case .connected:
            // ICE is up and the track is attached, but actual frames
            // can take hundreds of ms to start rendering. Keep the
            // overlay until the renderer reports a non-zero video
            // size (markFirstFrameReceived); otherwise the user sees
            // a blank black window for a beat.
            return !session.hasReceivedFirstFrame
        case .reconnecting, .kicked:
            return false
        }
    }

    private func connect() async {
        let saved = PasswordVault.load(for: host.host)
        await session.connect(endpoint: host.endpoint, password: saved)
    }
}
