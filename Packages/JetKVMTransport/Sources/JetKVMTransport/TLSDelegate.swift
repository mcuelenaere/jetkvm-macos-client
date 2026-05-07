import Foundation

/// `URLSessionDelegate` that optionally trusts any server certificate
/// presented during the TLS handshake. Used so a user-opted-in
/// connection to a JetKVM device's default self-signed certificate
/// doesn't immediately fail closed.
///
/// Only the server-trust authentication challenge is handled; client
/// auth and other challenge methods fall through to default handling.
final class TLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    let allowSelfSignedCertificate: Bool

    init(allowSelfSignedCertificate: Bool) {
        self.allowSelfSignedCertificate = allowSelfSignedCertificate
    }

    // Session-level challenges (TLS server trust during connection setup).
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge: challenge, completionHandler: completionHandler)
    }

    // Task-level challenges (some servers issue TLS challenges per-task).
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge: challenge, completionHandler: completionHandler)
    }

    private func handle(
        challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if allowSelfSignedCertificate {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
