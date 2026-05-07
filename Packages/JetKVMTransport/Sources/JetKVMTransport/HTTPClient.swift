import Foundation
import JetKVMProtocol

/// HTTP errors surfaced by `HTTPClient`. The login endpoint distinguishes
/// 400 (noPassword mode), 401 (bad password), and 429 (rate-limited);
/// callers want to react differently to each, so we model them explicitly.
public enum HTTPClientError: Error, Sendable, Equatable {
    case unauthorized(message: String?)
    case badRequest(message: String?)
    case rateLimited(retryAfter: Int)
    case notFound
    case server(statusCode: Int, message: String?)
    case invalidResponse
    case decoding(String)
    case transport(String)
}

/// HTTP client for JetKVM's REST endpoints.
///
/// One client per device. Owns its own `HTTPCookieStorage` so multiple
/// connections to different devices don't share auth cookies, and so the
/// cookie storage outlives the URLSession (we want the `authToken` cookie
/// available to the signaling WebSocket too).
public final class HTTPClient: @unchecked Sendable {
    public let endpoint: DeviceEndpoint
    public let cookieStorage: HTTPCookieStorage
    public let urlSession: URLSession

    private let encoder: JSONEncoder = JSONEncoder()
    private let decoder: JSONDecoder = JSONDecoder()

    public init(endpoint: DeviceEndpoint) {
        self.endpoint = endpoint
        // Per-instance cookie storage. Using `.shared` would leak auth across
        // connections to different devices.
        self.cookieStorage = HTTPCookieStorage()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = cookieStorage
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Endpoints

    /// `GET /device/status` — public endpoint, returns whether the device
    /// has been provisioned at all (`web.go:810-827`).
    public func getDeviceStatus() async throws -> DeviceStatus {
        try await get("/device/status")
    }

    /// `GET /device` — protected. In `noPassword` mode the protected
    /// middleware lets unauthenticated requests through (`web.go:561-577`)
    /// so this also acts as our way to read `authMode` without a cookie.
    /// Throws `.unauthorized` if password mode is on and we have no valid
    /// cookie yet.
    public func getDevice() async throws -> LocalDevice {
        try await get("/device")
    }

    /// `POST /auth/login-local` — public. On success the server's
    /// `Set-Cookie: authToken=<uuid>` is captured by `cookieStorage` and
    /// will be replayed automatically on subsequent requests AND on the
    /// signaling WebSocket handshake (URLSession applies cookies to WS
    /// upgrades when both share a `URLSessionConfiguration.httpCookieStorage`).
    public func login(password: String) async throws {
        try await postExpectingNoBody("/auth/login-local", body: LoginRequest(password: password))
    }

    // MARK: - Internal request plumbing

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = endpoint.httpURL(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await perform(req)
    }

    private func postExpectingNoBody(_ path: String, body: some Encodable) async throws {
        let url = endpoint.httpURL(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try encoder.encode(body)
        _ = try await performRaw(req)
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await performRaw(request)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw HTTPClientError.decoding(String(describing: error))
        }
    }

    private func performRaw(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw HTTPClientError.transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapError(statusCode: http.statusCode, headers: http.allHeaderFields, body: data)
        }
        return data
    }

    private func mapError(statusCode: Int, headers: [AnyHashable: Any], body: Data) -> HTTPClientError {
        let message = parseErrorMessage(body)
        switch statusCode {
        case 400: return .badRequest(message: message)
        case 401: return .unauthorized(message: message)
        case 404: return .notFound
        case 429:
            let retryAfter = (headers["Retry-After"] as? String).flatMap(Int.init) ?? 0
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .server(statusCode: statusCode, message: message)
        }
    }

    private func parseErrorMessage(_ body: Data) -> String? {
        // JetKVM's gin handlers return errors as `{"error": "..."}` (and
        // sometimes `{"message": "..."}` on success). Try both.
        struct Envelope: Decodable {
            let error: String?
            let message: String?
        }
        guard let env = try? decoder.decode(Envelope.self, from: body) else { return nil }
        return env.error ?? env.message
    }
}
