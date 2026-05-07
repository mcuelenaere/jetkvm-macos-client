import SwiftUI
import JetKVMTransport
import WebRTC

struct KVMWindowView: View {
    @Environment(Session.self) private var session
    @State private var capturer = KeyboardCapturer()
    @State private var showControls = false
    @State private var showStats = false

    private var captureToggleBinding: Binding<Bool> {
        Binding(
            get: {
                if case .enabled = capturer.state { return true } else { return false }
            },
            set: { newValue in
                if newValue { capturer.enable() } else { capturer.disable() }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.ignoresSafeArea()
                if let track = session.videoTrack {
                    KVMVideoRepresentable(track: track, session: session)
                } else {
                    ProgressView("Waiting for video…")
                        .controlSize(.large)
                        .foregroundStyle(.white)
                }
                // Stack of top-of-window banners. Most-severe first.
                VStack(spacing: 8) {
                    if case .kicked = session.state {
                        banner(
                            "Another peer connected to this device — your session was taken over.",
                            background: .red,
                            foreground: .white
                        )
                    }
                    if let failsafe = session.failsafe, failsafe.active {
                        banner(
                            "Device is in failsafe mode: \(failsafe.reason)",
                            background: .red,
                            foreground: .white
                        )
                    }
                    if case .awaitingAccessibility = capturer.state {
                        banner(
                            "Grant Accessibility permission to capture system shortcuts (Cmd+Tab, Cmd+Space, …), then click Capture again.",
                            background: .yellow,
                            foreground: .black
                        )
                    }
                    Spacer()
                }
                .padding()
            }
            StatusStrip()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if let device = session.device {
                    Text(device.deviceID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: captureToggleBinding) {
                    Label("Capture", systemImage: "keyboard")
                }
                .toggleStyle(.button)
                .help("Forward Cmd+Tab, Cmd+Space, and other system-grabbed shortcuts to the host. Requires Accessibility permission.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showControls.toggle()
                } label: {
                    Label("Controls", systemImage: "slider.horizontal.3")
                }
                .popover(isPresented: $showControls, arrowEdge: .top) {
                    ControlPanel()
                        .environment(session)
                }
                .disabled(!session.rpcReady)
                .help("Power, codec, and quality controls.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showStats.toggle()
                } label: {
                    Label("Stats", systemImage: "chart.line.uptrend.xyaxis")
                }
                .popover(isPresented: $showStats, arrowEdge: .top) {
                    StatsPanel()
                        .environment(session)
                }
                .help("Live network and video diagnostics.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Disconnect") {
                    Task { await session.disconnect() }
                }
            }
        }
        .onAppear {
            // Wire capturer event handlers into the same Session methods
            // KVMVideoView calls when the tap isn't installed. Same
            // contract: keyCode is the macOS Carbon virtual keycode.
            capturer.onKeyDown = { [session] keyCode in
                session.sendKeypress(virtualKeyCode: keyCode, pressed: true)
            }
            capturer.onKeyUp = { [session] keyCode in
                session.sendKeypress(virtualKeyCode: keyCode, pressed: false)
            }
            capturer.onFlagsChanged = { [session] keyCode in
                session.handleFlagsChanged(virtualKeyCode: keyCode)
            }
            // When capture pauses (focus loss or user toggling off
            // mid-keystroke), release any modifiers the tracker thinks
            // are held on the host. Without this, e.g. a Cmd-down sent
            // before a focus-out and a Cmd-up that the system swallowed
            // would leave the host with a stuck Cmd modifier.
            capturer.onSuspend = { [session] in
                session.releaseAllHeldModifiers()
            }
        }
        .onDisappear {
            capturer.disable()
        }
    }

    /// Top-of-window banner used for kicked / failsafe / accessibility
    /// states. All read better as a pinned strip than a popup, so we
    /// stack them at the top of the video view.
    private func banner(_ text: String, background: Color, foreground: Color) -> some View {
        Text(text)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .foregroundStyle(foreground)
            .cornerRadius(6)
    }
}

private struct KVMVideoRepresentable: NSViewRepresentable {
    let track: RTCVideoTrack
    let session: Session

    func makeNSView(context: Context) -> KVMVideoView {
        let view = KVMVideoView()
        view.setSession(session)
        view.attach(track: track)
        return view
    }

    func updateNSView(_ nsView: KVMVideoView, context: Context) {
        nsView.setSession(session)
        nsView.attach(track: track)
    }

    static func dismantleNSView(_ nsView: KVMVideoView, coordinator: ()) {
        nsView.detach()
    }
}
