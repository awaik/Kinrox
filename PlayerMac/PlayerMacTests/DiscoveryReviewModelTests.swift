import Foundation
import MusicCore
import Testing

@testable import Kinrox

extension DiscoveryServiceTests {
    @Test func missingConsentPreferenceEnablesSimilarityAndSurvivesSynchronization() async throws {
        DiscoveryHTTPStub.state.reset(routes: ["GET /v1/tracks/seed": [.init(body: hydrated)]])
        let defaults = try preferences()
        let store = makeStore()
        let model = MusicViewModel(store: store, defaults: defaults)
        #expect(defaults.object(forKey: ListenBrainzPreference.key) == nil)
        #expect(model.listenBrainzEnabled)
        #expect(store.listenBrainzEnabled)
        #expect(!model.synchronizeDiscoveryConsent())
        model.openSimilar(forTrack: seed)
        await model.browsingTask?.value
        #expect(model.listenBrainzEnabled)
        #expect(DiscoveryHTTPStub.state.requests.contains { $0.url?.host == "musicbrainz.org" })
        store.retire()
        await store.client.close()
    }

    @Test(arguments: [false, true])
    func explicitOptOutAndAbsentDefaultsMakeZeroMetaBrainzRequests(useDefaults: Bool) async throws {
        DiscoveryHTTPStub.state.reset(routes: ["GET /v1/tracks/seed": [.init(body: hydrated)]])
        let defaults = try useDefaults ? preferences() : nil
        defaults?.set(false, forKey: ListenBrainzPreference.key)
        let store = makeStore()
        let model = MusicViewModel(store: store, defaults: defaults)
        #expect(!model.listenBrainzEnabled)
        #expect(!store.listenBrainzEnabled)
        model.openSimilar(forTrack: seed)
        await model.browsingTask?.value
        #expect(model.listenBrainzStatus == .off)
        #expect(store.metaBrainzClient == nil)
        #expect(!DiscoveryHTTPStub.state.requests.isEmpty)
        #expect(DiscoveryHTTPStub.state.requests.allSatisfy { $0.url?.host == "api.spotify.com" })
        store.retire()
        await store.client.close()
    }

    @Test func removingStoredOptOutRestoresDefaultOn() async throws {
        let defaults = try preferences()
        defaults.set(false, forKey: ListenBrainzPreference.key)
        let store = makeStore()
        let model = MusicViewModel(store: store, defaults: defaults)
        #expect(!model.listenBrainzEnabled)
        defaults.removeObject(forKey: ListenBrainzPreference.key)
        #expect(model.synchronizeDiscoveryConsent())
        #expect(model.listenBrainzEnabled)
        #expect(store.listenBrainzEnabled)
        store.retire()
        await store.client.close()
    }

    @Test(arguments: [nil, false, true] as [Bool?])
    func reconnectReappliesSimilarityPreference(stored: Bool?) async throws {
        DiscoveryHTTPStub.state.reset([])
        let defaults = try preferences()
        if let stored { defaults.set(stored, forKey: ListenBrainzPreference.key) }
        let store = makeStore()
        let model = MusicViewModel(store: store, defaults: defaults)
        let enabled = stored ?? true
        #expect(store.listenBrainzEnabled == enabled)
        store.retire()
        model.replaceStore(DisconnectedMusicLibraryStore())
        #expect(!store.listenBrainzEnabled)
        #expect(model.listenBrainzEnabled == enabled)
        #expect(DiscoveryHTTPStub.state.requests.isEmpty)
        let reconnected = makeStore()
        model.replaceStore(reconnected)
        #expect(model.listenBrainzEnabled == enabled)
        #expect(reconnected.listenBrainzEnabled == enabled)
        model.openSimilar(forTrack: seed)
        await model.browsingTask?.value
        #expect(
            DiscoveryHTTPStub.state.requests.contains { $0.url?.host == "musicbrainz.org" }
                == enabled)
        reconnected.retire()
        await store.client.close()
        await reconnected.client.close()
    }

    @Test func disconnectAndReconnectClearUnavailableSimilarityStatus() async throws {
        DiscoveryHTTPStub.state.reset(routes: [
            "GET /v1/tracks/seed": [.init(body: hydrated)],
            "GET /ws/2/isrc/SEEDISRC": [.init(status: 500)],
        ])
        let defaults = try preferences()
        let store = makeStore()
        let model = MusicViewModel(store: store, defaults: defaults)
        model.openSimilar(forTrack: seed)
        await model.browsingTask?.value
        #expect(model.listenBrainzStatus == .unavailable)
        #expect(store.listenBrainzStatus == .unavailable)
        model.select(.queue)
        let requestCount = DiscoveryHTTPStub.state.requests.count

        store.retire()
        model.replaceStore(DisconnectedMusicLibraryStore())
        #expect(model.listenBrainzEnabled)
        #expect(model.listenBrainzStatus == .ready)

        let reconnected = makeStore()
        model.replaceStore(reconnected)
        #expect(model.listenBrainzStatus == .ready)
        #expect(reconnected.listenBrainzStatus == .ready)
        #expect(DiscoveryHTTPStub.state.requests.count == requestCount)
        reconnected.retire()
        await store.client.close()
        await reconnected.client.close()
    }

    @Test(arguments: [false, true])
    func replaceStoreSynchronizesConsentBeforeDefaultsObservation(enabled: Bool) async throws {
        DiscoveryHTTPStub.state.reset([])
        let defaults = try preferences()
        defaults.set(!enabled, forKey: ListenBrainzPreference.key)
        let store = makeStore()
        let model = MusicViewModel(store: store, defaults: defaults)

        // Do not yield between changing the preference and replacing either store.
        defaults.set(enabled, forKey: ListenBrainzPreference.key)
        store.retire()
        model.replaceStore(DisconnectedMusicLibraryStore())
        #expect(model.listenBrainzEnabled == enabled)
        #expect(model.listenBrainzStatus == (enabled ? .ready : .off))

        defaults.set(!enabled, forKey: ListenBrainzPreference.key)
        let reconnected = makeStore()
        model.replaceStore(reconnected)
        #expect(model.listenBrainzEnabled == !enabled)
        #expect(model.listenBrainzStatus == (enabled ? .off : .ready))
        #expect(reconnected.listenBrainzEnabled == !enabled)
        #expect(reconnected.listenBrainzStatus == (enabled ? .off : .ready))
        #expect(DiscoveryHTTPStub.state.requests.isEmpty)
        reconnected.retire()
        await store.client.close()
        await reconnected.client.close()
    }

    @Test func defaultsObservationDoesNotRetainModel() async throws {
        let defaults = try preferences()
        weak var released: MusicViewModel?
        do {
            let model = MusicViewModel(defaults: defaults)
            released = model
        }
        #expect(released == nil)
        defaults.set(true, forKey: ListenBrainzPreference.key)
        await Task.yield()
        #expect(released == nil)
    }

    @Test(arguments: ["album", "playlist", "restricted"])
    func unloadedCollectionsLoadTheirTracksBeforeDiscovery(kind: String) async throws {
        let remote = trackJSON("collectionTrack")
        let playlistJSON =
            #"{"id":"collection","uri":"playlist","name":"Chosen playlist","owner":{"id":"u"},"snapshot_id":"s"}"#
        DiscoveryHTTPStub.state.reset(routes: [
            "GET /v1/albums/collection": [
                .init(
                    body:
                        #"{"id":"collection","uri":"album","name":"Chosen album","artists":[],"tracks":{"items":[\#(remote)]}}"#
                )
            ],
            "GET /v1/playlists/collection": Array(repeating: .init(body: playlistJSON), count: 2),
            "GET /v1/playlists/collection/items": [
                .init(
                    status: kind == "restricted" ? 403 : 200,
                    body: "{\"items\":[{\"item\":\(remote)}]}")
            ],
        ])
        let store = makeStore()
        let model = MusicViewModel(store: store)
        model.queue.start([seed])
        if kind == "album" {
            model.openSimilar(
                album: .init(
                    id: "collection", uri: "album", title: "Chosen album", artists: [],
                    year: "2026", trackIDs: []))
        } else {
            model.openSimilar(
                playlist: .init(
                    id: "collection", uri: "playlist", title: "Chosen playlist", ownerID: "u"))
        }
        await model.browsingTask?.value
        #expect(
            model.discoverySnapshot?.seed.title
                == (kind == "album" ? "Chosen album" : "Chosen playlist"))
        #expect(
            model.discoverySnapshot?.seed.trackID
                == (kind == "restricted" ? nil : "collectionTrack"))
        #expect(model.statusMessage == nil)
        #expect(!DiscoveryHTTPStub.state.requests.contains { $0.url?.path == "/v1/tracks/seed" })
        if kind != "restricted" {
            let requests = DiscoveryHTTPStub.state.requests
            let load = try #require(
                requests.firstIndex {
                    $0.url?.path.hasPrefix(kind == "album" ? "/v1/albums/" : "/v1/playlists/")
                        == true
                })
            let discovery = try #require(
                requests.firstIndex { $0.url?.path == "/v1/tracks/collectionTrack" })
            #expect(load < discovery)
        }
        store.retire()
        await store.client.close()
    }

    @Test func disabledMetaBrainzRemovesUnavailableSelectedGenre() async throws {
        DiscoveryHTTPStub.state.reset(routes: [
            "GET /v1/tracks/seed": [.init(body: hydrated)],
            "GET /ws/2/isrc/SEEDISRC": [.init(body: resolutionJSON)],
            "GET /ws/2/artist/mbArtist": [
                .init(body: #"{"genres":[{"name":"ambient","count":5}]}"#)
            ],
            "GET /similar-artists/json": [.init(body: "[]")],
            "GET /similar-recordings/json": [.init(body: "[]")],
        ])
        let store = makeStore()
        let model = MusicViewModel(store: store)
        model.listenBrainzEnabled = true
        model.openSimilar(forTrack: seed)
        await model.browsingTask?.value
        model.setDiscoveryGenre("ambient")
        await model.browsingTask?.value
        #expect(model.discoverySelectedGenre == "ambient")
        model.listenBrainzEnabled = false
        #expect(model.discoverySelectedGenre == nil)
        await model.browsingTask?.value
        #expect(model.discoverySnapshot?.selectedGenre == nil)
        #expect(model.discoverySnapshot?.genres.isEmpty == true)
        store.retire()
        await store.client.close()
    }

    func preferences() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "DiscoveryReview-\(UUID())"))
    }

    @Test func restoresSimilarLocallyThenDiscoversWhenConnected() async throws {
        DiscoveryHTTPStub.state.reset([])
        let defaults = try preferences()
        defaults.set(
            try JSONEncoder().encode(BrowserSelection(source: .similar)),
            forKey: "app.kinrox.music.selection")
        let store = makeStore()
        store.isConnected = false
        let model = MusicViewModel(store: store, defaults: defaults)
        #expect(model.selection.source == .similar)
        #expect(model.discoverySnapshot != nil)
        await model.browsingTask?.value
        #expect(DiscoveryHTTPStub.state.requests.isEmpty)
        #expect(model.statusMessage == nil)
        model.queue.start([seed])
        store.isConnected = true
        model.acceptLibrary(store)
        await model.browsingTask?.value
        #expect(!DiscoveryHTTPStub.state.requests.isEmpty)
        let replacement = makeStore()
        model.replaceStore(replacement)
        #expect(model.discoverySnapshot != nil)
        await model.browsingTask?.value
        store.retire()
        replacement.retire()
        await store.client.close()
        await replacement.client.close()
    }

    @Test func storedConsentRevocationAppliesOutsideDiscoveryAndBeforeRadioRefill() async throws {
        DiscoveryHTTPStub.state.reset([])
        let defaults = try preferences()
        defaults.set(true, forKey: ListenBrainzPreference.key)
        let store = makeStore()
        let model = MusicViewModel(store: store, defaults: defaults)
        model.queue.start([seed])
        model.isDiscoveryRadioActive = true
        model.select(.queue)
        defaults.set(false, forKey: ListenBrainzPreference.key)
        // Refill must be safe even before the defaults observer gets a main-actor turn.
        model.refillDiscoveryRadioIfNeeded()
        await model.radioRefillTask?.value
        #expect(!model.listenBrainzEnabled)
        #expect(!store.listenBrainzEnabled)
        #expect(DiscoveryHTTPStub.state.requests.allSatisfy { $0.url?.host == "api.spotify.com" })
        defaults.set(true, forKey: ListenBrainzPreference.key)
        for _ in 0..<100 where !model.listenBrainzEnabled {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.listenBrainzEnabled)
        #expect(store.listenBrainzEnabled)
        model.stopDiscoveryRadio()
        store.retire()
        await store.client.close()
    }

    @Test func explicitArtistAndUnavailablePlaylistNeverUseCurrentTrack() throws {
        let model = MusicViewModel()
        let artist = try #require(
            model.catalog.artists.first { $0.id != model.currentTrack?.artists.first?.id })
        model.openSimilar(artist: artist)
        #expect(model.discoverySnapshot?.seed.trackID == nil)
        #expect(model.discoverySnapshot?.seed.artistID == artist.id)
        #expect(model.discoverySnapshot?.seed.title == artist.name)
        let playlist = MusicPlaylist(
            id: "unavailable", uri: "playlist", title: "Chosen playlist", ownerID: "u",
            itemsAvailable: false)
        model.openSimilar(playlist: playlist)
        #expect(model.discoverySnapshot?.seed.trackID == nil)
        #expect(model.discoverySnapshot?.seed.title == playlist.title)
    }

    @Test func disconnectClearsNegativeFeedbackAndUndo() throws {
        let defaults = try preferences()
        let model = MusicViewModel(defaults: defaults)
        let track = try #require(model.catalog.tracks.first)
        model.notInterested(track: track)
        model.notInterested(artist: track.artists[0])
        model.replaceStore(DisconnectedMusicLibraryStore())
        #expect(model.notInterestedTrackIDs.isEmpty)
        #expect(model.notInterestedArtistIDs.isEmpty)
        #expect(!model.canUndoNotInterested)
        #expect(defaults.object(forKey: "app.kinrox.music.notInterestedTracks") == nil)
        #expect(defaults.object(forKey: "app.kinrox.music.notInterestedArtists") == nil)
    }
}
