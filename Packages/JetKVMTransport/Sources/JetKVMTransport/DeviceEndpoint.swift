import Foundation

/// Where on the network a JetKVM device lives. Owns URL construction so the
/// HTTP client and the WebSocket signaling client agree on the same scheme,
/// host and port.
public struct DeviceEndpoint: Sendable, Hashable {
    /// Hostname or IP literal. No scheme, no port, no brackets for IPv6 —
    /// we compose those at URL build time.
    public let host: String
    public let port: Int
    public let useTLS: Bool
    /// Accept the server's TLS certificate without normal trust validation.
    /// JetKVM ships with a self-signed certificate by default, so HTTPS/WSS
    /// connections fail closed without this opt-in. Only set true when the
    /// user has explicitly accepted it for this device.
    public let allowSelfSignedCertificate: Bool

    public init(
        host: String,
        port: Int = 80,
        useTLS: Bool = false,
        allowSelfSignedCertificate: Bool = false
    ) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.allowSelfSignedCertificate = allowSelfSignedCertificate
    }

    public func httpURL(path: String, queryItems: [URLQueryItem]? = nil) -> URL {
        url(scheme: useTLS ? "https" : "http", path: path, queryItems: queryItems)
    }

    public func webSocketURL(path: String) -> URL {
        url(scheme: useTLS ? "wss" : "ws", path: path, queryItems: nil)
    }

    private func url(scheme: String, path: String, queryItems: [URLQueryItem]?) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if shouldIncludePort {
            components.port = port
        }
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else {
            // The URLComponents path requires a leading slash. We control the
            // input here so this is a programming error if it fires.
            preconditionFailure("DeviceEndpoint produced an invalid URL: \(components)")
        }
        return url
    }

    private var shouldIncludePort: Bool {
        switch (useTLS, port) {
        case (true, 443), (false, 80): return false
        default: return true
        }
    }
}
