import Foundation
import OSLog
import Security

private let log = Logger(subsystem: "app.jetkvm.client", category: "tls")

/// `URLSessionDelegate` that optionally trusts any server certificate
/// presented during the TLS handshake. Used so a user-opted-in
/// connection to a JetKVM device's default self-signed certificate
/// doesn't immediately fail closed.
///
/// `URLCredential(trust:)` alone is not enough — URLSession also runs
/// hostname validation, and JetKVM's default cert's CN typically does
/// not match the address the user typed (e.g. `jetkvm.local`). We
/// install `SecTrustSetExceptions` to bypass *all* validation failures
/// when the user has explicitly opted in; this is equivalent to "I
/// trust this exact certificate from this exact server" and is the
/// pattern Apple documents for handling self-signed certs.
final class TLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    let allowSelfSignedCertificate: Bool

    init(allowSelfSignedCertificate: Bool) {
        self.allowSelfSignedCertificate = allowSelfSignedCertificate
    }

    // Session-level challenges (rare for TLS — usually fires task-level).
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge: challenge, level: "session", completionHandler: completionHandler)
    }

    // Task-level challenges (HTTPS server trust normally fires here).
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge: challenge, level: "task", completionHandler: completionHandler)
    }

    private func handle(
        challenge: URLAuthenticationChallenge,
        level: String,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        log.debug("\(level)-level challenge: method=\(method, privacy: .public) host=\(challenge.protectionSpace.host, privacy: .public) allow=\(self.allowSelfSignedCertificate, privacy: .public)")

        guard method == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard allowSelfSignedCertificate else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 1. Try evaluating; if it fails, copy the failure as exceptions
        //    onto the trust object so subsequent evaluation passes.
        var error: CFError?
        let initialOk = SecTrustEvaluateWithError(serverTrust, &error)
        if !initialOk {
            log.debug("initial trust evaluation failed: \(error?.localizedDescription ?? "?", privacy: .public) — installing exceptions")
            if let exceptions = SecTrustCopyExceptions(serverTrust) {
                SecTrustSetExceptions(serverTrust, exceptions)
            }
        }

        // 2. Hand URLSession a credential built from the (now-accepted)
        //    trust object. This bypasses both cert validity and hostname
        //    checks — that's the user's explicit opt-in.
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
