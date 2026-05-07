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

    private var endpoint: DeviceEndpoint?
    private var http: HTTPClient?
    private var signaling: SignalingClient?
    private var webrtc: WebRTCFacade?
    private var pumpTasks: [Task<Void, Never>] = []

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

            // 3. Open signaling WS using the same cookie storage so the
            //    authToken we just got rides along on the upgrade request.
            state = .connecting(.signaling)
            let signaling = SignalingClient(
                endpoint: endpoint,
                cookieStorage: http.cookieStorage
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
