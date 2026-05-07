import AppKit
import JetKVMProtocol
import JetKVMTransport
import OSLog
import WebRTC

private let log = Logger(subsystem: "app.jetkvm.client", category: "kvm-view")

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
    /// Set by the SwiftUI representable when pointer-lock is engaged.
    /// When true, mouse events route through `Session.sendMouseRelative`
    /// (relative deltas, MouseReport opcode 0x06) instead of
    /// `sendPointerMotion` / `sendPointerButtonChange` (absolute,
    /// PointerReport opcode 0x03).
    var pointerLocked: Bool = false

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
        // Drop any prior didBecomeKey observer (we may be moving from
        // one window to another, e.g. SwiftUI re-parenting on
        // representable updates).
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        guard let window else { return }
        window.makeFirstResponder(self)
        // Required for mouseMoved delivery. Without this NSWindow only
        // dispatches mouse-button events, not bare-cursor motion.
        window.acceptsMouseMovedEvents = true
        // viewDidMoveToWindow only fires once when we're added. Without
        // this observer, when a second KVM window opens and steals key
        // status, then the user clicks back to this one, NSWindow's
        // remembered first responder may have been lost and keystrokes
        // would have nowhere to go. Re-establishing on every become-key
        // is cheap insurance.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard let window else { return }
        if window.firstResponder !== self {
            log.debug("window became key — re-establishing first responder")
            window.makeFirstResponder(self)
        }
    }

    /// Make a click in a non-key window both activate the window and
    /// land in our event handlers. Without this, the first click on an
    /// unfocused window is silently consumed by activation, which feels
    /// broken with multiple KVM windows open.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        let buttons = MouseButtons(rawValue: UInt8(truncatingIfNeeded: NSEvent.pressedMouseButtons))

        if pointerLocked {
            // Pointer-lock engaged: send relative deltas via MouseReport
            // (opcode 0x06). Button events (motion=false) become
            // dx=dy=0 + new buttons bitmask so the host registers the
            // press/release at the cursor's pinned position. NSEvent
            // deltaX/Y are floating-point points; clamp to Int8 (-128..127)
            // — typical mouse motion is single digits.
            let dx = Int8(clamping: Int(event.deltaX.rounded()))
            let dy = Int8(clamping: Int(event.deltaY.rounded()))
            session.sendMouseRelative(dx: dx, dy: dy, buttons: buttons)
            return
        }

        // Absolute pointer mode (default).
        //
        // Motion events outside the video rect (letterbox bars,
        // toolbar, anywhere not over the actual host display) drop
        // — otherwise the host cursor walks toward the edge of its
        // screen tracking our cursor's clamped position. Button
        // events always send (clamped) so a drag that starts inside
        // and releases outside still produces a clean release on
        // the host.
        guard let coords = normalizedCoords(event: event, clampOutOfBounds: !motion) else { return }
        if motion {
            session.sendPointerMotion(normalizedX: coords.x, normalizedY: coords.y, buttons: buttons)
        } else {
            session.sendPointerButtonChange(normalizedX: coords.x, normalizedY: coords.y, buttons: buttons)
        }
    }

    /// View-local coordinates → 0..32767 normalized over the actual
    /// rendered video sub-rect.
    ///
    /// - `clampOutOfBounds: false` (motion events): returns nil when
    ///   the cursor is outside the video rect, so the caller can skip
    ///   sending a no-op pointer update.
    /// - `clampOutOfBounds: true` (button events): clamps to the
    ///   nearest edge of the video rect, so we can always emit
    ///   button up/down without leaving the host with a stuck button.
    private func normalizedCoords(event: NSEvent, clampOutOfBounds: Bool) -> (x: Int32, y: Int32)? {
        let videoRect = videoContentRect
        guard videoRect.width > 0, videoRect.height > 0 else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let videoX = local.x - videoRect.minX
        let videoY = local.y - videoRect.minY
        let inVideo = videoX >= 0 && videoX <= videoRect.width
                   && videoY >= 0 && videoY <= videoRect.height
        guard inVideo || clampOutOfBounds else { return nil }
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
