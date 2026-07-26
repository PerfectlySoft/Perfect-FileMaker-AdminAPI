#if os(Linux)
import Foundation
import FoundationNetworking
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import NIOSSL

/// Linux equivalent of `FMAdminInsecureTLSDelegate` (see
/// `FMAdminInsecureTLS.swift`) for connecting to a known dev/test FileMaker
/// Server that presents a self-signed certificate.
///
/// `URLProtectionSpace.serverTrust`/`SecTrust` — what the Darwin delegate
/// relies on to evaluate and accept a self-signed cert — are unimplemented
/// in swift-corelibs-foundation on Linux (still open upstream), so there is
/// no way to build a Linux `URLSessionDelegate` that does the same thing.
///
/// Rather than porting "trust whatever cert this session presents" (which
/// would need to disable certificate verification globally for the
/// connection), this PINS trust to one specific certificate you supply, via
/// NIOSSL/AsyncHTTPClient: a MITM presenting any other certificate —
/// including one from a real, trusted CA — still fails. That's a strictly
/// narrower bypass than the Darwin delegate, not a matching one.
///
/// Never point this at a production FileMaker Server: it carries Admin API
/// credentials, which grant full server reconfiguration privileges.
public final class FMAdminInsecureLinuxTransport: FMAdminTransport, Sendable {
    private let httpClient: HTTPClient

    /// - Parameter pinnedCertificatePath: Path to a PEM file containing the
    ///   dev/test FileMaker Server's certificate — e.g. captured with
    ///   `openssl s_client -connect host:port -showcerts`. When omitted,
    ///   falls back to the `FMADMIN_INSECURE_CERT_PATH` environment
    ///   variable; if neither is set, throws
    ///   `FMAdminInsecureTLSError.missingCertificatePath`.
    public init(pinnedCertificatePath: String? = nil) throws {
        guard let path = pinnedCertificatePath
            ?? ProcessInfo.processInfo.environment["FMADMIN_INSECURE_CERT_PATH"] else {
            throw FMAdminInsecureTLSError.missingCertificatePath
        }
        let certificates: [NIOSSLCertificate]
        do {
            certificates = try NIOSSLCertificate.fromPEMFile(path)
        } catch {
            throw FMAdminInsecureTLSError.unreadableCertificate(path: path, underlying: error)
        }

        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        tlsConfiguration.trustRoots = .certificates(certificates)
        tlsConfiguration.certificateVerification = .fullVerification

        self.httpClient = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: HTTPClient.Configuration(tlsConfiguration: tlsConfiguration)
        )

        FileHandle.standardError.write(Data("""
            [PerfectFileMakerAdminAPI] FMAdminInsecureLinuxTransport constructed, pinned to \
            certificate at \(path). TLS trust for connections made through this transport is \
            limited to that one certificate — never use it against a production FileMaker Server.\n
            """.utf8))
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }

        var httpRequest = HTTPClientRequest(url: url.absoluteString)
        httpRequest.method = HTTPMethod(rawValue: request.httpMethod ?? "GET")
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            httpRequest.headers.replaceOrAdd(name: name, value: value)
        }
        if let body = request.httpBody {
            httpRequest.body = .bytes(ByteBuffer(bytes: body))
        }

        let response = try await httpClient.execute(httpRequest, timeout: .seconds(30))
        // The Admin API returns small JSON payloads (client lists, tokens) —
        // this cap is a sanity bound, not a real limit on expected traffic.
        let buffer = try await response.body.collect(upTo: 10 * 1024 * 1024)
        let data = Data(buffer.readableBytesView)

        var headerFields: [String: String] = [:]
        for (name, value) in response.headers {
            headerFields[name] = value
        }
        guard let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: Int(response.status.code),
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        ) else {
            throw FMAdminInsecureTLSError.invalidResponse
        }
        return (data, httpResponse)
    }

    /// Releases the underlying `HTTPClient`'s event loop resources. Not
    /// required for short-lived CLI/script usage, where process exit
    /// reclaims it — call it explicitly in long-running processes that
    /// construct more than one of these over their lifetime.
    public func shutdown() async throws {
        try await httpClient.shutdown()
    }
}

public enum FMAdminInsecureTLSError: Error, CustomStringConvertible {
    case missingCertificatePath
    case unreadableCertificate(path: String, underlying: Error)
    case invalidResponse

    public var description: String {
        switch self {
        case .missingCertificatePath:
            return "FMAdminInsecureLinuxTransport needs a certificate to pin to — pass " +
                   "pinnedCertificatePath:, or set the FMADMIN_INSECURE_CERT_PATH environment variable."
        case .unreadableCertificate(let path, let underlying):
            return "FMAdminInsecureLinuxTransport could not read a PEM certificate from " +
                   "\(path): \(underlying)"
        case .invalidResponse:
            return "FMAdminInsecureLinuxTransport received a response it could not translate to HTTPURLResponse."
        }
    }
}

extension FMAdminClient {
    /// Builds an `FMAdminClient` on Linux backed by a certificate-pinned
    /// transport instead of `URLSession` — see `FMAdminInsecureLinuxTransport`
    /// for why `URLSession` alone can't do this on Linux, and why this pins
    /// to one certificate rather than trusting any certificate.
    ///
    /// - Parameter pinnedCertificatePath: Forwarded to
    ///   `FMAdminInsecureLinuxTransport.init`; falls back to
    ///   `FMADMIN_INSECURE_CERT_PATH` when omitted.
    public static func insecureLinux(
        host: String, port: Int = 16000, username: String, password: String,
        pinnedCertificatePath: String? = nil
    ) throws -> FMAdminClient {
        let transport = try FMAdminInsecureLinuxTransport(pinnedCertificatePath: pinnedCertificatePath)
        return FMAdminClient(host: host, port: port, username: username, password: password,
                              transport: transport)
    }
}
#endif
