import AppKit
import JetKVMTransport
import WebRTC

/// `NSView` that hosts an `RTCMTLNSVideoView` for rendering a JetKVM video
/// track and captures keyboard/mouse events for forwarding to the host.
///
/// The Metal view does the heavy lifting (VideoToolbox-backed hardware
/// decode, Metal rendering); we keep first-responder + event handling on
/// this parent view so input lands in code we control.
final class KVMVideoView: NSView {
    private var rtcView: RTCMTLNSVideoView?
    private weak var currentTrack: RTCVideoTrack?
    private weak var session: Session?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KVMVideoView is created in code only")
    }

    /// Wire up the session this view forwards input to. Held weakly so
    /// the SwiftUI-owned `Session` lifetime drives release.
    func setSession(_ session: Session?) {
        self.session = session
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

    // MARK: - First responder

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Become first responder so keyDown/keyUp/flagsChanged events
        // arrive here. mouseMoved delivery requires the window opt-in
        // (commit 14 will rely on this).
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
    }

    // MARK: - Keyboard events

    override func keyDown(with event: NSEvent) {
        // NSEvent fires keyDown repeatedly on auto-repeat — we forward
        // each one. The host's HID stack handles repeat semantics.
        session?.sendKeypress(virtualKeyCode: event.keyCode, pressed: true)
    }

    override func keyUp(with event: NSEvent) {
        session?.sendKeypress(virtualKeyCode: event.keyCode, pressed: false)
    }

    override func flagsChanged(with event: NSEvent) {
        // Modifier press/release. We use event.keyCode (the specific
        // modifier key that toggled) rather than event.modifierFlags
        // (the combined union) so we can distinguish left vs right.
        session?.handleFlagsChanged(virtualKeyCode: event.keyCode)
    }

    // Suppress the system's "beep on unhandled keys" sound — we forward
    // every key, so to NSResponder there's no such thing as unhandled.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only swallow when we have a session and the key has a
        // mapping; otherwise let it bubble (Cmd+Q etc. should still
        // close the app when input forwarding is off).
        guard session != nil else { return false }
        return false  // CGEventTap "Capture Keyboard" mode in M4 will
                      // be the path that swallows these.
    }
}
