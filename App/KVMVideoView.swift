import AppKit
import JetKVMProtocol
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

    // MARK: - First responder + coordinate system

    override var acceptsFirstResponder: Bool { true }

    /// Use top-left origin so view-local coordinates match what the
    /// host expects (0..32767 normalized with 0,0 in the top-left).
    /// Without this, NSEvent.locationInWindow → view-local would have
    /// bottom-left origin and we'd have to flip Y manually.
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        // Required for mouseMoved delivery. Without this NSWindow only
        // dispatches mouse-button events, not bare-cursor motion.
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

    // MARK: - Mouse events

    override func mouseMoved(with event: NSEvent) { sendPointer(event: event, motion: true) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event: event, motion: true) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event: event, motion: true) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event: event, motion: true) }

    override func mouseDown(with event: NSEvent) { sendPointer(event: event, motion: false) }
    override func mouseUp(with event: NSEvent) { sendPointer(event: event, motion: false) }
    override func rightMouseDown(with event: NSEvent) { sendPointer(event: event, motion: false) }
    override func rightMouseUp(with event: NSEvent) { sendPointer(event: event, motion: false) }
    override func otherMouseDown(with event: NSEvent) { sendPointer(event: event, motion: false) }
    override func otherMouseUp(with event: NSEvent) { sendPointer(event: event, motion: false) }

    private func sendPointer(event: NSEvent, motion: Bool) {
        guard let session else { return }
        guard let coords = normalizedCoords(event: event) else { return }
        // NSEvent.pressedMouseButtons is a class property giving the
        // global currently-pressed-buttons bitmask. Lower 5 bits map
        // 1:1 to JetKVM's MouseButtons (left/right/middle/back/forward).
        let buttons = MouseButtons(rawValue: UInt8(truncatingIfNeeded: NSEvent.pressedMouseButtons))
        if motion {
            session.sendPointerMotion(normalizedX: coords.x, normalizedY: coords.y, buttons: buttons)
        } else {
            session.sendPointerButtonChange(normalizedX: coords.x, normalizedY: coords.y, buttons: buttons)
        }
    }

    /// View-local coordinates → 0..32767 normalized over view bounds.
    /// Returns nil if the view has zero area (rare; defensive).
    private func normalizedCoords(event: NSEvent) -> (x: Int32, y: Int32)? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        // Clamp — NSEvent can deliver mouseMoved with the cursor a hair
        // outside the view bounds during fast motion.
        let clampedX = max(0, min(bounds.width, local.x))
        let clampedY = max(0, min(bounds.height, local.y))
        let nx = Int32(clampedX / bounds.width * 32767)
        let ny = Int32(clampedY / bounds.height * 32767)
        return (nx, ny)
    }
}
