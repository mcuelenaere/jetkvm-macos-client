import Foundation
import JetKVMProtocol

public enum SignalingError: Error, Sendable {
    /// The first message we received over the WebSocket wasn't `device-metadata`.
    /// The server is required to send it before anything else (`web.go:317`).
    case unexpectedFirstMessage(SignalingMessage)
    /// We got a binary frame; the signaling protocol is text-only.
    case binaryFrameReceived
    /// The remote closed the connection or it dropped.
    case disconnected(String?)
    /// Tried to connect twice on the same client.
    case alreadyConnected
    /// Tried to send before connect succeeded.
    case notConnected
    /// Failed to encode an outgoing message.
    case encoding(String)
    /// Failed to decode an incoming text frame as a SignalingMessage.
    case decoding(payload: String, error: String)
    /// URLSession reported an error during the WS lifecycle.
    case transport(String)
}

/// WebSocket signaling client for the JetKVM device.
///
/// One client per session. Drives the offer/answer/ICE flow per the protocol
/// at `web.go:281-500`. Cookie-based auth is handled by `cookieStorage`,
/// which the caller is expected to share with `HTTPClient` so the
/// `authToken` cookie a prior `login()` set is replayed on the WebSocket
/// handshake.
public actor SignalingClient {
    private let endpoint: DeviceEndpoint
    private let cookieStorage: HTTPCookieStorage
    private let signalingPath: String

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var streamContinuation: AsyncThrowingStream<SignalingMessage, Error>.Continuation?
    private var tlsDelegate: TLSDelegate?

    private let encoder: JSONEncoder = JSONEncoder()
    private let decoder: JSONDecoder = JSONDecoder()

    public init(
        endpoint: DeviceEndpoint,
        cookieStorage: HTTPCookieStorage,
        signalingPath: String = "/webrtc/signaling/client"
    ) {
        self.endpoint = endpoint
        self.cookieStorage = cookieStorage
        self.signalingPath = signalingPath
    }

    /// Open the WebSocket, wait for `device-metadata`, return the metadata
    /// alongside an async stream of all subsequent messages. Cancel the
    /// stream by calling `disconnect()`.
    public func connect() async throws -> (
        DeviceMetadata,
        AsyncThrowingStream<SignalingMessage, Error>
    ) {
        guard task == nil else { throw SignalingError.alreadyConnected }

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = cookieStorage
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        // URLSession applies cookies from the configured storage to the
        // WebSocket upgrade request automatically; that's how the authToken
        // cookie reaches the server here.
        let delegate = TLSDelegate(allowSelfSignedCertificate: endpoint.allowSelfSignedCertificate)
        self.tlsDelegate = delegate
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.session = session

        let url = endpoint.webSocketURL(path: signalingPath)
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        // First message must be device-metadata.
        let firstMessage = try await receiveSingleMessage(task: task)
        guard case .deviceMetadata(let metadata) = firstMessage else {
            throw SignalingError.unexpectedFirstMessage(firstMessage)
        }

        let stream = AsyncThrowingStream<SignalingMessage, Error> { continuation in
            self.streamContinuation = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.cancelReceive() }
            }
        }

        // Start the persistent receive loop. We hold onto the Task so we
        // can cancel it on disconnect.
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task: task)
        }

        return (metadata, stream)
    }

    /// Encode and send a SignalingMessage as a text frame.
    public func send(_ message: SignalingMessage) async throws {
        guard let task else { throw SignalingError.notConnected }
        let data: Data
        do {
            data = try encoder.encode(message)
        } catch {
            throw SignalingError.encoding(String(describing: error))
        }
        guard let str = String(data: data, encoding: .utf8) else {
            throw SignalingError.encoding("UTF-8 encoding failed")
        }
        do {
            try await task.send(.string(str))
        } catch {
            throw SignalingError.transport(String(describing: error))
        }
    }

    public func disconnect() async {
        await cancelReceive()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - Internal

    private func cancelReceive() async {
        receiveTask?.cancel()
        receiveTask = nil
        streamContinuation?.finish()
        streamContinuation = nil
    }

    private func receiveSingleMessage(task: URLSessionWebSocketTask) async throws -> SignalingMessage {
        while true {
            let frame: URLSessionWebSocketTask.Message
            do {
                frame = try await task.receive()
            } catch {
                throw SignalingError.transport(String(describing: error))
            }
            if let msg = try parseFrame(frame) {
                return msg
            }
            // If parseFrame returned nil it was a heartbeat; keep reading.
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            let frame: URLSessionWebSocketTask.Message
            do {
                frame = try await task.receive()
            } catch {
                streamContinuation?.finish(throwing: SignalingError.disconnected(String(describing: error)))
                return
            }
            do {
                if let msg = try parseFrame(frame) {
                    streamContinuation?.yield(msg)
                }
            } catch {
                streamContinuation?.finish(throwing: error)
                return
            }
        }
    }

    /// Returns nil for heartbeat frames ("ping"/"pong") and throws on
    /// malformed input. Returns a SignalingMessage for valid envelopes.
    private func parseFrame(_ frame: URLSessionWebSocketTask.Message) throws -> SignalingMessage? {
        switch frame {
        case .string(let str):
            // The server treats text-frame "ping"/"pong" as a heartbeat
            // (`web.go:432-444`). It echoes a "pong" when it sees a "ping"
            // from us; it does not initiate text-frame pings itself, so we
            // generally won't see these — but tolerate them defensively.
            if str == "ping" || str == "pong" {
                return nil
            }
            guard let data = str.data(using: .utf8) else {
                throw SignalingError.decoding(payload: str, error: "non-UTF-8 text frame")
            }
            do {
                return try decoder.decode(SignalingMessage.self, from: data)
            } catch {
                throw SignalingError.decoding(payload: str, error: String(describing: error))
            }
        case .data:
            throw SignalingError.binaryFrameReceived
        @unknown default:
            return nil
        }
    }
}
