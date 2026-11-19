import Foundation
import MetaBrainzAPI
import Testing
import os

@testable import Kinrox

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct OpenVideoMetadataClientTests {
    @Test func encodesSearchAndValidatesIDBeforeFetchingExactMovie() async throws {
        MetadataURLProtocol.state.withLock { $0 = .init() }
        let client = makeClient()
        let result = try #require(
            try await client.lookup(VideoTitle(title: "A/B? C # %", year: 2020)))
        #expect(result.title == "A/B? C # %")
        #expect(result.rating == 8.4)
        #expect(result.genres == ["Mystery"])
        #expect(result.source == .imdb)
        let urls = MetadataURLProtocol.state.withLock { $0.requests }
        #expect(urls.count == 2)
        #expect(urls.first?.absoluteString.contains("A%2FB%3F%20C%20%23%20%25.json") == true)
        #expect(urls.last?.path == "/meta/movie/tt1234567.json")
        #expect(OpenVideoMetadataClient.searchURL(title: "../movie", series: false) == nil)
    }

    @Test func seriesFallsBackToTVMazeAndExtractsPlainText() async throws {
        MetadataURLProtocol.state.withLock { $0 = .init() }
        let result = try #require(
            try await makeClient().lookup(VideoTitle(title: "Rain", season: 1)))
        #expect(result.source == .tvmaze)
        #expect(result.summary == "An example & a storm.")
        #expect(result.episodes.first?.title == "Pilot")
    }

    @Test func disablingLiveConsentCancelsRequestAndPreventsNewRequests() async throws {
        MetadataURLProtocol.state.withLock { $0 = .init(hold: true) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KinroxMetadata-\(UUID())")
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer {
            defaults.removePersistentDomain(forName: root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }
        let store = MediaLibraryStore(
            limiter: MusicBrainzRateLimiter(), defaults: defaults, storage: (root, root),
            videoClient: makeClient())
        store.snapshot.files = [file(titled: "Example", in: root)]
        store.scheduleEnrichment(refresh: false)
        #expect(
            try await eventually { MetadataURLProtocol.state.withLock { $0.requests.count == 1 } })
        store.setEnrichMetadata(false)
        #expect(store.enrichmentTask == nil)
        #expect(try await eventually { MetadataURLProtocol.state.withLock { $0.cancelled == 1 } })
        store.snapshot.files.append(file(titled: "Other", in: root))
        store.scheduleEnrichment(refresh: true)
        #expect(store.enrichmentTask == nil)
        #expect(MetadataURLProtocol.state.withLock { $0.requests.count } == 1)
    }

    @Test func negativeResultsAreCachedAndManualRefreshCanRetry() async throws {
        MetadataURLProtocol.state.withLock { $0 = .init() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KinroxMetadata-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaLibraryStore(
            limiter: MusicBrainzRateLimiter(), storage: (root, root), videoClient: makeClient())
        let media = file(titled: "Missing", in: root)
        let key = try #require(media.metadataKey)
        store.snapshot.files = [media]
        store.scheduleEnrichment(refresh: false)
        await store.enrichmentTask?.value
        #expect(store.snapshot.metadata[key]?.notFound == true)
        store.scheduleEnrichment(refresh: false)
        #expect(store.enrichmentTask == nil)
        #expect(MetadataURLProtocol.state.withLock { $0.requests.count } == 1)
        store.scheduleEnrichment(refresh: true)
        await store.enrichmentTask?.value
        #expect(MetadataURLProtocol.state.withLock { $0.requests.count } == 2)
    }

    @Test func malformedMetadataDoesNotCreateAFabricatedMatch() async {
        MetadataURLProtocol.state.withLock { $0 = .init() }
        await #expect(throws: DecodingError.self) {
            _ = try await makeClient().lookup(VideoTitle(title: "Malformed"))
        }
        #expect(MetadataURLProtocol.state.withLock { $0.requests.count } == 1)
    }

    private func file(titled title: String, in root: URL) -> MediaLibraryFile {
        MediaLibraryFile(
            path: root.appendingPathComponent(title + ".mkv").path, size: 1, modified: Date(),
            added: Date(), video: VideoTitle(title: title))
    }

    private func makeClient() -> OpenVideoMetadataClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MetadataURLProtocol.self]
        return OpenVideoMetadataClient(configuration: config)
    }

    private func eventually(_ ready: () -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if ready() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return ready()
    }
}

private final class MetadataURLProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var hold = false
        var requests: [URL] = []
        var cancelled = 0
    }

    static let state = OSAllocatedUnfairLock(initialState: State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let hold = Self.state.withLock { state in
            state.requests.append(url)
            return state.hold
        }
        if hold { return }
        let response =
            switch url.path {
            case let path
            where path.hasPrefix("/catalog/movie/") && url.absoluteString.contains("%2F"):
                #"{"metas":[{"imdb_id":"tt1234567/extra","name":"A/B? C # %"},{"imdb_id":"tt1234567","name":"A/B? C # %","releaseInfo":"2020"}]}"#
            case "/catalog/movie/top/search=Malformed.json":
                "{"
            case "/meta/movie/tt1234567.json":
                #"{"meta":{"name":"A/B? C # %","imdbRating":"8.4","year":2020,"genre":["Mystery"]}}"#
            case "/singlesearch/shows":
                #"{"name":"Rain","rating":{"average":8.7},"summary":"<p>An <b>example</b> &amp; a storm.</p>","_embedded":{"episodes":[{"season":1,"number":1,"name":"Pilot"}]}}"#
            default:
                #"{"metas":[]}"#
            }
        let http = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { Self.state.withLock { $0.cancelled += 1 } }
}
