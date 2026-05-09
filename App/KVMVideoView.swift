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

    /// Cursor used inside `videoContentRect` while video is actually
    /// flowing — a 1×1 fully-transparent image. Avoids the
    /// double-cursor look (our local cursor + the host's cursor
    /// rendered into the video stream). Static so we build it once.
    private static let invisibleCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()

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

    override func scrollWheel(with event: NSEvent) {
        // Match the JetKVM web frontend's clampWheel shape — ±1 per
        // event for typical scroll, delta/100 for fast/accelerated
        // scrolls. Keeping the per-NSEvent emission rate (60+ Hz on
        // trackpad) instead of accumulating into bigger ticks gives
        // the host a steady stream of small wheel reports, which
        // feels smoother end-to-end than fewer/larger ones.
        let yTick = Self.clampWheelDelta(event.scrollingDeltaY)
        let xTick = Self.clampWheelDelta(event.scrollingDeltaX)
        if yTick == 0 && xTick == 0 { return }
        // NSEvent.scrollingDeltaY > 0 = user scrolled up; HID wheel
        // positive = wheel rotated up = page scrolls up. Same sign,
        // no negation needed (unlike the web frontend which negates
        // because browser WheelEvent.deltaY uses the opposite
        // convention).
        session?.sendWheelReport(wheelY: yTick, wheelX: xTick)
    }

    /// Mirror of `useMouse.ts`'s `clampWheel`. Maps an NSEvent /
    /// WheelEvent delta to a small Int8 wheel tick: ±1 for normal
    /// scroll, `delta/100` for very fast (`|delta| >= 100`) scroll.
    private static func clampWheelDelta(_ delta: CGFloat) -> Int8 {
        if delta == 0 { return 0 }
        let scaled: CGFloat
        if abs(delta) >= 100 {
            scaled = delta / 100
        } else {
            scaled = delta > 0 ? 1 : -1
        }
        return Int8(clamping: Int(scaled.rounded()))
    }

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

    /// Hide the cursor only while video is actively flowing — not
    /// while we're staring at the no-signal placeholder, where the
    /// user needs to read text and interact with the card. Also
    /// keeps the cursor visible while the connect-flow overlay
    /// (`ConnectionStatusView`) is up, which can sit over us during
    /// the gap between track attach and the first frame rendering;
    /// AppKit cursor rects are NSView-scoped and the SwiftUI
    /// overlay can't shadow them, so we have to check ourselves.
    private var shouldHideCursorOverVideo: Bool {
        guard currentTrack != nil else { return false }
        guard session?.hasReceivedFirstFrame == true else { return false }
        if let err = session?.videoState?.error, !err.isEmpty { return false }
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard shouldHideCursorOverVideo else { return }
        // Limit the invisible-cursor rect to the actual rendered
        // video sub-rect. Letterbox/pillarbox bands keep the normal
        // cursor so the user can see they're outside the stream.
        let rect = videoContentRect
        if rect.width > 0, rect.height > 0 {
            addCursorRect(rect, cursor: Self.invisibleCursor)
        }
    }

    /// Called from KVMVideoRepresentable.updateNSView when state that
    /// affects shouldHideCursorOverVideo may have changed (track
    /// attached/detached, video error appeared/cleared). AppKit will
    /// re-call resetCursorRects on the next opportunity.
    func refreshCursorRects() {
        window?.invalidateCursorRects(for: self)
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
        // First non-zero size = first frame has actually rendered.
        // Tell Session so the connect-flow overlay can come down.
        if size.width > 0, size.height > 0 {
            session?.markFirstFrameReceived()
        }
        // The invisible-cursor rect is tied to videoContentRect,
        // which depends on videoSize — refresh when size changes.
        defer { window?.invalidateCursorRects(for: self) }
        let previousAspect: CGFloat = (videoSize.height > 0)
            ? videoSize.width / videoSize.height
            : 0
        videoSize = size
        guard size.width > 0, size.height > 0 else { return }
        let newAspect = size.width / size.height
        // Resize the window to match the video aspect on each genuine
        // aspect change — typically the first frame, or a host
        // resolution change mid-session. Matching aspect already
        // (within 1%) means no work needed; this also preserves the
        // user's manual window resize across reconnects when the
        // aspect they picked already fits.
        if abs(newAspect - previousAspect) > 0.01 {
            DispatchQueue.main.async { [weak self] in
                self?.resizeWindowToVideoAspect(newAspect)
            }
        }
    }
}

extension KVMVideoView {
    /// Adjust the host NSWindow so that this view's bounds match
    /// `videoAspect`. We change the height (keeping width) anchored
    /// to the window's top-left, so the title-bar position is stable.
    /// No-op when fullscreen, miniaturized, or the bounds aspect
    /// already matches.
    fileprivate func resizeWindowToVideoAspect(_ videoAspect: CGFloat) {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) { return }
        if window.isMiniaturized { return }
        guard bounds.width > 0, bounds.height > 0 else { return }
        let currentAspect = bounds.width / bounds.height
        if abs(currentAspect - videoAspect) < 0.01 { return }

        // First attempt: keep video-area width, derive height from
        // the target aspect, fold the delta into the window. Window
        // chrome (title bar / toolbar / status strip) stays its own
        // height; we just grow/shrink the video area.
        let chromeWidth = max(window.frame.width - bounds.width, 0)
        let chromeHeight = max(window.frame.height - bounds.height, 0)
        var newBoundsHeight = bounds.width / videoAspect
        var newBoundsWidth = bounds.width
        var newFrame = window.frame
        newFrame.size.height = newBoundsHeight + chromeHeight
        newFrame.size.width = newBoundsWidth + chromeWidth
        // Anchor the top edge: y in macOS is bottom-up, so growing
        // height pushes the bottom-left up to keep the title bar at
        // the same screen y.
        newFrame.origin.y = window.frame.maxY - newFrame.size.height

        // If shrinking would violate the window's minSize, hold the
        // height at the floor and widen instead so the video aspect
        // still lands. Otherwise the floor would just leave us with
        // letterbox bars.
        let minHeight = window.minSize.height
        if minHeight > 0, newFrame.size.height < minHeight {
            newFrame.size.height = minHeight
            newFrame.origin.y = window.frame.maxY - minHeight
            newBoundsHeight = minHeight - chromeHeight
            newBoundsWidth = newBoundsHeight * videoAspect
            newFrame.size.width = max(newBoundsWidth + chromeWidth, window.minSize.width)
        }

        // Clamp to the active screen so we don't end up off-edge or
        // taller/wider than the visible area.
        if let visible = window.screen?.visibleFrame {
            if newFrame.height > visible.height {
                let scale = visible.height / newFrame.height
                newFrame.size.height = visible.height
                newFrame.size.width = newFrame.size.width * scale
            }
            if newFrame.width > visible.width {
                let scale = visible.width / newFrame.width
                newFrame.size.width = visible.width
                newFrame.size.height = newFrame.size.height * scale
            }
            if newFrame.maxY > visible.maxY {
                newFrame.origin.y = visible.maxY - newFrame.height
            }
            if newFrame.minY < visible.minY {
                newFrame.origin.y = visible.minY
            }
            if newFrame.maxX > visible.maxX {
                newFrame.origin.x = visible.maxX - newFrame.width
            }
            if newFrame.minX < visible.minX {
                newFrame.origin.x = visible.minX
            }
        }
        window.setFrame(newFrame, display: true, animate: true)
    }
}
