import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A connection to a FileMaker Server's Admin API (v2), used to list and
/// force-disconnect connected clients.
///
/// Independent of, and with zero dependency on, `Perfect-FileMaker`
/// (classic XML CWP) or `Perfect-FileMaker-DataAPI` — a consumer that only
/// needs session management pulls in just this package.
///
/// This type performs REAL disconnects when `disconnectClient` is called —
/// it has no built-in dry-run concept. "Would I disconnect this" is a
/// policy decision that belongs above this client (see `CWPSessionJanitor`),
/// not inside a raw API wrapper.
public struct FMAdminClient: Sendable {
    public let host: String
    public let port: Int
    let username: String
    let password: String
    let session: FMAdminSession
    let transport: any FMAdminTransport

    /// - Parameters:
    ///   - host: FileMaker Server hostname or IP address.
    ///   - port: Admin API port. Defaults to 16000.
    ///   - username: A full FileMaker Server admin account — NOT the same
    ///     credential as a CWP or Data API account.
    ///   - password: Admin account password.
    ///   - urlSession: Custom URLSession for certificate pinning or testing. Defaults to `.shared`.
    public init(host: String, port: Int = 16000, username: String, password: String,
                urlSession: URLSession = .shared) {
        self.init(host: host, port: port, username: username, password: password,
                   transport: URLSessionTransport(session: urlSession))
    }

    /// Same as the `urlSession:` initializer, but accepts any `FMAdminTransport`
    /// — e.g. `FMAdminInsecureLinuxTransport` on Linux, where there is no
    /// `URLSession`-based equivalent of a pinned/insecure TLS delegate. Most
    /// callers want the `urlSession:` initializer instead.
    init(host: String, port: Int = 16000, username: String, password: String,
         transport: any FMAdminTransport) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.session = FMAdminSession()
        self.transport = transport
    }

    /// Returns every currently connected client — all types (CWP, Pro, Go,
    /// WebDirect, Data API, FMSE, XDBC), not just CWP. No server-side
    /// filtering exists on this endpoint; callers filter client-side.
    public func listClients() async throws -> [FMAdminClientInfo] {
        let data = try await request(method: "GET", path: "/clients")
        return try JSONDecoder().decode(FMAdminClientsResponse.self, from: data).response.clients
    }

    /// Force-disconnects a single client. Performs a REAL disconnect — no
    /// dry-run gate here (see type doc comment).
    /// - Parameters:
    ///   - clientID: The `id` from a previously-fetched `FMAdminClientInfo`.
    ///   - messageText: Shown to the disconnected client, if the client type supports it.
    ///   - graceTime: Seconds of server-side grace period before the disconnect takes effect.
    public func disconnectClient(clientID: String, messageText: String, graceTime: Int = 0) async throws {
        let encodedMessage = messageText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? messageText
        let path = "/clients/\(clientID)?messageText=\(encodedMessage)&graceTime=\(graceTime)"
        _ = try await request(method: "DELETE", path: path)
    }

    // MARK: - Private helpers

    private var baseURL: String { "https://\(host):\(port)/fmi/admin/api/v2" }

    private func token() async throws -> String {
        try await session.getToken(host: host, port: port, username: username, password: password,
                                    transport: transport)
    }

    private func request(method: String, path: String) async throws -> Data {
        guard let url = URL(string: baseURL + path) else { throw FMAdminError.invalidResponse }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw FMAdminError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            await session.invalidate()
            throw FMAdminError.authenticationFailed
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FMAdminError.serverError(http.statusCode, body)
        }
        return data
    }
}
