import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Darwin-only: relies on `URLProtectionSpace.serverTrust`/`URLCredential(trust:)`,
// which need the Security framework's SecTrust/SecIdentity primitives. Those are
// not implemented in swift-corelibs-foundation on Linux (still open upstream as of
// swiftlang/swift-corelibs-foundation#5157), so there is no `URLSession`-based
// equivalent to swap in on Linux. See `FMAdminInsecureLinuxTransport` in
// FMAdminInsecureLinuxTransport.swift for the Linux dev/test path (pinned to a
// caller-supplied certificate, not a trust-anything bypass); the supported
// production path on Linux remains installing the server's certificate into the
// system CA trust store.
#if canImport(Security)

/// Accepts ANY server TLS certificate unconditionally, including self-signed
/// ones — e.g. FileMaker Server's default "Claris Self Signed Certificate
/// (Not for Production Use)". This is an explicit opt-in escape hatch for a
/// known dev/test server, NOT a default: using this against a server whose
/// identity you haven't otherwise verified defeats TLS's whole purpose. See
/// `FMAdminClient.insecureURLSession()`.
public final class FMAdminInsecureTLSDelegate: NSObject, URLSessionDelegate {
    public override init() { super.init() }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

extension FMAdminClient {
    /// A `URLSession` that trusts any server certificate unconditionally —
    /// pass as `urlSession:` to `FMAdminClient.init` when the target is a
    /// known dev/test FileMaker Server using a self-signed certificate.
    /// Never use this for a server reachable over an untrusted network.
    public static func insecureURLSession() -> URLSession {
        URLSession(configuration: .ephemeral, delegate: FMAdminInsecureTLSDelegate(), delegateQueue: nil)
    }
}

#endif
