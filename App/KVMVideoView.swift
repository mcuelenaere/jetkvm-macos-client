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
///
/// The view tracks the source video frame size via `RTCVideoViewDelegate`
/// so it can compute the aspect-fit content rect (the actual rendered
/// video sub-rect within the view, accounting for letterboxing /
/// pillarboxing) and translate mouse coordinates accordingly. Without
/// this, the host cursor drifts out of sync with the user's cursor over
/// any black-bar regions.
final class KVMVideoView: NSView {
    private var rtcView: RTCMTLNSVideoView?
    private weak var currentTrack: RTCVideoTrack?
    private weak var session: Session?
    private var videoSize: CGSize = .zero

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
        // Become the delegate so didChangeVideoSize fires and we can
        // track the source's aspect ratio for coord translation.
        view.delegate = self
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        return view
    }

    /// The aspect-fit sub-rect of the rendered video within `bounds`.
    /// `RTCMTLNSVideoView` letterboxes/pillarboxes to preserve aspect, so
    /// the actual pixels of the host display occupy this sub-rect, not
    /// the whole view. We use this for mouse-coordinate translation.
    private var videoContentRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let viewAspect = bounds.width / bounds.height
        let videoAspect = videoSize.width / videoSize.height
        if videoAspect > viewAspect {
            // Video is wider than the view: letterbox top + bottom.
            let h = bounds.width / videoAspect
            return CGRect(
                x: 0,
                y: (bounds.height - h) / 2,
                width: bounds.width,
                height: h
            )
        } else {
            // Video is taller than the view: pillarbox left + right.
            let w = bounds.height * videoAspect
            return CGRect(
                x: (bounds.width - w) / 2,
                y: 0,
                width: w,
                height: bounds.height
            )
        }
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

    /// View-local coordinates → 0..32767 normalized over the actual
    /// rendered video sub-rect (so letterboxing doesn't desync the
    /// host cursor). Returns nil if the video rect has zero area
    /// (haven't received a frame yet, or the view collapsed).
    private func normalizedCoords(event: NSEvent) -> (x: Int32, y: Int32)? {
        let videoRect = videoContentRect
        guard videoRect.width > 0, videoRect.height > 0 else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        // Translate to video-rect-local space.
        let videoX = local.x - videoRect.minX
        let videoY = local.y - videoRect.minY
        // Clamp — outside the video rect (in a letterbox bar, or a hair
        // outside view bounds during fast motion) becomes the nearest
        // edge so the host cursor stops at the corresponding edge of
        // the video frame instead of drifting into the bars.
        let clampedX = max(0, min(videoRect.width, videoX))
        let clampedY = max(0, min(videoRect.height, videoY))
        let nx = Int32(clampedX / videoRect.width * 32767)
        let ny = Int32(clampedY / videoRect.height * 32767)
        return (nx, ny)
    }
}

extension KVMVideoView: RTCVideoViewDelegate {
    func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        videoSize = size
    }
}
