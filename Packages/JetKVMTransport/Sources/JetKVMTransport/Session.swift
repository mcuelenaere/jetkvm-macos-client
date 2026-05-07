import Foundation
import JetKVMProtocol
import Observation
import WebRTC

public enum SessionError: Error, Sendable {
    /// `GET /device/status` returned `isSetup: false`. The device hasn't
    /// been provisioned yet — we don't try to push past this; the user
    /// has to go through the setup flow in the web UI first.
    case deviceNotProvisioned
    /// Server sent device-metadata with an empty deviceVersion, indicating
    /// firmware too old for the WS signaling path (per the plan).
    case deviceTooOld
    /// The signaling WS sent something other than device-metadata first.
    case unexpectedFirstMessage(String)
    /// Tried to make an RPC call before the rpc data channel opened.
    case rpcNotReady
    case underlying(Error)
}

/// Orchestrates the connect flow: HTTP auth → signaling WS → WebRTC peer
/// connection. Owns one HTTPClient, SignalingClient, and WebRTCFacade for
/// the lifetime of a connection.
///
/// `@MainActor` so SwiftUI can observe state directly without an extra
/// view-model translation layer. The underlying transports are themselves
/// actors so heavy work doesn't block the main thread.
@MainActor
@Observable
public final class Session {
    public enum State: Equatable {
        case idle
        case connecting(Phase)
        case awaitingPassword(LocalDevice?)
        case connected
        case kicked
        case failed(String)

        public enum Phase: Sendable {
            case checkingStatus
            case authenticating
            case signaling
            case offering
            case awaitingAnswer
            case iceGathering
        }
    }

    public private(set) var state: State = .idle
    public private(set) var deviceMetadata: DeviceMetadata?
    public private(set) var device: LocalDevice?
    public private(set) var videoTrack: RTCVideoTrack?
    /// `true` once the reliable HID-RPC channel is open and the
    /// handshake has been sent. Input handlers should gate on this so
    /// keypress/pointer reports aren't silently dropped server-side
    /// (`hidrpc.go:28`).
    public private(set) var hidReady: Bool = false
    /// `true` once the `rpc` data channel is open. Typed RPC methods
    /// should gate on this so calls don't hang waiting for a
    /// response that can't ride a closed channel.
    public private(set) var rpcReady: Bool = false
    /// The JSON-RPC 2.0 client over the `rpc` data channel. Available
    /// once the connection is up; nil before connect / after disconnect.
    public private(set) var rpc: JSONRPCClient?

    // MARK: - Cached control-plane state
    //
    // Populated on rpc-ready by a one-shot `refreshControlState()`
    // call, and updated optimistically when the user changes a value
    // via setStreamQualityFactor / setVideoCodecPreference. Server-
    // pushed events (M3 commit 18) refresh the time-varying ones
    // (videoState, usbState, atxState).

    public internal(set) var videoState: VideoState?
    public internal(set) var usbState: String?
    public internal(set) var atxState: ATXState?
    public internal(set) var streamQualityFactor: Double?
    public internal(set) var videoCodecPreference: VideoCodecPreference?
    /// Last-received failsafe mode notification. nil when the device
    /// hasn't sent one yet; `.active == true` is the signal that the
    /// device is in failsafe mode and the UI should warn the user.
    public internal(set) var failsafe: FailsafeModeNotification?

    private var endpoint: DeviceEndpoint?
    private var http: HTTPClient?
    private var signaling: SignalingClient?
    private var webrtc: WebRTCFacade?
    private var pumpTasks: [Task<Void, Never>] = []
    private var modifierTracker = ModifierTracker()
    private var pointerThrottler = InputThrottler(interval: .milliseconds(8))

    public init() {}

    // MARK: - Public API

    /// Begin connecting to a device. If the device is in password mode and
    /// no password is supplied (or the supplied one is wrong), the state
    /// transitions to `.awaitingPassword`; the UI is expected to collect a
    /// password and call `connect(...)` again with it.
    public func connect(endpoint: DeviceEndpoint, password: String? = nil) async {
        if case .connecting = state { return }
        await teardown()

        self.endpoint = endpoint
        state = .connecting(.checkingStatus)

        let http = HTTPClient(endpoint: endpoint)
        self.http = http

        do {
            // 1. Public status check.
            let status = try await http.getDeviceStatus()
            guard status.isSetup else {
                state = .failed("Device not provisioned. Open the web UI to set it up first.")
                return
            }

            // 2. Try /device. In noPassword mode this works without auth
            //    (web.go:561-577 lets unauthenticated requests through).
            //    In password mode it 401s and we either log in or stop to
            //    ask the user.
            state = .connecting(.authenticating)
            let device: LocalDevice
            do {
                device = try await http.getDevice()
            } catch HTTPClientError.unauthorized {
                if let password {
                    do {
                        try await http.login(password: password)
                    } catch HTTPClientError.unauthorized(let msg) {
                        state = .awaitingPassword(self.device)
                        _ = msg // keep optional for future UI surfacing
                        return
                    }
                    device = try await http.getDevice()
                } else {
                    state = .awaitingPassword(nil)
                    return
                }
            }
            self.device = device

            // 3. Open signaling WS, replaying the auth cookie HTTPClient
            //    captured from the login response so the upgrade request
            //    carries it.
            state = .connecting(.signaling)
            let signaling = SignalingClient(
                endpoint: endpoint,
                cookieHeader: http.currentCookieHeader
            )
            self.signaling = signaling
            let (metadata, incoming) = try await signaling.connect()
            guard !metadata.deviceVersion.isEmpty else {
                throw SessionError.deviceTooOld
            }
            self.deviceMetadata = metadata

            // 4. Stand up the WebRTC peer connection, the JSON-RPC
            //    client over its rpc channel, and the pumps.
            let webrtc = WebRTCFacade()
            self.webrtc = webrtc
            let rpcClient = JSONRPCClient(send: { [weak webrtc] frame in
                guard let webrtc else { return false }
                return await webrtc.sendRPCFrame(frame)
            })
            self.rpc = rpcClient
            startPumps(webrtc: webrtc, signaling: signaling, incoming: incoming, rpc: rpcClient)

            // 5. Build offer and ship it.
            state = .connecting(.offering)
            let offerSDP = try await webrtc.start()
            try await signaling.send(.offer(sdpBase64: offerSDP))
            state = .connecting(.awaitingAnswer)
        } catch {
            state = .failed(describe(error))
            await teardown()
        }
    }

    public func disconnect() async {
        await teardown()
        state = .idle
    }

    // MARK: - Input

    /// Forward a `keyDown` or `keyUp` event from the KVM view. The
    /// `keyCode` is the macOS Carbon virtual keycode
    /// (`NSEvent.keyCode`); we translate via `KeyMap`.
    /// Drops if the HID channel isn't ready yet, or if the keyCode
    /// isn't in the keymap.
    public func sendKeypress(virtualKeyCode keyCode: UInt16, pressed: Bool) {
        guard hidReady, let webrtc else { return }
        guard let usbHID = KeyMap.virtualKeyToHIDUsageID[keyCode] else { return }
        let message = HIDRPCMessage.keypressReport(key: usbHID, pressed: pressed)
        Task { await webrtc.sendHID(message, on: .reliable) }
    }

    /// Forward a `flagsChanged` event from the KVM view. Two distinct
    /// cases:
    ///
    /// - **Held modifiers** (Shift, Cmd, Option, Control). macOS fires
    ///   `flagsChanged` on press *and* on release, so we let
    ///   `ModifierTracker` toggle its internal state and emit one
    ///   `KeypressReport` per transition with the modifier-key USB-HID
    ///   code (0xE0..0xE7).
    /// - **Caps Lock**. macOS treats it as a toggle and fires
    ///   `flagsChanged` once per physical press, with the new toggle
    ///   state in `modifierFlags`. The host (USB HID) wants a
    ///   momentary press to flip its own CapsLock state, so we emit
    ///   press + release back-to-back. Looking up via `KeyMap`
    ///   (kVK_CapsLock 0x39 → USB HID 0x39).
    public func handleFlagsChanged(virtualKeyCode keyCode: UInt16) {
        guard hidReady, let webrtc else { return }

        if keyCode == 0x39, let usbHID = KeyMap.virtualKeyToHIDUsageID[keyCode] {
            // Caps Lock toggle. macOS hosts apply a debounce/minimum-hold
            // duration to USB-HID Caps Lock (anti-accident, since Sierra),
            // so a back-to-back press+release is rejected as a glitch.
            // Holding for ~200ms clears the threshold on macOS hosts
            // tested without being noticeably laggy. Linux/Windows hosts
            // toggle on the release regardless of duration, so this is
            // safe across hosts.
            let down = HIDRPCMessage.keypressReport(key: usbHID, pressed: true)
            let up = HIDRPCMessage.keypressReport(key: usbHID, pressed: false)
            Task {
                await webrtc.sendHID(down, on: .reliable)
                try? await Task.sleep(for: .milliseconds(200))
                await webrtc.sendHID(up, on: .reliable)
            }
            return
        }

        guard let transition = modifierTracker.handle(modifierKeyCode: keyCode) else { return }
        guard let usbHID = transition.modifier.usbHIDUsageID else { return }
        let message = HIDRPCMessage.keypressReport(key: usbHID, pressed: transition.pressed)
        Task { await webrtc.sendHID(message, on: .reliable) }
    }

    /// Release every modifier the tracker thinks is held on the host
    /// side, then reset the tracker. Call when capture pauses (e.g.
    /// our app lost focus mid-keystroke) so the host doesn't end up
    /// with stuck modifiers we'll never explicitly release.
    public func releaseAllHeldModifiers() {
        guard let webrtc else {
            modifierTracker.reset()
            return
        }
        let allBits: [ModifierBits] = [
            .leftControl, .leftShift, .leftAlt, .leftMeta,
            .rightControl, .rightShift, .rightAlt, .rightMeta,
        ]
        let held = modifierTracker.currentState
        for bit in allBits where held.contains(bit) {
            guard let usbHID = bit.usbHIDUsageID else { continue }
            let message = HIDRPCMessage.keypressReport(key: usbHID, pressed: false)
            if hidReady {
                Task { await webrtc.sendHID(message, on: .reliable) }
            }
        }
        modifierTracker.reset()
    }

    /// Forward continuous mouse motion (mouseMoved / mouseDragged).
    /// Throttled to ~120 Hz at the InputThrottler — under congestion,
    /// dropping a stale absolute position is better than queueing it.
    public func sendPointerMotion(normalizedX: Int32, normalizedY: Int32, buttons: MouseButtons) {
        guard hidReady else { return }
        guard pointerThrottler.shouldEmit() else { return }
        sendPointerReport(x: normalizedX, y: normalizedY, buttons: buttons)
    }

    /// Forward a discrete mouse-button transition (mouseDown / mouseUp
    /// for left/right/middle/back/forward). Bypasses the throttler so
    /// down/up pairs always reach the host even if a motion event was
    /// just throttled out, and resets the throttler so the next motion
    /// event doesn't get dropped immediately after a click.
    public func sendPointerButtonChange(normalizedX: Int32, normalizedY: Int32, buttons: MouseButtons) {
        guard hidReady else { return }
        pointerThrottler.reset()
        sendPointerReport(x: normalizedX, y: normalizedY, buttons: buttons)
    }

    private func sendPointerReport(x: Int32, y: Int32, buttons: MouseButtons) {
        guard let webrtc else { return }
        let message = HIDRPCMessage.pointerReport(x: x, y: y, buttons: buttons.rawValue)
        Task { await webrtc.sendHID(message, on: .unreliableOrdered) }
    }

    // MARK: - Internal pumps

    private func startPumps(
        webrtc: WebRTCFacade,
        signaling: SignalingClient,
        incoming: AsyncThrowingStream<SignalingMessage, Error>,
        rpc: JSONRPCClient
    ) {
        // 1. Server → us: answers and ICE candidates from signaling stream.
        pumpTasks.append(Task { [weak self] in
            do {
                for try await message in incoming {
                    guard let self else { return }
                    switch message {
                    case .answer(let sdpBase64):
                        try await webrtc.setRemoteAnswer(sdpBase64: sdpBase64)
                        await self.transition(.connecting(.iceGathering))
                    case .newIceCandidate(let cand):
                        try await webrtc.addRemoteIceCandidate(cand)
                    case .deviceMetadata, .offer:
                        // Server doesn't normally re-send these.
                        continue
                    }
                }
            } catch {
                await self?.fail(describe(error))
            }
        })

        // 2. Us → server: locally-gathered ICE candidates.
        pumpTasks.append(Task { [weak self] in
            for await candidate in await webrtc.localIceCandidates {
                guard self != nil else { return }
                try? await signaling.send(.newIceCandidate(candidate))
            }
        })

        // 3. Surface remote video tracks to the UI.
        pumpTasks.append(Task { [weak self] in
            for await track in await webrtc.videoTracks {
                guard let self else { return }
                await self.attachVideoTrack(track)
            }
        })

        // 4. Watch ICE connection state; flip to .connected on first success.
        pumpTasks.append(Task { [weak self] in
            for await rtcState in await webrtc.connectionState {
                guard let self else { return }
                await self.handleRTCState(rtcState)
            }
        })

        // 5. Track when the reliable HID channel is open + handshaken.
        pumpTasks.append(Task { @MainActor [weak self] in
            for await ready in await webrtc.hidReadyState {
                self?.hidReady = ready
                if !ready {
                    self?.modifierTracker.reset()
                }
            }
        })

        // 6. Pump rpc text frames into the JSON-RPC client.
        pumpTasks.append(Task {
            for await frame in await webrtc.incomingRPCFrames {
                await rpc.handle(incomingFrame: frame)
            }
        })

        // 7. Track rpc channel open/closed state. On the first transition
        //    to ready, fetch the initial control-plane state so the UI
        //    has something to bind to before any server events arrive.
        pumpTasks.append(Task { @MainActor [weak self] in
            for await ready in await webrtc.rpcReadyState {
                self?.rpcReady = ready
                if ready {
                    await self?.refreshControlState()
                }
            }
        })

        // 8. Server-pushed JSON-RPC notifications. The server fires
        //    these without prompting (`webrtc.go:406-411` etc.) — most
        //    update the cached control-plane state, otherSessionConnected
        //    transitions us to `.kicked`.
        pumpTasks.append(Task { @MainActor [weak self] in
            for await notification in await rpc.notifications {
                self?.handleRPCNotification(notification)
            }
        })
    }

    private func handleRPCNotification(_ n: JSONRPCNotification) {
        // Important: only assign on decode success. `try?` here
        // would clobber existing state with nil on the first
        // payload-shape mismatch.
        switch n.method {
        case "otherSessionConnected":
            // Server sends this just before tearing down our peer
            // connection (cloud.go:477, web.go:261). Show the kicked
            // UI; .closed transitions stop overriding state.kicked
            // (see handleRTCState).
            state = .kicked

        case "videoInputState":
            if let v = try? n.decodeParams(VideoState.self) {
                videoState = v
            }

        case "usbState":
            // Wire shape is a bare JSON string ("configured",
            // "connected", "disconnected", …).
            if let s = try? n.decodeParams(String.self) {
                usbState = s
            }

        case "atxState":
            if let a = try? n.decodeParams(ATXState.self) {
                atxState = a
            }

        case "failsafeMode":
            if let f = try? n.decodeParams(FailsafeModeNotification.self) {
                failsafe = f
            }

        default:
            // Unhandled events (otaState, networkState, dcState,
            // willReboot, keyboardLedState, etc.) — silently ignore
            // for now; surface them when a feature actually needs
            // them.
            break
        }
    }

    private func attachVideoTrack(_ track: RTCVideoTrack) {
        videoTrack = track
    }

    private func transition(_ new: State) {
        state = new
    }

    private func handleRTCState(_ rtcState: WebRTCConnectionState) {
        switch rtcState {
        case .connected:
            // Don't trample .kicked — that takes precedence visually
            // even if the underlying RTC state is technically still
            // connected for the second or so before the server tears
            // us down.
            if state != .kicked { state = .connected }
        case .failed:
            state = .failed("WebRTC connection failed")
        case .closed:
            // Closure may be initiated by us or by the server (e.g. after
            // otherSessionConnected). When we're already .kicked, stay
            // there so the user sees the kicked UI; the connection is
            // gone but the state explains why.
            if case .connected = state {
                state = .idle
            }
        case .disconnected:
            // Transient — WebRTC may recover. Don't change state.
            break
        case .new, .connecting:
            break
        }
    }

    private func fail(_ message: String) async {
        state = .failed(message)
        await teardown()
    }

    private func teardown() async {
        for task in pumpTasks { task.cancel() }
        pumpTasks = []
        if let rpc = self.rpc {
            await rpc.close()
        }
        if let webrtc = self.webrtc {
            await webrtc.close()
        }
        if let signaling = self.signaling {
            await signaling.disconnect()
        }
        rpc = nil
        webrtc = nil
        signaling = nil
        http = nil
        videoTrack = nil
        hidReady = false
        rpcReady = false
        videoState = nil
        usbState = nil
        atxState = nil
        streamQualityFactor = nil
        videoCodecPreference = nil
        failsafe = nil
        modifierTracker.reset()
        pointerThrottler.reset()
    }
}

private func describe(_ error: Error) -> String {
    if let httpError = error as? HTTPClientError {
        return "HTTP: \(httpError)"
    }
    if let signalErr = error as? SignalingError {
        return "Signaling: \(signalErr)"
    }
    if let sessionErr = error as? SessionError {
        return "Session: \(sessionErr)"
    }
    return "\(error)"
}
