import Foundation
import MetaBrainzAPI
import MusicCore
import SpotifyWebAPI
import Testing

@testable import Kinrox

@Suite(.serialized)
@MainActor
struct DiscoveryServiceTests {
    let artist = MusicArtist(id: "artist", uri: "spotify:artist:artist", name: "Seed Artist")
    var seed: MusicTrack {
        MusicTrack(
            id: "seed", uri: "spotify:track:seed", title: "Seed Song", artists: [artist],
            albumID: "album", albumTitle: "Album", duration: 200)
    }
    let hydrated =
        #"{"id":"seed","uri":"spotify:track:seed","name":"Seed Song","artists":[{"id":"artist","uri":"spotify:artist:artist","name":"Seed Artist"}],"album":{"id":"album","uri":"spotify:album:album","name":"Album","artists":[]},"duration_ms":200000,"external_ids":{"isrc":"SEEDISRC"}}"#
    func makeStore(
        cache: SpotifyCacheStore? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) -> SpotifyLibraryStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiscoveryHTTPStub.self]
        let client = SpotifyClient(configuration: config) { _ in "synthetic" }
        let store = SpotifyLibraryStore(client: client, cache: cache, now: now)
        store.catalog = MusicCatalog(tracks: [seed])
        store.metaBrainzFactory = { MetaBrainzClient(version: "test", configuration: config) }
        return store
    }
    func discover(_ store: SpotifyLibraryStore) async throws -> MusicDiscoverySnapshot {
        try await store.discover(
            seedTitle: seed.title, seedTrack: seed, seedArtist: artist, mode: .sameSpirit,
            selectedGenre: nil, hideLiked: false)
    }
    @Test func consentOffMakesZeroMetaBrainzRequestsAndHydratesAlbumSeed() async throws {
        DiscoveryHTTPStub.state.reset(routes: ["GET /v1/tracks/seed": [.init(body: hydrated)]])
        let store = makeStore()
        let factory = try #require(store.metaBrainzFactory)
        var constructions = 0
        store.metaBrainzFactory = {
            constructions += 1
            return factory()
        }
        _ = try await discover(store)
        #expect(constructions == 0)
        #expect(store.listenBrainzStatus == .off)
        #expect(store.catalog.track(id: seed.id)?.isrc == "SEEDISRC")
        #expect(DiscoveryHTTPStub.state.requests.allSatisfy { $0.url?.host == "api.spotify.com" })
        #expect(
            !DiscoveryHTTPStub.state.requests.contains {
                ($0.url?.query ?? "").contains("playlist")
            })
        store.retire()
        await store.client.close()
    }
    @Test func enabledResolutionUsesHydratedISRCAndFailureStaysInline() async throws {
        DiscoveryHTTPStub.state.reset(routes: [
            "GET /v1/tracks/seed": [.init(body: hydrated)],
            "GET /ws/2/isrc/SEEDISRC": [.init(status: 500)],
        ])
        let store = makeStore()
        store.setListenBrainzEnabled(true)
        let result = try await discover(store)
        #expect(DiscoveryHTTPStub.state.requests.contains { $0.url?.path == "/ws/2/isrc/SEEDISRC" })
        #expect(store.listenBrainzStatus == .unavailable)
        #expect(result.genres.isEmpty)
        #expect(store.discoveryCache.isEmpty)
        store.retire()
        await store.client.close()
    }
    @Test func cachedCandidatesSurvivePruningRestartAndExpireAt24Hours() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "discovery-cache-\(UUID())")
        let cache = SpotifyCacheStore(
            clientID: "c", userID: "u", displayName: "Test", root: root, now: { date })
        let store = makeStore(cache: cache, now: { date })
        let candidate = MusicTrack(
            id: "remote", uri: "spotify:track:remote", title: "Remote",
            artists: [.init(id: "other", uri: "other", name: "Other")], albumID: "remoteAlbum",
            albumTitle: "Remote Album", duration: 200, isrc: "ISRC", releaseDate: "2026-11-01")
        var data = SpotifyDiscoveryData()
        data.tracks = [candidate]
        data.signals = [.init(track: candidate, kind: .collaborator, detail: "Other")]
        let key = "seed-v2|track:seed|artist:artist|0"
        try await cache.saveDiscovery(key, value: data, session: store.sessionGeneration)
        try await cache.save(
            .init(library: LibrarySnapshot(userID: "u")), revision: 1,
            session: store.sessionGeneration)
        store.pruneDisposableCatalog()
        #expect(store.catalog.track(id: candidate.id) == nil)
        DiscoveryHTTPStub.state.reset([])
        let snapshot = try await discover(store)
        #expect(snapshot.tracks == [candidate])
        #expect(DiscoveryHTTPStub.state.requests.isEmpty)
        let reopened = SpotifyCacheStore(
            clientID: "c", userID: "u", displayName: "Test", root: root, now: { date })
        #expect(try await reopened.discovery(key)?.tracks == [candidate])
        let expired = SpotifyCacheStore(
            clientID: "c", userID: "u", displayName: "Test", root: root,
            now: { date.addingTimeInterval(86400) })
        #expect(try await expired.discovery(key) == nil)
        let row = MusicPlayHistoryEntry(
            sessionID: UUID(), trackID: "remote", playedAt: date, playedSeconds: 200,
            completed: true, skipped: false)
        try await cache.recordPlay(row, session: store.sessionGeneration)
        try await cache.saveMetaBrainz(
            "test", data: Data("[]".utf8), ttl: 100, session: store.sessionGeneration)
        #expect(try await cache.playHistory() == [row])
        #expect(try await cache.metaBrainz("test") != nil)
        try await cache.destroyAccountCache()
        #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
        store.retire()
        await store.client.close()
    }
    @Test func consentRevocationRejectsInFlightResults() async throws {
        let gate = MusicResponseGate()
        DiscoveryHTTPStub.state.reset(routes: [
            "GET /v1/tracks/seed": [.init(body: hydrated)],
            "GET /ws/2/isrc/SEEDISRC": [.init(body: #"{"recordings":[]}"#, gate: gate)],
        ])
        let store = makeStore()
        store.setListenBrainzEnabled(true)
        let task = Task { try await discover(store) }
        for _ in 0..<100
        where !DiscoveryHTTPStub.state.requests.contains(where: {
            $0.url?.host == "musicbrainz.org"
        }) { try await Task.sleep(for: .milliseconds(10)) }
        store.setListenBrainzEnabled(false)
        await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(store.listenBrainzStatus == .off)
        #expect(store.discoveryCache.isEmpty)
        store.retire()
        await store.client.close()
    }
}

extension DiscoveryServiceTests {
    @Test func cacheDigestPersistsHydratedIsrcAndAlbumDate() async throws {
        let date = Date()
        let cache = SpotifyCacheStore(
            clientID: "c", userID: "u", displayName: "Test",
            root: FileManager.default.temporaryDirectory.appendingPathComponent(
                "discovery-digest-\(UUID())"))
        var value = SpotifyCachedLibrary(
            library: LibrarySnapshot(userID: "u", likedTrackIDs: [seed.id]),
            catalog: MusicCatalog(tracks: [seed]))
        value.resources["liked"] = .init(fetchedAt: date, expiresAt: date.addingTimeInterval(300))
        try await cache.save(value, revision: 1)
        let track = try #require(
            JSONDecoder().decode(SpotifyTrack.self, from: Data(hydrated.utf8)).model())
        let album = MusicAlbum(
            id: seed.albumID, uri: "album", title: "Album", artists: [artist], year: "2026",
            trackIDs: [], releaseDate: "2026-11-01")
        value.catalog.merge(tracks: [track], albums: [album])
        try await cache.save(value, revision: 2)
        let restored = try await cache.restore()
        #expect(restored.catalog.track(id: seed.id)?.isrc == "SEEDISRC")
        #expect(restored.catalog.track(id: seed.id)?.releaseDate == "2026-11-01")
        #expect(restored.catalog.album(id: seed.albumID)?.releaseDate == "2026-11-01")
    }
}

extension DiscoveryServiceTests {
    @Test func listenBrainzMappingAndArtistSearchHaveBoundedSpotifyBudget() async throws {
        func json(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        let recordings = (0..<20).map {
            [
                "recording_mbid": "r\($0)", "recording_name": "Song \($0)",
                "artist_credit_name": "Recording Artist \($0)", "score": 20 - $0,
            ] as [String: Any]
        }
        let artists = (0..<15).map {
            ["artist_mbid": "a\($0)", "name": "Other \($0)", "score": 15 - $0] as [String: Any]
        }
        let mappings = (0..<20).map {
            ["recording_mbid": "r\($0)", "spotify_track_ids": ["mapped\($0)"]] as [String: Any]
        }
        var routes: [String: [DiscoveryHTTPStub.Reply]] = [
            "GET /v1/tracks/seed": [.init(body: hydrated)],
            "GET /v1/artists/artist": [
                .init(
                    body:
                        #"{"id":"artist","uri":"spotify:artist:artist","name":"Seed Artist","genres":["ambient"]}"#
                )
            ],
            "GET /ws/2/isrc/SEEDISRC": [
                .init(
                    body:
                        #"{"recordings":[{"id":"seedRecording","artist-credit":[{"artist":{"id":"seedArtist","name":"Seed Artist"}}]}]}"#
                )
            ],
            "GET /similar-recordings/json": [.init(body: try json(recordings))],
            "GET /similar-artists/json": [.init(body: try json(artists))],
            "POST /spotify-id-from-mbid/json": [.init(body: try json(mappings))],
            "GET /v1/search": Array(repeating: .init(body: #"{"tracks":{"items":[]}}"#), count: 7),
        ]
        for index in 0..<8 {
            routes["GET /v1/tracks/mapped\(index)"] = [
                .init(
                    body: try json([
                        "id": "mapped\(index)", "uri": "spotify:track:mapped\(index)",
                        "name": "Mapped \(index)",
                        "duration_ms": 200000,
                        "artists": [
                            [
                                "id": "recordingArtist\(index)", "uri": "artist\(index)",
                                "name": "Recording Artist \(index)",
                            ]
                        ],
                        "album": [
                            "id": "album\(index)", "uri": "album\(index)", "name": "Album",
                            "artists": [],
                        ],
                    ]))
            ]
        }
        DiscoveryHTTPStub.state.reset(routes: routes)
        let store = makeStore()
        store.setListenBrainzEnabled(true)
        let snapshot = try await discover(store)
        let requests = DiscoveryHTTPStub.state.requests
        #expect(requests.filter { $0.url?.path.hasPrefix("/v1/tracks/mapped") == true }.count == 8)
        let artistQueries = requests.filter {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains {
                $0.name == "q" && $0.value?.hasPrefix("artist:\"Other") == true
            } == true
        }
        #expect(artistQueries.count == 5)
        #expect(!requests.contains { $0.url?.path == "/ws/2/artist/seedArtist" })
        #expect(snapshot.genreSource == .spotify)
        #expect(snapshot.genres == ["ambient"])
        #expect(snapshot.tracks.count == 8)
        #expect(store.listenBrainzStatus == .ready)
        let count = requests.count
        _ = try await discover(store)
        #expect(DiscoveryHTTPStub.state.requests.count == count)
        store.retire()
        await store.client.close()
    }
}

extension DiscoveryServiceTests {
    @Test func musicBrainzGenresAreUsedOnlyWhenSpotifyHasNone() async throws {
        DiscoveryHTTPStub.state.reset(routes: [
            "GET /v1/tracks/seed": [.init(body: hydrated)],
            "GET /ws/2/isrc/SEEDISRC": [
                .init(
                    body:
                        #"{"recordings":[{"id":"recording","artist-credit":[{"artist":{"id":"mbArtist","name":"Seed Artist"}}]}]}"#
                )
            ],
            "GET /ws/2/artist/mbArtist": [
                .init(body: #"{"genres":[{"name":"ambient","count":9}]}"#)
            ],
            "GET /similar-artists/json": [.init(body: "[]")],
            "GET /similar-recordings/json": [.init(body: "[]")],
        ])
        let store = makeStore()
        store.setListenBrainzEnabled(true)
        let snapshot = try await discover(store)
        #expect(snapshot.genres == ["ambient"])
        #expect(snapshot.genreSource == .musicBrainz)
        store.setListenBrainzEnabled(false)
        let off = try await discover(store)
        #expect(off.genreSource == .none)
        #expect(off.genres.isEmpty)
        store.retire()
        await store.client.close()
    }
}

extension DiscoveryServiceTests {
    @Test func collaboratorSearchKeepsFullAlbumMetadataInSeedCache() async throws {
        let joint =
            #"{"tracks":{"items":[{"id":"joint","uri":"spotify:track:joint","name":"Joint","artists":[{"id":"artist","uri":"artist","name":"Seed Artist"},{"id":"partner","uri":"partner","name":"Partner"}],"duration_ms":200000,"album":{"id":"jointAlbum","uri":"jointAlbum","name":"Joint Album","artists":[]}}]}}"#
        let other =
            #"{"tracks":{"items":[{"id":"other","uri":"spotify:track:other","name":"Other","artists":[{"id":"partner","uri":"partner","name":"Partner"}],"duration_ms":200000,"album":{"id":"partnerAlbum","uri":"partnerAlbum","name":"Partner Album","release_date":"2026-10-01","total_tracks":12,"artists":[{"id":"partner","uri":"partner","name":"Partner"}]}}]}}"#
        DiscoveryHTTPStub.state.reset(routes: [
            "GET /v1/tracks/seed": [.init(body: hydrated)],
            "GET /v1/search": [.init(body: joint), .init(body: other)],
        ])
        let store = makeStore()
        let snapshot = try await discover(store)
        #expect(snapshot.tracks.contains { $0.id == "other" })
        #expect(store.catalog.album(id: "partnerAlbum")?.totalTrackCount == 12)
        let data = try #require(store.discoveryCache.values.first?.value)
        #expect(data.albums.first { $0.id == "partnerAlbum" }?.releaseDate == "2026-10-01")
        store.catalog = MusicCatalog(tracks: [seed])
        _ = try await discover(store)
        #expect(store.catalog.album(id: "partnerAlbum")?.totalTrackCount == 12)
        store.retire()
        await store.client.close()
    }
}
