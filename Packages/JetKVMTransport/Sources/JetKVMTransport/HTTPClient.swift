import Foundation
import JetKVMProtocol
import OSLog

private let log = Logger(subsystem: "app.jetkvm.client", category: "http")

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
    private let tlsDelegate: TLSDelegate

    private let encoder: JSONEncoder = JSONEncoder()
    private let decoder: JSONDecoder = JSONDecoder()

    public init(endpoint: DeviceEndpoint) {
        self.endpoint = endpoint
        // Per-instance cookie storage. Using `.shared` would leak auth across
        // connections to different devices.
        let storage = HTTPCookieStorage()
        storage.cookieAcceptPolicy = .always
        self.cookieStorage = storage
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = storage
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        let delegate = TLSDelegate(allowSelfSignedCertificate: endpoint.allowSelfSignedCertificate)
        self.tlsDelegate = delegate
        self.urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
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
    /// `Set-Cookie: authToken=<uuid>` is captured into `cookieStorage` and
    /// will be replayed automatically on subsequent requests AND on the
    /// signaling WebSocket handshake (URLSession applies cookies to WS
    /// upgrades when both share a `URLSessionConfiguration.httpCookieStorage`).
    ///
    /// Belt and braces: we also explicitly parse `Set-Cookie` from the
    /// response and inject into storage. URLSession *should* do this
    /// automatically, but we've seen a hardware-test where the
    /// subsequent `GET /device` came back 401 — pulling the cookie in by
    /// hand removes that as a possible failure mode.
    public func login(password: String) async throws {
        let url = endpoint.httpURL(path: "/auth/login-local")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpShouldHandleCookies = true
        req.httpBody = try encoder.encode(LoginRequest(password: password))
        let (data, response) = try await rawCall(req)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }
        if !(200..<300).contains(httpResponse.statusCode) {
            throw mapError(statusCode: httpResponse.statusCode, headers: httpResponse.allHeaderFields, body: data)
        }
        injectSetCookieFromResponse(httpResponse, requestURL: url)
        log.debug("login OK; cookies in storage for \(url.absoluteString, privacy: .public): \(self.cookieDump(for: url), privacy: .public)")
    }

    private func injectSetCookieFromResponse(_ response: HTTPURLResponse, requestURL: URL) {
        // HTTPURLResponse.allHeaderFields is `[AnyHashable: Any]`, but
        // HTTPCookie.cookies(withResponseHeaderFields:) expects [String: String].
        // Filter to string-keyed/string-valued entries.
        var stringHeaders: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                stringHeaders[k] = v
            }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: stringHeaders, for: requestURL)
        for cookie in cookies {
            cookieStorage.setCookie(cookie)
        }
    }

    private func cookieDump(for url: URL) -> String {
        guard let cookies = cookieStorage.cookies(for: url), !cookies.isEmpty else { return "(none)" }
        return cookies.map { "\($0.name)=\($0.value.prefix(8))…(d=\($0.domain) p=\($0.path))" }.joined(separator: ", ")
    }

    // MARK: - Internal request plumbing

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = endpoint.httpURL(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpShouldHandleCookies = true
        log.debug("GET \(url.absoluteString, privacy: .public); cookies: \(self.cookieDump(for: url), privacy: .public)")
        return try await perform(req)
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
        let (data, response) = try await rawCall(request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapError(statusCode: http.statusCode, headers: http.allHeaderFields, body: data)
        }
        return data
    }

    private func rawCall(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await urlSession.data(for: request)
        } catch {
            throw HTTPClientError.transport(String(describing: error))
        }
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
