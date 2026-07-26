import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one HTTP call shape `FMAdminClient`/`FMAdminSession` need, factored
/// out so they can be backed by either `URLSession` (the default on every
/// platform, and the only option on Darwin) or an AsyncHTTPClient-backed
/// transport (Linux dev/test TLS pinning — see `FMAdminInsecureLinuxTransport`).
/// Not a general-purpose networking abstraction: scoped to exactly this one
/// method because that's the only one either caller uses.
protocol FMAdminTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Wraps `URLSession` rather than conforming it to `FMAdminTransport`
/// directly via an `extension URLSession: FMAdminTransport {}` — Darwin's
/// and Linux's `URLSession.data(for:)` overload sets differ just enough
/// (an extra defaulted `delegate:` parameter on Darwin) that direct calls
/// resolve fine on both platforms, but strict protocol witness matching
/// rejects the conformance on Linux. Calling through a concrete method body
/// sidesteps that: it's ordinary overload resolution, not witness matching.
struct URLSessionTransport: FMAdminTransport {
    let session: URLSession

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
