import SwiftUI
import JetKVMTransport
import WebRTC

struct KVMWindowView: View {
    @Environment(Session.self) private var session
    @State private var capturer = KeyboardCapturer()

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
        ZStack {
            Color.black.ignoresSafeArea()
            if let track = session.videoTrack {
                KVMVideoRepresentable(track: track, session: session)
            } else {
                ProgressView("Waiting for video…")
                    .controlSize(.large)
                    .foregroundStyle(.white)
            }
            // Banner when capture mode is requested but Accessibility
            // permission still needs to be granted.
            if case .awaitingAccessibility = capturer.state {
                VStack {
                    Text("Grant Accessibility permission to capture system shortcuts (Cmd+Tab, Cmd+Space, …), then click Capture again.")
                        .padding(8)
                        .background(.yellow)
                        .foregroundStyle(.black)
                        .cornerRadius(6)
                        .padding()
                    Spacer()
                }
            }
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
        }
        .onDisappear {
            capturer.disable()
        }
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
