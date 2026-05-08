import AppKit
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
    @State private var ownWindow: NSWindow?
    /// True between this window's didEnterFullScreen and
    /// didExitFullScreen notifications. Drives StatusStrip
    /// suppression and the system-presentation-options hide.
    @State private var isFullscreen = false
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
            if isConnectedOrLater && !isFullscreen {
                StatusStrip()
            }
        }
        .environment(session)
        .navigationTitle(host.displayName)
        .background(WindowAccessor(window: $ownWindow))
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
            // If we exit while still fullscreen (e.g. user closes the
            // window from a fullscreen Space), clear our presentation
            // override so the menu bar / dock come back for the next
            // window.
            if isFullscreen {
                FullscreenPresentationCounter.shared.exit()
                isFullscreen = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didEnterFullScreenNotification)
        ) { note in
            guard let win = note.object as? NSWindow, win === ownWindow else { return }
            isFullscreen = true
            FullscreenPresentationCounter.shared.enter()
            // Suppress the window's toolbar entirely so it doesn't
            // slide back in when the cursor reaches the top of the
            // screen. NSApp.presentationOptions only governs the
            // system menu bar / dock; the window's own title-bar
            // reveal is separate macOS behavior.
            win.toolbar?.isVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didExitFullScreenNotification)
        ) { note in
            guard let win = note.object as? NSWindow, win === ownWindow else { return }
            isFullscreen = false
            FullscreenPresentationCounter.shared.exit()
            win.toolbar?.isVisible = true
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

/// Resolves the NSWindow hosting the SwiftUI view it's attached to,
/// publishing the reference back through a Binding. Used by
/// KVMSessionWindow to scope NSWindow.didEnterFullScreenNotification
/// observers to its OWN window — the notification posts for any
/// app window, but with multiple sessions open we only want to react
/// when our specific window changes fullscreen state.
private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window !== nsView.window {
            DispatchQueue.main.async {
                window = nsView.window
            }
        }
    }
}

/// Reference counts how many KVMSessionWindows are currently in
/// fullscreen so we apply NSApp.presentationOptions exactly once and
/// revert exactly once. NSApp.presentationOptions is process-global —
/// a single set/clear pair would race when two windows fullscreen at
/// the same time (e.g. the second exit clobbering the first's hide).
@MainActor
private final class FullscreenPresentationCounter {
    static let shared = FullscreenPresentationCounter()
    private var refCount = 0

    func enter() {
        refCount += 1
        if refCount == 1 {
            // .hideMenuBar (not .autoHide…) so the menu bar stays
            // hidden even when the cursor reaches the top of the
            // screen — the host's display would otherwise lose its
            // top row every time the user nudged the mouse upward.
            NSApp.presentationOptions = [.hideMenuBar, .hideDock]
        }
    }

    func exit() {
        refCount = max(0, refCount - 1)
        if refCount == 0 {
            NSApp.presentationOptions = []
        }
    }
}
