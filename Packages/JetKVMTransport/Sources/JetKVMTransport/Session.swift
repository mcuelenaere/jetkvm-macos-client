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

            // 4. Stand up the WebRTC peer connection and pumps.
            let webrtc = WebRTCFacade()
            self.webrtc = webrtc
            startPumps(webrtc: webrtc, signaling: signaling, incoming: incoming)

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

    /// Forward a `flagsChanged` event from the KVM view. Resolves the
    /// transition through `ModifierTracker` and emits a single
    /// `KeypressReport` for the modifier-key USB-HID code (0xE0..0xE7).
    public func handleFlagsChanged(virtualKeyCode keyCode: UInt16) {
        guard hidReady, let webrtc else { return }
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
        incoming: AsyncThrowingStream<SignalingMessage, Error>
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
            state = .connected
        case .failed:
            state = .failed("WebRTC connection failed")
        case .closed:
            // Closure may be initiated by us or by the server (e.g. after
            // otherSessionConnected); we model the latter as `.kicked` once
            // the JSON-RPC channel surfaces that event in M3.
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
        if let webrtc = self.webrtc {
            await webrtc.close()
        }
        if let signaling = self.signaling {
            await signaling.disconnect()
        }
        webrtc = nil
        signaling = nil
        http = nil
        videoTrack = nil
        hidReady = false
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
