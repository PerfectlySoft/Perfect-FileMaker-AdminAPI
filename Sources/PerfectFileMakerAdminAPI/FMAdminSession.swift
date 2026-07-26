import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Manages the Admin API bearer token for a single FileMaker Server host.
///
/// Tokens last 15 minutes from last use, but the countdown resets on every
/// call — the token MUST be cached and reused across calls, never re-fetched
/// on every poll. Re-authenticating on every call is a documented
/// anti-pattern that exhausts a hard cap on concurrent Admin API sessions;
/// the resulting failure is a generic auth error, not an obvious "out of
/// quota" message, so this caching is load-bearing correctness, not just
/// an optimization.
actor FMAdminSession {
    private var token: String?

    func currentToken() -> String? { token }

    func invalidate() { token = nil }

    func getToken(host: String, port: Int, username: String, password: String,
                  transport: any FMAdminTransport) async throws -> String {
        if let token { return token }
        let newToken = try await Self.login(
            host: host, port: port, username: username, password: password,
            transport: transport
        )
        self.token = newToken
        return newToken
    }

    // The Admin API is HTTPS-only on its own port (16000 by default) —
    // unlike the classic XML CWP client, there's no plain-HTTP fallback to
    // consider here.
    private static func login(host: String, port: Int, username: String, password: String,
                               transport: any FMAdminTransport) async throws -> String {
        guard let url = URL(string: "https://\(host):\(port)/fmi/admin/api/v2/user/auth") else {
            throw FMAdminError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FMAdminError.authenticationFailed
        }
        struct AuthResponse: Decodable {
            struct Inner: Decodable { let token: String }
            let response: Inner
        }
        return try JSONDecoder().decode(AuthResponse.self, from: data).response.token
    }
}
