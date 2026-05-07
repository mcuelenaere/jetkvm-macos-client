import AppKit
import WebRTC

/// `NSView` that hosts an `RTCMTLNSVideoView` for rendering a JetKVM video
/// track. The Metal view does the heavy lifting (VideoToolbox-backed
/// hardware decode, Metal rendering); this wrapper exists so M2 input
/// handling can be added by overriding `keyDown`/`mouseMoved` etc. without
/// fighting `RTCMTLNSVideoView`'s own first-responder behaviour.
final class KVMVideoView: NSView {
    private var rtcView: RTCMTLNSVideoView?
    private weak var currentTrack: RTCVideoTrack?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KVMVideoView is created in code only")
    }

    /// Attach a remote video track. Replaces any previously attached track.
    func attach(track: RTCVideoTrack) {
        if currentTrack === track { return }
        if let prev = currentTrack, let rtcView {
            prev.remove(rtcView)
        }
        let view = rtcView ?? makeRTCView()
        if rtcView == nil { rtcView = view }
        track.add(view)
        currentTrack = track
    }

    /// Detach any attached track (e.g. when the session disconnects).
    func detach() {
        if let track = currentTrack, let rtcView {
            track.remove(rtcView)
        }
        currentTrack = nil
    }

    private func makeRTCView() -> RTCMTLNSVideoView {
        let view = RTCMTLNSVideoView(frame: bounds)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        return view
    }
}
