import Foundation
import MusicCore
import SpotifyWebAPI
import Testing

@testable import Kinrox

extension DiscoveryServiceTests {
    @Test func remoteRemixerMatchingRequiresCreditInsteadOfTitleSubstring() throws {
        let base = trackJSON("Before the Dawn")
        let unrelated = try #require(
            JSONDecoder().decode(SpotifyTrack.self, from: Data(base.utf8)).model())
        #expect(!SpotifyLibraryStore.discoveryArtistMatches(unrelated, name: "Dawn", remixer: true))
        let remix = base.replacingOccurrences(of: "Before the Dawn", with: "Song (Dawn Remix)")
        let credited = try #require(
            JSONDecoder().decode(SpotifyTrack.self, from: Data(remix.utf8)).model())
        #expect(SpotifyLibraryStore.discoveryArtistMatches(credited, name: "Dawn", remixer: true))
    }
    func trackJSON(_ id: String, name: String = "Other", artistID: String = "other") -> String {
        #"{"id":"\#(id)","uri":"spotify:track:\#(id)","name":"\#(id)","artists":[{"id":"\#(artistID)","uri":"spotify:artist:\#(artistID)","name":"\#(name)"}],"album":{"id":"otherAlbum","uri":"album","name":"Other Album","artists":[]},"duration_ms":200000}"#
    }

    var resolutionJSON: String {
        #"{"recordings":[{"id":"recording","artist-credit":[{"artist":{"id":"mbArtist","name":"Seed Artist"}}]}]}"#
    }

    @Test(arguments: ["recordings", "mapping", "artists", "genresOnly"])
    func metaBrainzFailuresPreserveIndependentSignals(failure: String) async throws {
        let other = trackJSON("other")
        DiscoveryHTTPStub.state.reset(routes: [
            "GET /ws/2/isrc/SEEDISRC": [.init(body: resolutionJSON)],
            "GET /ws/2/artist/mbArtist": [
                .init(body: #"{"genres":[{"name":"ambient","count":5}]}"#)
            ],
            "GET /similar-recordings/json": [
                .init(
                    status: ["recordings", "genresOnly"].contains(failure) ? 500 : 200,
                    body:
                        #"[{"recording_mbid":"otherRecording","recording_name":"other","artist_credit_name":"Other","score":10}]"#
                )
            ],
            "POST /spotify-id-from-mbid/json": [
                .init(
                    status: failure == "mapping" ? 500 : 200,
                    body: #"[{"recording_mbid":"otherRecording","spotify_track_ids":["other"]}]"#)
            ],
            "GET /similar-artists/json": [
                .init(
                    status: ["artists", "genresOnly"].contains(failure) ? 500 : 200,
                    body: #"[{"artist_mbid":"otherArtist","name":"Other","score":10}]"#)
            ],
            "GET /v1/search": [.init(body: "{\"tracks\":{\"items\":[\(other)]}}")],
        ])
        let store = makeStore()
        store.setListenBrainzEnabled(true)
        let seed = try #require(
            JSONDecoder().decode(SpotifyTrack.self, from: Data(hydrated.utf8)).model())
        let candidate = try #require(
            JSONDecoder().decode(SpotifyTrack.self, from: Data(other.utf8)).model())
        store.catalog.merge(tracks: [candidate])
        var data = SpotifyDiscoveryData()
        if failure != "genresOnly" { data.genres = ["spotify genre"] }
        try await store.addListenBrainzSignals(
            to: &data, seedTrack: seed, artist: artist,
            session: store.sessionGeneration, consent: store.consentGeneration)
        #expect(data.listenBrainzStatus == .ready)
        if failure == "genresOnly" {
            #expect(data.genreSource == .musicBrainz)
            #expect(data.genres == ["ambient"])
        } else {
            let expected: MusicDiscoveryReasonKind =
                failure == "artists" ? .listenBrainzRecording : .listenBrainzArtist
            #expect(data.signals.contains { $0.track.id == "other" && $0.reason.kind == expected })
        }
        store.retire()
        await store.client.close()
    }

    @Test func modesGenresAndFeedbackReuseSeedSignalsWithoutBlankingSections() async throws {
        let other = trackJSON("other")
        let genreTrack = trackJSON("genreTrack", name: "Genre Artist", artistID: "genreArtist")
        let joint = trackJSON("joint", name: "Seed Artist", artistID: "artist")
            .replacingOccurrences(
                of: "}],\"album\"",
                with: "},{\"id\":\"other\",\"uri\":\"other\",\"name\":\"Other\"}],\"album\"")
        DiscoveryHTTPStub.state.reset(routes: [
            "GET /v1/tracks/seed": [.init(body: hydrated)],
            "GET /v1/artists/artist": [
                .init(
                    body:
                        #"{"id":"artist","uri":"artist","name":"Seed Artist","genres":["ambient","techno"]}"#
                )
            ],
            "GET /v1/search artist:\"Seed Artist\"": [
                .init(body: "{\"tracks\":{\"items\":[\(joint)]}}")
            ],
            "GET /v1/search artist:\"Other\"": [.init(body: "{\"tracks\":{\"items\":[\(other)]}}")],
            "GET /v1/search genre:\"ambient\"": [
                .init(body: "{\"tracks\":{\"items\":[\(genreTrack)]}}")
            ],
            "GET /v1/search": Array(
                repeating: .init(body: #"{"tracks":{"items":[]},"albums":{"items":[]}}"#), count: 8),
        ])
        let store = makeStore()
        let model = MusicViewModel(store: store)
        model.openSimilar(forTrack: seed)
        await model.browsingTask?.value
        #expect(model.discoverySnapshot?.items.contains { $0.id == "other" } == true)
        let baseRequests = DiscoveryHTTPStub.state.requests.filter { request in
            request.url?.path != "/v1/search" || query(request).hasPrefix("artist:")
        }.count
        #expect(model.discoverySnapshot?.items.contains { $0.id == "genreTrack" } == true)
        model.setDiscoveryMode(.underground)
        #expect(model.discoverySnapshot?.items.contains { $0.id == "genreTrack" } == true)
        #expect(model.discoverySnapshot?.items.contains { $0.id == "other" } == true)
        await model.browsingTask?.value
        model.setDiscoveryMode(.fresh)
        await model.browsingTask?.value
        model.setDiscoveryGenre("techno")
        await model.browsingTask?.value
        model.toggleDiscoveryHideLiked()
        #expect(model.discoverySnapshot?.items.contains { $0.id == "other" } == true)
        await model.browsingTask?.value
        let beforeFeedback = DiscoveryHTTPStub.state.requests.count
        let remote = try #require(model.discoverySnapshot?.tracks.first { $0.id == "other" })
        model.notInterested(track: remote)
        #expect(model.discoverySnapshot?.items.contains { $0.id == "other" } == false)
        await model.browsingTask?.value
        model.undoNotInterested()
        #expect(model.discoverySnapshot?.items.contains { $0.id == "other" } == true)
        await model.browsingTask?.value
        #expect(DiscoveryHTTPStub.state.requests.count == beforeFeedback)
        #expect(
            DiscoveryHTTPStub.state.requests.filter {
                $0.url?.path != "/v1/search" || query($0).hasPrefix("artist:")
            }.count == baseRequests)
        store.retire()
        await store.client.close()
    }

    func query(_ request: URLRequest) -> String {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "q" }?.value ?? ""
    }

    @Test func lowerHalfArtistsAreSampledUsingOriginalRankAndCachedAcrossModes() async throws {
        let artists = (0..<15).map {
            ["artist_mbid": "a\($0)", "name": "Other \($0)", "score": 15 - $0] as [String: Any]
        }
        let json = String(
            decoding: try JSONSerialization.data(withJSONObject: artists), as: UTF8.self)
        var routes: [String: [DiscoveryHTTPStub.Reply]] = [
            "GET /v1/tracks/seed": [.init(body: hydrated)],
            "GET /v1/artists/artist": [
                .init(
                    body:
                        #"{"id":"artist","uri":"artist","name":"Seed Artist","genres":["ambient"]}"#
                )
            ],
            "GET /ws/2/isrc/SEEDISRC": [.init(body: resolutionJSON)],
            "GET /similar-recordings/json": [.init(body: "[]")],
            "GET /similar-artists/json": [.init(body: json)],
            "GET /v1/search": Array(
                repeating: .init(body: #"{"tracks":{"items":[]},"albums":{"items":[]}}"#), count: 4),
        ]
        for index in [0, 1, 2, 7, 8] {
            routes["GET /v1/search artist:\"Other \(index)\""] = [
                .init(
                    body:
                        "{\"tracks\":{\"items\":[\(trackJSON("other\(index)", name: "Other \(index)", artistID: "a\(index)"))]}}"
                )
            ]
        }
        DiscoveryHTTPStub.state.reset(routes: routes)
        let store = makeStore()
        store.setListenBrainzEnabled(true)
        let initial = try await discover(store)
        #expect(initial.tracks.count == 5)
        let changed = try await store.discover(
            seedTitle: seed.title, seedTrack: seed, seedArtist: artist, mode: .underground,
            selectedGenre: "ambient", hideLiked: false)
        for id in ["other7", "other8"] {
            #expect(
                try #require(changed.items.first { $0.id == id }).score
                    > #require(initial.items.first { $0.id == id }).score)
        }
        let requests = DiscoveryHTTPStub.state.requests
        #expect(requests.filter { query($0).hasPrefix("artist:\"Other") }.count == 5)
        #expect(requests.filter { $0.url?.path == "/similar-artists/json" }.count == 1)
        #expect(requests.filter { $0.url?.path == "/similar-recordings/json" }.count == 1)
        #expect(requests.filter { $0.url?.path == "/v1/tracks/seed" }.count == 1)
        store.retire()
        await store.client.close()
    }
}
