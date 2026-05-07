import SwiftUI
import JetKVMTransport
import WebRTC

struct KVMWindowView: View {
    @Environment(Session.self) private var session

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let track = session.videoTrack {
                KVMVideoRepresentable(track: track)
            } else {
                ProgressView("Waiting for video…")
                    .controlSize(.large)
                    .foregroundStyle(.white)
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
                Button("Disconnect") {
                    Task { await session.disconnect() }
                }
            }
        }
    }
}

private struct KVMVideoRepresentable: NSViewRepresentable {
    let track: RTCVideoTrack

    func makeNSView(context: Context) -> KVMVideoView {
        let view = KVMVideoView()
        view.attach(track: track)
        return view
    }

    func updateNSView(_ nsView: KVMVideoView, context: Context) {
        nsView.attach(track: track)
    }

    static func dismantleNSView(_ nsView: KVMVideoView, coordinator: ()) {
        nsView.detach()
    }
}
