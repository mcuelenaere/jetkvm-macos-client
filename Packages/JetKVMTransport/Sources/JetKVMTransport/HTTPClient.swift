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
    /// TLS handshake completed but the server's certificate didn't
    /// pass the system trust store and the user hasn't opted into
    /// trusting it. The reason carries the system-localized message
    /// (e.g. "certificate is not trusted") for display.
    case untrustedServerCertificate(reason: String)
}

/// HTTP client for JetKVM's REST endpoints.
///
/// One client per device. Manages the auth cookie by hand rather than
/// relying on `HTTPCookieStorage`: in hardware testing, even after
/// explicitly calling `setCookie(_:)` on a per-instance `HTTPCookieStorage`,
/// `cookies(for:)` returned nothing and the auth cookie didn't ride
/// along on the next request. Bypassing the OS cookie machinery and
/// attaching `Cookie:` headers ourselves removes the entire failure mode.
public final class HTTPClient: @unchecked Sendable {
    public let endpoint: DeviceEndpoint
    public let urlSession: URLSession
    private let tlsDelegate: TLSDelegate

    /// Manually-managed cookie jar. Single dictionary keyed by cookie
    /// name; this is sufficient for JetKVM's only cookie (`authToken`)
    /// and avoids the complexity of full RFC-6265 storage semantics
    /// for a single host.
    private let cookiesLock = NSLock()
    private var cookieJar: [String: String] = [:]

    private let encoder: JSONEncoder = JSONEncoder()
    private let decoder: JSONDecoder = JSONDecoder()

    public init(endpoint: DeviceEndpoint) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        // Turn off URLSession's automatic cookie handling so we don't have to
        // fight it; everything goes through `cookieJar`.
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        let delegate = TLSDelegate(allowSelfSignedCertificate: endpoint.allowSelfSignedCertificate)
        self.tlsDelegate = delegate
        self.urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Cookie header value to attach to ad-hoc requests outside this
    /// client (e.g. the WebSocket signaling upgrade in `SignalingClient`).
    /// Returns nil when the jar is empty.
    public var currentCookieHeader: String? {
        cookiesLock.lock()
        defer { cookiesLock.unlock() }
        guard !cookieJar.isEmpty else { return nil }
        return cookieJar.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
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
    /// `Set-Cookie: authToken=<uuid>` is parsed out of the response by
    /// hand and stored in `cookieJar`; subsequent requests attach it
    /// via the `Cookie:` header.
    public func login(password: String) async throws {
        let url = endpoint.httpURL(path: "/auth/login-local")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try encoder.encode(LoginRequest(password: password))
        attachCookies(to: &req)
        let (data, response) = try await rawCall(req)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }
        log.debug("login response status=\(httpResponse.statusCode, privacy: .public) headers=\(self.headerKeys(httpResponse), privacy: .public)")
        if !(200..<300).contains(httpResponse.statusCode) {
            throw mapError(statusCode: httpResponse.statusCode, headers: httpResponse.allHeaderFields, body: data)
        }
        captureCookies(from: httpResponse, requestURL: url)
        log.debug("login OK; cookieJar=\(self.cookieDump(), privacy: .public)")
    }

    // MARK: - Internal request plumbing

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = endpoint.httpURL(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        attachCookies(to: &req)
        log.debug("GET \(url.absoluteString, privacy: .public); cookies=\(self.cookieDump(), privacy: .public)")
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
        // Capture any cookies even on non-2xx responses; servers sometimes
        // set cookies on 4xx (e.g. session-rotation on auth failure).
        if let url = request.url {
            captureCookies(from: http, requestURL: url)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw mapError(statusCode: http.statusCode, headers: http.allHeaderFields, body: data)
        }
        return data
    }

    private func rawCall(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await urlSession.data(for: request)
        } catch let urlErr as URLError where Self.isTLSTrustError(urlErr.code) {
            // System trust store rejected the cert chain and the user
            // hasn't opted into trusting it (allowSelfSignedCertificate
            // is false, or TLSDelegate fell through to default
            // handling). Surface as a distinct error so Session can
            // transition to .awaitingTrustOverride and the UI can
            // prompt the user.
            throw HTTPClientError.untrustedServerCertificate(
                reason: urlErr.localizedDescription
            )
        } catch {
            throw HTTPClientError.transport(String(describing: error))
        }
    }

    /// True for the URLError codes that mean "the TLS handshake's cert
    /// chain didn't pass system trust evaluation." We treat all of
    /// these the same — the user opt-in we'd offer (`SecTrustSet-
    /// Exceptions` via TLSDelegate) overrides chain-of-trust *and*
    /// hostname *and* validity-period checks anyway.
    private static func isTLSTrustError(_ code: URLError.Code) -> Bool {
        switch code {
        case .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateHasBadDate,
             .serverCertificateNotYetValid:
            return true
        default:
            return false
        }
    }

    // MARK: - Cookie jar

    private func attachCookies(to request: inout URLRequest) {
        cookiesLock.lock()
        defer { cookiesLock.unlock() }
        guard !cookieJar.isEmpty else { return }
        let header = cookieJar.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        request.setValue(header, forHTTPHeaderField: "Cookie")
    }

    private func captureCookies(from response: HTTPURLResponse, requestURL: URL) {
        // Pull all string-typed headers and run them through HTTPCookie's
        // own parser — that's the only way to handle multi-Set-Cookie
        // responses correctly (commas in Expires dates make naive
        // splitting unsafe).
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                headers[k] = v
            }
        }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: headers, for: requestURL)
        guard !parsed.isEmpty else { return }
        cookiesLock.lock()
        defer { cookiesLock.unlock() }
        for cookie in parsed {
            cookieJar[cookie.name] = cookie.value
        }
    }

    private func cookieDump() -> String {
        cookiesLock.lock()
        defer { cookiesLock.unlock() }
        if cookieJar.isEmpty { return "(none)" }
        return cookieJar.map { "\($0.key)=\($0.value.prefix(8))…" }.joined(separator: ", ")
    }

    private func headerKeys(_ response: HTTPURLResponse) -> String {
        response.allHeaderFields.keys.compactMap { $0 as? String }.joined(separator: ", ")
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
        struct Envelope: Decodable {
            let error: String?
            let message: String?
        }
        guard let env = try? decoder.decode(Envelope.self, from: body) else { return nil }
        return env.error ?? env.message
    }
}
