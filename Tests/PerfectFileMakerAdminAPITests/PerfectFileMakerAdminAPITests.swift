import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PerfectFileMakerAdminAPI

// MARK: - URLProtocol mock (captures the outgoing request, returns a canned response)

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CapturedRequestsBox: @unchecked Sendable {
    var requests: [URLRequest] = []
}

/// A plain local `var` can't be mutated from inside a `@Sendable` mock
/// handler closure — this box gives the handler somewhere thread-safe
/// (for this single-threaded mock's purposes) to stash a mutable counter.
private final class CounterBox: @unchecked Sendable {
    var value = 0
}

private func mockSession() -> URLSession {
    MockURLProtocol.requestCount = 0
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func mockClient(handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)) -> FMAdminClient {
    MockURLProtocol.requestHandler = handler
    return FMAdminClient(host: "mock.example", username: "admin", password: "secret", urlSession: mockSession())
}

private func authOKResponse(token: String = "abc123") -> (HTTPURLResponse, Data) {
    let http = HTTPURLResponse(url: URL(string: "https://mock.example:16000/fmi/admin/api/v2/user/auth")!,
                                statusCode: 200, httpVersion: nil, headerFields: nil)!
    let body = Data(#"{"response":{"token":"\#(token)"}}"#.utf8)
    return (http, body)
}

// Field names/shape confirmed live 2026-07-17 against a real FileMaker
// Server instance — see FMAdminModels.swift's doc comment.
private let sampleClientsJSON = """
{"response":{"clients":[
    {"id":"1","appType":"CWP","userName":"cwp-user","ipaddress":"10.0.0.5","connectDuration":"00:03:20"},
    {"id":"2","appType":"CWP","userName":"cwp-user","ipaddress":"10.0.0.6","connectDuration":"00:00:10"},
    {"id":"3","appType":"FMPRO","userName":"real-user","ipaddress":"10.0.0.7","connectDuration":"02:46:39"}
]}}
"""

// MARK: - FMAdminSession + FMAdminClient
//
// Both suites below share `MockURLProtocol`'s static state, so they're
// combined into ONE `.serialized` suite — `.serialized` only guarantees
// ordering *within* a suite, not across two separate suites, which the
// test runner is otherwise free to run concurrently against each other.

@Suite(.serialized)
struct FMAdminSessionAndClientTests {
    @Test func getTokenCachesAcrossCalls() async throws {
        let counter = CounterBox()
        let box = CapturedRequestsBox()
        MockURLProtocol.requestHandler = { req in
            box.requests.append(req)
            counter.value += 1
            return authOKResponse()
        }
        let session = FMAdminSession()
        let urlSession = mockSession()
        let first = try await session.getToken(host: "mock.example", port: 16000, username: "u", password: "p", transport: URLSessionTransport(session: urlSession))
        let second = try await session.getToken(host: "mock.example", port: 16000, username: "u", password: "p", transport: URLSessionTransport(session: urlSession))
        #expect(first == "abc123")
        #expect(second == "abc123")
        #expect(counter.value == 1) // second call reused the cached token, no second login
    }

    @Test func invalidateForcesFreshLogin() async throws {
        let counter = CounterBox()
        MockURLProtocol.requestHandler = { _ in
            counter.value += 1
            return authOKResponse(token: "token-\(counter.value)")
        }
        let session = FMAdminSession()
        let urlSession = mockSession()
        let first = try await session.getToken(host: "mock.example", port: 16000, username: "u", password: "p", transport: URLSessionTransport(session: urlSession))
        await session.invalidate()
        let second = try await session.getToken(host: "mock.example", port: 16000, username: "u", password: "p", transport: URLSessionTransport(session: urlSession))
        #expect(first == "token-1")
        #expect(second == "token-2")
        #expect(counter.value == 2)
    }

    @Test func loginFailureThrowsAuthenticationFailed() async {
        MockURLProtocol.requestHandler = { req in
            let http = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (http, Data())
        }
        let session = FMAdminSession()
        await #expect(throws: FMAdminError.self) {
            _ = try await session.getToken(host: "mock.example", port: 16000, username: "u", password: "p", transport: URLSessionTransport(session: mockSession()))
        }
    }

    @Test func listClientsDecodesResponse() async throws {
        let client = mockClient { req in
            if req.url?.path.contains("/user/auth") == true {
                return authOKResponse()
            }
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(sampleClientsJSON.utf8))
        }
        let clients = try await client.listClients()
        #expect(clients.count == 3)
        #expect(clients[0].id == "1")
        #expect(clients[0].appType == "CWP")
        #expect(clients[0].connectDurationSeconds == 200)
        #expect(clients[2].appType == "FMPRO")
    }

    @Test func disconnectClientBuildsCorrectURL() async throws {
        let box = CapturedRequestsBox()
        let client = mockClient { req in
            box.requests.append(req)
            if req.url?.path.contains("/user/auth") == true {
                return authOKResponse()
            }
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data())
        }
        try await client.disconnectClient(clientID: "42", messageText: "bye now", graceTime: 5)
        let disconnectRequest = box.requests.first { $0.httpMethod == "DELETE" }
        #expect(disconnectRequest != nil)
        let url = disconnectRequest?.url?.absoluteString ?? ""
        #expect(url.contains("/clients/42"))
        #expect(url.contains("graceTime=5"))
        #expect(url.contains("messageText=bye"))
    }

    @Test func unauthorizedResponseInvalidatesSessionAndThrows() async {
        let client = mockClient { req in
            if req.url?.path.contains("/user/auth") == true {
                return authOKResponse()
            }
            let http = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (http, Data())
        }
        await #expect(throws: FMAdminError.self) {
            _ = try await client.listClients()
        }
    }

    @Test func nonSuccessStatusSurfacesAsServerError() async {
        let client = mockClient { req in
            if req.url?.path.contains("/user/auth") == true {
                return authOKResponse()
            }
            let http = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (http, Data("boom".utf8))
        }
        do {
            _ = try await client.listClients()
            Issue.record("Expected FMAdminError.serverError to be thrown")
        } catch FMAdminError.serverError(let code, let message) {
            #expect(code == 500)
            #expect(message == "boom")
        } catch {
            Issue.record("Expected FMAdminError.serverError, got \(error)")
        }
    }

    @Test func sweepCapsDisconnectsPerSweepOldestFirst() async throws {
        let fiveClientsJSON = """
        {"response":{"clients":[
            {"id":"1","appType":"CWP","connectDuration":"00:05:00"},
            {"id":"2","appType":"CWP","connectDuration":"00:04:00"},
            {"id":"3","appType":"CWP","connectDuration":"00:03:00"},
            {"id":"4","appType":"CWP","connectDuration":"00:02:00"},
            {"id":"5","appType":"CWP","connectDuration":"00:01:00"}
        ]}}
        """
        let box = CapturedRequestsBox()
        let client = mockClient { req in
            box.requests.append(req)
            if req.url?.path.contains("/user/auth") == true {
                return authOKResponse()
            }
            if req.httpMethod == "DELETE" {
                let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (http, Data())
            }
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(fiveClientsJSON.utf8))
        }
        let tracker = CWPSessionJanitorTracker()
        await CWPSessionJanitor.sweep(
            client: client,
            durationThresholdSeconds: 10, // all 5 clients exceed this
            maxSessions: 1, // excess=4 ("1".."4" over the limit, "5" spared)
            minFloor: 0,
            maxDisconnectsPerSweep: 2,
            dryRun: false,
            tracker: tracker,
            log: { _ in }
        )
        let disconnectedIDs = box.requests
            .filter { $0.httpMethod == "DELETE" }
            .compactMap { $0.url?.path.split(separator: "/").last }
            .map(String.init)
        #expect(disconnectedIDs.count == 2)
        // Oldest-first among the over-limit excess: "1" and "2" (300s, 240s).
        #expect(Set(disconnectedIDs) == Set(["1", "2"]))
        let snapshot = await tracker.snapshot()
        #expect(snapshot.considered == 5)
        #expect(snapshot.disconnected == 2)
    }

    @Test func sweepWithNoCapDisconnectsAllCandidates() async throws {
        let threeClientsJSON = """
        {"response":{"clients":[
            {"id":"1","appType":"CWP","connectDuration":"00:05:00"},
            {"id":"2","appType":"CWP","connectDuration":"00:03:20"},
            {"id":"3","appType":"CWP","connectDuration":"00:00:10"}
        ]}}
        """
        let box = CapturedRequestsBox()
        let client = mockClient { req in
            box.requests.append(req)
            if req.url?.path.contains("/user/auth") == true {
                return authOKResponse()
            }
            if req.httpMethod == "DELETE" {
                let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (http, Data())
            }
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(threeClientsJSON.utf8))
        }
        let tracker = CWPSessionJanitorTracker()
        await CWPSessionJanitor.sweep(
            client: client,
            durationThresholdSeconds: 5, // "1" (300s) and "2" (200s) both exceed this
            maxSessions: 1, // excess=2 -> "1" and "2" over the limit, "3" spared
            minFloor: 0,
            maxDisconnectsPerSweep: nil,
            dryRun: false,
            tracker: tracker,
            log: { _ in }
        )
        let disconnectedCount = box.requests.filter { $0.httpMethod == "DELETE" }.count
        #expect(disconnectedCount == 2)
    }
}

// MARK: - CWPSessionSelector

@Suite struct CWPSessionSelectorTests {
    /// Builds a test fixture, taking `duration` in seconds for readability
    /// and formatting it into the real `connectDuration` "H+:MM:SS" shape
    /// `FMAdminClientInfo` actually decodes from the live API.
    private func client(id: String, type: String = "CWP", duration: Int) -> FMAdminClientInfo {
        let h = duration / 3600
        let m = (duration % 3600) / 60
        let s = duration % 60
        let formatted = String(format: "%02d:%02d:%02d", h, m, s)
        return FMAdminClientInfo(id: id, appType: type, connectDuration: formatted)
    }

    // Current semantics (redesigned 2026-07-18 per live-test findings): being
    // over the count limit is the ONLY trigger for considering a disconnect
    // at all. Duration only ever narrows down *which* of the over-the-limit
    // sessions get disconnected — a session's age alone, while under the
    // count limit, is never sufficient reason to kill it.

    @Test func neverDisconnectsWhenUnderMaxSessionsRegardlessOfAge() {
        let clients = [client(id: "1", duration: 99999)]
        let (_, candidates) = CWPSessionSelector.selectCandidates(
            allClients: clients, cwpTypeValue: "CWP",
            durationThresholdSeconds: 1, maxSessions: 5, minFloor: 0
        )
        #expect(candidates.isEmpty)
    }

    @Test func nilMaxSessionsAlwaysSelectsNothing() {
        let clients = [client(id: "1", duration: 99999)]
        let (_, candidates) = CWPSessionSelector.selectCandidates(
            allClients: clients, cwpTypeValue: "CWP",
            durationThresholdSeconds: 1, maxSessions: nil, minFloor: 0
        )
        #expect(candidates.isEmpty)
    }

    @Test func underMaxSessionsSelectsNothing() {
        let clients = [client(id: "1", duration: 300), client(id: "2", duration: 200)]
        let (_, candidates) = CWPSessionSelector.selectCandidates(
            allClients: clients, cwpTypeValue: "CWP",
            durationThresholdSeconds: nil, maxSessions: 5, minFloor: 0
        )
        #expect(candidates.isEmpty)
    }

    @Test func overLimitButUnderDurationThresholdIsNotSelected() {
        // 4 clients, maxSessions=2 -> excess=2, the two OLDEST ("1", "2") are
        // "over the limit". But with a duration threshold of 250, only "1"
        // (500s) clears it — "2" (200s) is over the limit yet still gets
        // spared, proving age-while-over-the-limit alone isn't sufficient.
        let clients = [
            client(id: "1", duration: 500),
            client(id: "2", duration: 200),
            client(id: "3", duration: 100),
            client(id: "4", duration: 50),
        ]
        let (_, candidates) = CWPSessionSelector.selectCandidates(
            allClients: clients, cwpTypeValue: "CWP",
            durationThresholdSeconds: 250, maxSessions: 2, minFloor: 0
        )
        #expect(candidates.map(\.id) == ["1"])
    }

    @Test func overLimitAndOverDurationThresholdBothSelected() {
        let clients = [
            client(id: "1", duration: 500),
            client(id: "2", duration: 200),
            client(id: "3", duration: 100),
            client(id: "4", duration: 50),
        ]
        let (_, candidates) = CWPSessionSelector.selectCandidates(
            allClients: clients, cwpTypeValue: "CWP",
            durationThresholdSeconds: 150, maxSessions: 2, minFloor: 0
        )
        #expect(Set(candidates.map(\.id)) == ["1", "2"])
    }

    @Test func nilDurationThresholdSelectsAllOverLimitUnconditionally() {
        let clients = [
            client(id: "1", duration: 300), client(id: "2", duration: 200),
            client(id: "3", duration: 100), client(id: "4", duration: 50),
        ]
        let (_, candidates) = CWPSessionSelector.selectCandidates(
            allClients: clients, cwpTypeValue: "CWP",
            durationThresholdSeconds: nil, maxSessions: 2, minFloor: 0
        )
        #expect(Set(candidates.map(\.id)) == ["1", "2"]) // two oldest, count(4) - max(2) = 2 excess
    }

    @Test func minFloorTrimsYoungestCandidatesFirst() {
        // 3 CWP clients, maxSessions=1 puts "old" and "mid" over the limit,
        // both also over the duration threshold — but minFloor=2 means only
        // 1 can actually be removed, so the OLDEST (most urgent) survives as
        // a candidate and "mid" gets dropped.
        let clients = [
            client(id: "old", duration: 500),
            client(id: "mid", duration: 400),
            client(id: "young", duration: 300),
        ]
        let (_, candidates) = CWPSessionSelector.selectCandidates(
            allClients: clients, cwpTypeValue: "CWP",
            durationThresholdSeconds: 100, maxSessions: 1, minFloor: 2
        )
        #expect(candidates.count == 1)
        #expect(candidates.first?.id == "old")
    }

    @Test func nonCWPClientTypesExcludedFromCountAndCandidates() {
        let clients = [
            client(id: "1", type: "Pro", duration: 99999),
            client(id: "2", type: "WebDirect", duration: 99999),
            client(id: "3", type: "CWP", duration: 300),
            client(id: "4", type: "CWP", duration: 10),
        ]
        let (cwp, candidates) = CWPSessionSelector.selectCandidates(
            allClients: clients, cwpTypeValue: "CWP",
            durationThresholdSeconds: 100, maxSessions: 1, minFloor: 0
        )
        // Only the two real CWP clients count toward `cwp` at all — the
        // huge-duration non-CWP clients neither inflate the count nor
        // become candidates themselves.
        #expect(cwp.map(\.id) == ["3", "4"])
        #expect(candidates.map(\.id) == ["3"])
    }
}

// MARK: - CWPSessionJanitorTracker

@Suite struct CWPSessionJanitorTrackerTests {
    @Test func tryBeginBlocksConcurrentStart() async {
        let tracker = CWPSessionJanitorTracker()
        let first = await tracker.tryBegin()
        let second = await tracker.tryBegin()
        #expect(first == true)
        #expect(second == false)
        #expect(await tracker.isRunning == true)
    }

    @Test func finishClearsRunningAndExposesSummary() async {
        let tracker = CWPSessionJanitorTracker()
        await tracker.tryBegin()
        await tracker.finish(consideredCount: 10, disconnectedCount: 3, dryRun: false)
        #expect(await tracker.isRunning == false)
        let status = await tracker.statusDescription(fallback: "idle")
        #expect(status.contains("10 CWP session(s) considered"))
        #expect(status.contains("3 disconnected"))
        #expect(status.contains("armed"))
        #expect(await tracker.tryBegin() == true) // a finished tracker allows starting again
    }

    @Test func statusDescriptionFallsBackWhenNeverRun() async {
        let tracker = CWPSessionJanitorTracker()
        let status = await tracker.statusDescription(fallback: "idle description")
        #expect(status == "idle description")
    }

    @Test func snapshotReflectsLastSweep() async {
        let tracker = CWPSessionJanitorTracker()
        await tracker.tryBegin()
        await tracker.finish(consideredCount: 5, disconnectedCount: 1, dryRun: true, error: "oops")
        let snapshot = await tracker.snapshot()
        #expect(snapshot.considered == 5)
        #expect(snapshot.disconnected == 1)
        #expect(snapshot.dryRun == true)
        #expect(snapshot.error == "oops")
        #expect(snapshot.lastSweepAt != nil)
    }
}
