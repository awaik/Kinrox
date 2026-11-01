import Foundation
import Testing

@testable import SpotifyWebAPI

@Suite(.serialized)
struct SpotifyClientTests {
    @Test func pagingAndMembershipWireShapes() async throws {
        let stub = StubURLProtocol.state
        stub.reset([
            .init(
                body: #"{"items":[],"next":"https://api.spotify.com/v1/me/playlists?offset=50"}"#),
            .init(body: #"{"items":[],"next":null}"#),
            .init(body: ""),
            .init(body: #"{"snapshot_id":"new"}"#),
        ])
        let client = client()
        #expect(try await client.playlists().isEmpty)
        try await client.setSaved(uris: ["spotify:artist:abc", "spotify:track:def"], saved: false)
        #expect(
            try await client.removeItems(playlistID: "abc", uris: ["spotify:track:def"]) == "new")
        let requests = stub.requests
        #expect(requests.count == 4)
        #expect(requests[2].httpMethod == "DELETE")
        #expect(
            URLComponents(url: requests[2].url!, resolvingAgainstBaseURL: false)?.queryItems?.first?
                .value == "spotify:artist:abc,spotify:track:def")
        let body =
            try JSONSerialization.jsonObject(with: #require(requests[3].httpBody))
            as? [String: [[String: String]]]
        #expect(body?["items"] == [["uri": "spotify:track:def"]])
        await client.close()
    }

    @Test func quotaCooldownAndUnauthorizedRefreshAreBounded() async throws {
        let date = Date(timeIntervalSince1970: 10)
        StubURLProtocol.state.reset([
            .init(
                status: 429, body: #"{"error":{"message":"QUOTA_EXCEEDED"}}"#,
                headers: ["Retry-After": "7"])
        ])
        let quota = client(now: { date })
        for _ in 0..<3 {
            await #expect(
                throws: SpotifyError.rateLimited(
                    until: date.addingTimeInterval(7), quotaExceeded: true)
            ) {
                _ = try await quota.profile()
            }
        }
        #expect(StubURLProtocol.state.requests.count == 1)
        await quota.close()
        StubURLProtocol.state.reset([.init(status: 401), .init(status: 401)])
        let denied = client()
        await #expect(throws: SpotifyError.authentication) { _ = try await denied.profile() }
        let requests = StubURLProtocol.state.requests
        #expect(
            requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
                "Bearer initial", "Bearer refreshed",
            ])
        await denied.close()
    }

    @Test func maliciousPagingOriginAndCyclesAreRejected() async throws {
        StubURLProtocol.state.reset([
            .init(body: #"{"items":[],"next":"https://attacker.example/token"}"#)
        ])
        let client = client()
        await #expect(throws: SpotifyError.invalidURL) { _ = try await client.playlists() }
        #expect(StubURLProtocol.state.requests.count == 1)
        StubURLProtocol.state.reset([.init(body: #"{"items":[],"next":"me/playlists?limit=50"}"#)])
        await #expect(throws: SpotifyError.invalidResponse) { _ = try await client.playlists() }
        #expect(StubURLProtocol.state.requests.count == 1)
        await client.close()
    }

    @Test func pkceCallbackAndTokenExchange() async throws {
        let auth = try SpotifyAuthorization(clientID: String(repeating: "a", count: 32))
        let query = URLComponents(url: auth.url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(query.first { $0.name == "code_challenge" }?.value != auth.verifier)
        #expect(auth.verifier.count == 43)
        let callback = SpotifyAuthorization.redirect + "?state=" + auth.state + "&code=test"
        #expect(try auth.code(from: URL(string: callback)!) == "test")
        for invalid in [
            callback + "&code=duplicate",
            callback.replacingOccurrences(of: auth.state, with: "other"),
            callback.replacingOccurrences(of: "127.0.0.1", with: "localhost"),
        ] {
            #expect(throws: SpotifyError.authentication) {
                try auth.code(from: URL(string: invalid)!)
            }
        }
        StubURLProtocol.state.reset([
            .init(body: #"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#)
        ])
        let tokens = try await SpotifyOAuth.exchange(
            code: "test", authorization: auth, configuration: config())
        #expect(tokens.refreshToken == "refresh")
        let body = String(
            data: try #require(StubURLProtocol.state.requests.first?.httpBody), encoding: .utf8)!
        #expect(body.contains("code_verifier=" + auth.verifier))
        #expect(!body.contains("client_secret"))
        let denied = URL(
            string: SpotifyAuthorization.redirect + "?state=" + auth.state + "&error=access_denied")!
        #expect(auth.wasDenied(at: denied))
        #expect(!auth.wasDenied(at: URL(string: denied.absoluteString + "&state=other")!))
        #expect(
            !auth.wasDenied(
                at: URL(
                    string: denied.absoluteString.replacingOccurrences(
                        of: auth.state, with: "wrong"))!))
    }

    @Test func closedClientRejectsNewRequestsWithoutCreatingInvalidSessionTasks() async throws {
        StubURLProtocol.state.reset([])
        let client = client()
        await client.close()
        await #expect(throws: CancellationError.self) { _ = try await client.playback() }
        await #expect(throws: CancellationError.self) {
            try await client.pause(true, deviceID: "device")
        }
        #expect(StubURLProtocol.state.requests.isEmpty)
    }

    @Test func closeWhileRefreshingCannotSendLateRequest() async throws {
        actor Gate {
            var continuation: CheckedContinuation<String, Never>?
            func token() async -> String { await withCheckedContinuation { continuation = $0 } }
            func ready() -> Bool { continuation != nil }
            func resume() {
                continuation?.resume(returning: "synthetic")
                continuation = nil
            }
        }
        StubURLProtocol.state.reset([])
        let gate = Gate()
        let client = SpotifyClient(configuration: config()) { _ in await gate.token() }
        let task = Task { try await client.playback() }
        while await !gate.ready() { await Task.yield() }
        await client.close()
        await gate.resume()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(StubURLProtocol.state.requests.isEmpty)
    }

    private func config() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }
    private func client(now: @escaping @Sendable () -> Date = { Date() }) -> SpotifyClient {
        SpotifyClient(configuration: config(), now: now, token: { $0 ? "refreshed" : "initial" })
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int = 200
        var body: String = ""
        var headers: [String: String] = [:]
    }
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [Reply] = []
        private var recorded: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { recorded } }
        func reset(_ replies: [Reply]) {
            lock.withLock {
                responses = replies
                recorded = []
            }
        }
        func take(_ request: URLRequest) -> Reply {
            lock.withLock {
                recorded.append(request)
                return responses.isEmpty ? Reply(status: 500) : responses.removeFirst()
            }
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            captured.httpBody = data
        }
        let reply = Self.state.take(captured)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
