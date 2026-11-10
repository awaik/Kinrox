import Foundation
import Testing

@testable import MetaBrainzAPI

@Suite(.serialized)
struct MetaBrainzClientTests {
    @Test func recordingSearchCancellationDoesNotContinueResolution() async {
        MetaStub.state.reset([(-999, "")])
        let client = client()
        await #expect(throws: CancellationError.self) {
            _ = try await client.resolve(
                trackID: "seed", isrc: nil, title: "Song", artistID: "a", artistName: "Seed",
                needsGenres: true)
        }
        #expect(MetaStub.state.requests.count == 1)
        await client.close()
    }
    @Test(arguments: [500, 200]) func recordingSearchFailureStillResolvesArtistAndGenres(
        status: Int
    )
        async throws
    {
        MetaStub.state.reset([
            (status, "{\"new_schema\":true}"),
            (200, #"{"artists":[{"id":"artist","name":"Seed"}]}"#),
            (200, #"{"genres":[{"name":"ambient","count":5}]}"#),
        ])
        let client = client()
        let result = try await client.resolve(
            trackID: "seed", isrc: nil, title: "Song", artistID: "a", artistName: "Seed",
            needsGenres: true)
        #expect(result.recordingMBID == nil)
        #expect(result.artists.first?.id == "artist")
        #expect(result.genres == ["ambient"])
        await client.close()
    }

    func client() -> MetaBrainzClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MetaStub.self]
        let clock = RateLimiterTests.Clock()
        return MetaBrainzClient(
            version: "test", configuration: config,
            limiter: MusicBrainzRateLimiter(now: { clock.now() }, sleep: { clock.sleep($0) }),
            sleep: { clock.sleep($0) })
    }
    @Test func decodesResolutionGenresSimilarityMappingAndCaches() async throws {
        MetaStub.state.reset([
            (
                200,
                #"{"recordings":[{"id":"rec","artist-credit":[{"artist":{"id":"artist","name":"Seed"}}]}]}"#
            ),
            (200, #"{"genres":[{"name":"techno","count":2},{"name":"ambient","count":5}]}"#),
            (200, #"[{"artist_mbid":"other","name":"Other","score":10}]"#),
            (
                200,
                #"[{"recording_mbid":"r2","recording_name":"Track","artist_credit_name":"Other","score":5}]"#
            ),
            (200, #"[{"recording_mbid":"r2","spotify_track_ids":["spotifyID"]}]"#),
        ])
        let client = client()
        let resolved = try await client.resolve(
            trackID: "s", isrc: "ISRC", title: "Song", artistID: "a", artistName: "Seed",
            needsGenres: true)
        #expect(resolved.recordingMBID == "rec")
        #expect(resolved.genres == ["ambient", "techno"])
        #expect(try await client.similarArtists("artist").first?.name == "Other")
        #expect(try await client.similarRecordings("rec").first?.recordingMBID == "r2")
        #expect(try await client.spotifyIDs(["r2"]).first?.spotifyTrackIDs == ["spotifyID"])
        _ = try await client.resolve(
            trackID: "s", isrc: "ISRC", title: "Song", artistID: "a", artistName: "Seed",
            needsGenres: true)
        _ = try await client.similarArtists("artist")
        #expect(MetaStub.state.requests.count == 5)
        #expect(
            MetaStub.state.requests.allSatisfy {
                $0.url?.scheme == "https" && $0.value(forHTTPHeaderField: "Cookie") == nil
            })
        #expect(
            MetaStub.state.requests.first?.value(forHTTPHeaderField: "User-Agent")
                == "Kinrox/test ( https://kinrox.app )")
        await client.close()
    }
    @Test func unknownISRCFallsBackToExactNamesAndRejectsUnrelatedSearch() async throws {
        MetaStub.state.reset([
            (404, ""),
            (
                200,
                #"[{"recording_mbid":"wrong","recording_name":"Song","artist_credit_name":"Unrelated"},{"recording_mbid":"right","recording_name":"Song","artist_credit_name":"Sèed"}]"#
            ),
            (
                200,
                #"{"artists":[{"id":"wrong","name":"Seeding"},{"id":"rightArtist","name":"Seed"}]}"#
            ),
        ])
        let client = client()
        let result = try await client.resolve(
            trackID: "seed", isrc: "UNKNOWN", title: "Song", artistID: "a", artistName: "Seed",
            needsGenres: false)
        #expect(result.recordingMBID == "right")
        #expect(result.artists.first?.id == "rightArtist")
        await client.close()
    }
    @Test func retriesMusicBrainz503OnceAndCapsRetryDelay() async throws {
        MetaStub.state.reset([(503, ""), (200, #"{"artists":[]}"#)])
        let client = client()
        let result = try await client.resolve(
            trackID: nil, isrc: nil, title: "", artistID: "a", artistName: "Seed",
            needsGenres: false)
        #expect(result.artists.isEmpty)
        #expect(MetaStub.state.requests.count == 2)
        #expect(MetaBrainzClient.retryDelay("90", now: Date()) == 5)
        await client.close()
    }
    @Test func unmatchedRecordingMappingIsAnEmptyResult() throws {
        let data = Data(#"[{"recording_mbid":"unknown","spotify_track_ids":null}]"#.utf8)
        #expect(
            try JSONDecoder().decode([MetaBrainzSpotifyMapping].self, from: data).first?
                .spotifyTrackIDs == [])
    }
    @Test func experimentalSchemaChangeIsAnErrorNotFabricatedResults() async {
        MetaStub.state.reset([(200, #"{"new_schema":true}"#)])
        let client = client()
        await #expect(throws: (any Error).self) { _ = try await client.similarArtists("a") }
        await client.close()
    }
}

private final class MetaStub: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var replies: [(Int, String)] = []
        var recorded: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { recorded } }
        func reset(_ replies: [(Int, String)]) {
            lock.withLock {
                self.replies = replies
                recorded = []
            }
        }
        func take(_ request: URLRequest) -> (Int, String) {
            lock.withLock {
                recorded.append(request)
                return replies.isEmpty ? (500, "") : replies.removeFirst()
            }
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.take(request)
        if reply.0 == -999 {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.0, httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
