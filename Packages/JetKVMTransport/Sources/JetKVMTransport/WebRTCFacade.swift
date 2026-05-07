import Foundation
import JetKVMProtocol
import WebRTC

public enum WebRTCFacadeError: Error, Sendable {
    case peerConnectionCreationFailed
    case offerCreationFailed(String)
    case sessionDescriptionCodecFailure(String)
    case setLocalDescriptionFailed(String)
    case setRemoteDescriptionFailed(String)
    case addIceCandidateFailed(String)
    case alreadyStarted
    case notStarted
}

/// High-level connection state surfaced to the UI / Session actor. Wraps the
/// raw WebRTC states into a smaller vocabulary the rest of the app can
/// reason about.
public enum WebRTCConnectionState: Sendable, Equatable {
    case new
    case connecting
    case connected
    case disconnected
    case failed
    case closed
}

/// Wraps WebRTC.framework's RTCPeerConnection. The rest of the app should
/// not import WebRTC; route all interaction through this facade so version
/// upgrades stay localised (per the plan's risk #2).
///
/// Lifecycle for M1: `start()` creates the peer connection with one
/// recvonly video transceiver, builds an offer SDP and returns its
/// base64-encoded JSON form. The Session actor sends that on the signaling
/// WS, gets back an answer, and calls `setRemoteAnswer(...)`. ICE flows in
/// both directions via `addRemoteIceCandidate(...)` and the
/// `localIceCandidates` stream.
public actor WebRTCFacade {
    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var delegate: PeerDelegate?

    public let localIceCandidates: AsyncStream<IceCandidate>
    public let videoTracks: AsyncStream<RTCVideoTrack>
    public let connectionState: AsyncStream<WebRTCConnectionState>

    private let localIceCandidatesContinuation: AsyncStream<IceCandidate>.Continuation
    private let videoTracksContinuation: AsyncStream<RTCVideoTrack>.Continuation
    private let connectionStateContinuation: AsyncStream<WebRTCConnectionState>.Continuation

    public init() {
        // RTCDefaultVideoEncoderFactory / RTCDefaultVideoDecoderFactory ship
        // hardware-accelerated H.264 + H.265 decoders backed by VideoToolbox
        // on Apple platforms — that's what gets us hardware decode "for free".
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: videoEncoderFactory,
            decoderFactory: videoDecoderFactory
        )

        var iceCont: AsyncStream<IceCandidate>.Continuation!
        self.localIceCandidates = AsyncStream<IceCandidate> { iceCont = $0 }
        self.localIceCandidatesContinuation = iceCont

        var trackCont: AsyncStream<RTCVideoTrack>.Continuation!
        self.videoTracks = AsyncStream<RTCVideoTrack> { trackCont = $0 }
        self.videoTracksContinuation = trackCont

        var stateCont: AsyncStream<WebRTCConnectionState>.Continuation!
        self.connectionState = AsyncStream<WebRTCConnectionState> { stateCont = $0 }
        self.connectionStateContinuation = stateCont
    }

    /// Create the peer connection, add a single recvonly video transceiver,
    /// and produce an offer. Returns the offer in the wire form expected by
    /// the JetKVM signaling protocol: `base64(JSON({type:"offer", sdp:...}))`.
    public func start(iceServers: [String] = []) async throws -> String {
        guard peerConnection == nil else { throw WebRTCFacadeError.alreadyStarted }

        let config = RTCConfiguration()
        config.iceServers = iceServers.isEmpty ? [] : [RTCIceServer(urlStrings: iceServers)]
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )

        let delegate = PeerDelegate(
            iceContinuation: localIceCandidatesContinuation,
            trackContinuation: videoTracksContinuation,
            stateContinuation: connectionStateContinuation
        )
        self.delegate = delegate

        guard let pc = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: delegate
        ) else {
            throw WebRTCFacadeError.peerConnectionCreationFailed
        }
        self.peerConnection = pc

        // Single recvonly video transceiver — server adds its track to it.
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .recvOnly
        _ = pc.addTransceiver(of: .video, init: transceiverInit)

        // Create the offer.
        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveVideo": "true"],
            optionalConstraints: nil
        )
        let offer = try await Self.createOffer(pc: pc, constraints: offerConstraints)

        // Set local description to commit the offer.
        try await Self.setLocalDescription(pc: pc, sdp: offer)

        // Encode for the wire.
        return try Self.encodeSessionDescription(offer)
    }

    /// Apply the answer received from the server. The wire format is
    /// `base64(JSON({type:"answer", sdp:...}))`, same shape the offer uses.
    public func setRemoteAnswer(sdpBase64: String) async throws {
        guard let pc = peerConnection else { throw WebRTCFacadeError.notStarted }
        let answer = try Self.decodeSessionDescription(sdpBase64)
        try await Self.setRemoteDescription(pc: pc, sdp: answer)
    }

    /// Pass an ICE candidate received from the server into the peer
    /// connection.
    public func addRemoteIceCandidate(_ candidate: IceCandidate) async throws {
        guard let pc = peerConnection else { throw WebRTCFacadeError.notStarted }
        let rtcCandidate = RTCIceCandidate(
            sdp: candidate.candidate,
            sdpMLineIndex: Int32(candidate.sdpMLineIndex ?? 0),
            sdpMid: candidate.sdpMid
        )
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.add(rtcCandidate) { error in
                if let error {
                    cont.resume(throwing: WebRTCFacadeError.addIceCandidateFailed(String(describing: error)))
                } else {
                    cont.resume()
                }
            }
        }
    }

    public func close() async {
        peerConnection?.close()
        peerConnection = nil
        delegate = nil
        localIceCandidatesContinuation.finish()
        videoTracksContinuation.finish()
        connectionStateContinuation.finish()
    }

    // MARK: - SDP wire format

    /// JSON shape pion `webrtc.SessionDescription` serializes to. The
    /// JetKVM server base64-encodes this JSON for transport (`webrtc.go:206-211`).
    private struct SessionDescriptionJSON: Codable {
        let type: String
        let sdp: String
    }

    private static func encodeSessionDescription(_ sdp: RTCSessionDescription) throws -> String {
        let typeString: String
        switch sdp.type {
        case .offer: typeString = "offer"
        case .answer: typeString = "answer"
        case .prAnswer: typeString = "pranswer"
        case .rollback: typeString = "rollback"
        @unknown default:
            throw WebRTCFacadeError.sessionDescriptionCodecFailure("unknown sdp type")
        }
        let json = SessionDescriptionJSON(type: typeString, sdp: sdp.sdp)
        let data = try JSONEncoder().encode(json)
        return data.base64EncodedString()
    }

    private static func decodeSessionDescription(_ base64: String) throws -> RTCSessionDescription {
        guard let data = Data(base64Encoded: base64) else {
            throw WebRTCFacadeError.sessionDescriptionCodecFailure("invalid base64")
        }
        let json = try JSONDecoder().decode(SessionDescriptionJSON.self, from: data)
        let type: RTCSdpType
        switch json.type.lowercased() {
        case "offer": type = .offer
        case "answer": type = .answer
        case "pranswer": type = .prAnswer
        case "rollback": type = .rollback
        default:
            throw WebRTCFacadeError.sessionDescriptionCodecFailure("unknown sdp type: \(json.type)")
        }
        return RTCSessionDescription(type: type, sdp: json.sdp)
    }

    // MARK: - Async wrappers around RTCPeerConnection callbacks

    private static func createOffer(
        pc: RTCPeerConnection,
        constraints: RTCMediaConstraints
    ) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { cont in
            pc.offer(for: constraints) { sdp, error in
                if let error {
                    cont.resume(throwing: WebRTCFacadeError.offerCreationFailed(String(describing: error)))
                } else if let sdp {
                    cont.resume(returning: sdp)
                } else {
                    cont.resume(throwing: WebRTCFacadeError.offerCreationFailed("no sdp and no error"))
                }
            }
        }
    }

    private static func setLocalDescription(
        pc: RTCPeerConnection,
        sdp: RTCSessionDescription
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error {
                    cont.resume(throwing: WebRTCFacadeError.setLocalDescriptionFailed(String(describing: error)))
                } else {
                    cont.resume()
                }
            }
        }
    }

    private static func setRemoteDescription(
        pc: RTCPeerConnection,
        sdp: RTCSessionDescription
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error {
                    cont.resume(throwing: WebRTCFacadeError.setRemoteDescriptionFailed(String(describing: error)))
                } else {
                    cont.resume()
                }
            }
        }
    }
}

/// Bridges RTCPeerConnectionDelegate (called on WebRTC.framework's own
/// queue) to the actor's async streams. The continuations are Sendable and
/// thread-safe; no `await` needed in callbacks.
private final class PeerDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    let iceContinuation: AsyncStream<IceCandidate>.Continuation
    let trackContinuation: AsyncStream<RTCVideoTrack>.Continuation
    let stateContinuation: AsyncStream<WebRTCConnectionState>.Continuation

    init(
        iceContinuation: AsyncStream<IceCandidate>.Continuation,
        trackContinuation: AsyncStream<RTCVideoTrack>.Continuation,
        stateContinuation: AsyncStream<WebRTCConnectionState>.Continuation
    ) {
        self.iceContinuation = iceContinuation
        self.trackContinuation = trackContinuation
        self.stateContinuation = stateContinuation
    }

    // MARK: - Required delegate methods

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        // We don't currently surface signaling state — the offer/answer
        // flow is driven explicitly by the Session actor.
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        // Plan B legacy callback — Unified Plan uses didAdd:rtpReceiver:streams: instead.
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        // Plan B legacy callback.
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        // Renegotiation triggered (e.g. after addTransceiver). For our
        // M1 flow we drive negotiation explicitly so this is informational.
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let mapped: WebRTCConnectionState
        switch newState {
        case .new: mapped = .new
        case .checking, .count: mapped = .connecting
        case .connected, .completed: mapped = .connected
        case .disconnected: mapped = .disconnected
        case .failed: mapped = .failed
        case .closed: mapped = .closed
        @unknown default: mapped = .new
        }
        stateContinuation.yield(mapped)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        // Gathering state isn't surfaced — onLocalIceCandidate carries the data we need.
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let wire = IceCandidate(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: UInt16(max(0, candidate.sdpMLineIndex)),
            usernameFragment: nil
        )
        iceContinuation.yield(wire)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        // Removed candidates not surfaced.
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // Server-initiated data channels aren't expected in the JetKVM
        // protocol — the client opens all channels. Will be revisited in M2.
    }

    // MARK: - Unified Plan callbacks

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCVideoTrack {
            trackContinuation.yield(track)
        }
    }
}
