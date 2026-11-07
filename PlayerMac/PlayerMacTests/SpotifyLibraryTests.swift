import Foundation
import MusicCore
import SpotifyWebAPI
import Testing

@testable import Kinrox

@Suite(.serialized)
@MainActor
struct SpotifyLibraryTests {
    @Test func partialUnlikeFailureRestoresSavedTrack() async throws {
        let client = makeClient([.init(body: ""), .init(status: 403), .init(body: "")])
        let service = FavoritesService(client: client)
        let snapshot = LibrarySnapshot(
            userID: "owner", likedTrackIDs: ["track"], playlists: [playlist])
        let change = FavoritesPolicy.track("track", liked: false, in: snapshot)
        await #expect(throws: SpotifyError.forbidden) {
            _ = try await service.apply(change.mutations, to: snapshot)
        }
        let requests = MusicHTTPStub.state.requests
        #expect(requests.map(\.httpMethod) == ["DELETE", "DELETE", "PUT"])
        #expect(requests.last?.url?.path == "/v1/me/library")
        await client.close()
    }

    @Test func failedDuplicateRestorationCompensatesSuccessfulInsert() async throws {
        let response = #"{"snapshot_id":"version"}"#
        let client = makeClient([
            .init(body: response), .init(status: 403), .init(body: response), .init(body: response),
        ])
        let service = FavoritesService(client: client)
        let snapshot = LibrarySnapshot(userID: "owner", playlists: [playlist])
        await #expect(throws: SpotifyError.forbidden) {
            _ = try await service.apply(
                [.playlistInsert(playlistID: "playlist", trackID: "track", positions: [0, 2])],
                to: snapshot)
        }
        let requests = MusicHTTPStub.state.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "DELETE", "POST"])
        let last =
            try JSONSerialization.jsonObject(with: #require(requests.last?.httpBody))
            as? [String: Any]
        #expect(last?["position"] as? Int == 1)
        await client.close()
    }

    @Test func foreignPlaylistCannotBeMutatedEvenWithForgedMutation() async throws {
        let client = makeClient([])
        let service = FavoritesService(client: client)
        await #expect(throws: SpotifyError.forbidden) {
            _ = try await service.apply(
                [.playlistRemove(playlistID: "playlist", trackID: "track")],
                to: LibrarySnapshot(userID: "someoneelse", playlists: [playlist]))
        }
        #expect(MusicHTTPStub.state.requests.isEmpty)
        await client.close()
    }

    @Test func playlistIndexAvoidsSecondReadAndKeepsUnavailablePositions() async throws {
        let profile = #"{"id":"owner","display_name":"Test"}"#
        let empty = #"{"items":[],"next":null}"#
        let follows = #"{"artists":{"items":[],"next":null}}"#
        let playlists =
            #"{"items":[{"id":"playlist","uri":"spotify:playlist:playlist","name":"Test","owner":{"id":"owner"},"collaborative":false,"snapshot_id":"version"}],"next":null}"#
        let entries =
            #"{"items":[{"item":null},{"item":{"id":"track","uri":"spotify:track:track","name":"Test","artists":[],"duration_ms":1000,"type":"track","album":{"id":"album","uri":"spotify:album:album","name":"Album","artists":[]}}}],"next":null}"#
        let metadata =
            #"{"id":"playlist","uri":"spotify:playlist:playlist","name":"Test","owner":{"id":"owner"},"snapshot_id":"version"}"#
        MusicHTTPStub.state.reset(routes: [
            "GET /v1/me": [.init(body: profile)],
            "GET /v1/me/albums": [.init(body: empty), .init(body: empty)],
            "GET /v1/me/tracks": [.init(body: empty), .init(body: empty)],
            "GET /v1/me/following": [.init(body: follows), .init(body: follows)],
            "GET /v1/me/playlists": [.init(body: playlists), .init(body: playlists)],
            "GET /v1/playlists/playlist": [.init(body: metadata), .init(body: metadata)],
            "GET /v1/playlists/playlist/items": [.init(body: entries)],
        ])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MusicHTTPStub.self]
        let client = SpotifyClient(configuration: config) { _ in "synthetic" }
        let store = SpotifyLibraryStore(client: client)
        try await store.refresh()
        #expect(store.library.playlists.first?.trackIDs == ["unavailable:0", "track"])
        try await store.refresh()
        #expect(
            MusicHTTPStub.state.requests.filter { $0.url?.path.hasSuffix("/items") == true }.count
                == 1)
        #expect(store.catalog.tracks.first?.title == "Test")
        store.retire()
        await client.close()
    }

    @Test func followedPlaylistsStayInLibraryAndReportUnavailableItemsOn403() async throws {
        let playlists =
            #"{"items":[{"id":"owned","uri":"spotify:playlist:owned","name":"Owned","owner":{"id":"owner"},"collaborative":false,"snapshot_id":"v1"},{"id":"followed","uri":"spotify:playlist:followed","name":"Followed","owner":{"id":"curator"},"collaborative":false,"snapshot_id":"v2"}],"next":null}"#
        let followedMetadata =
            #"{"id":"followed","uri":"spotify:playlist:followed","name":"Followed","owner":{"id":"curator"},"collaborative":false,"snapshot_id":"v2"}"#
        MusicHTTPStub.state.reset(routes: [
            "GET /v1/me/playlists": [.init(body: playlists)],
            "GET /v1/playlists/followed": [
                .init(body: followedMetadata), .init(body: followedMetadata),
                .init(body: followedMetadata),
            ],
            "GET /v1/playlists/followed/items": [.init(status: 403), .init(status: 403)],
        ])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MusicHTTPStub.self]
        let client = SpotifyClient(configuration: config) { _ in "synthetic" }
        let profile = try JSONDecoder().decode(
            SpotifyProfile.self, from: Data(#"{"id":"owner","display_name":"Test"}"#.utf8))
        let store = SpotifyLibraryStore(client: client, profile: profile)
        try await store.loadCollection("playlists")
        #expect(store.library.playlists.map(\.id) == ["owned", "followed"])
        #expect(store.library.editablePlaylists.map(\.id) == ["owned"])
        await #expect(throws: SpotifyPlaylistError.itemsUnavailable) {
            try await store.ensurePlaylistLoaded("followed")
        }
        let followed = try #require(store.library.playlists.first { $0.id == "followed" })
        #expect(!followed.itemsAvailable)
        #expect(
            SpotifyStatus.message(SpotifyPlaylistError.itemsUnavailable)
                == L10n.text(
                    "Spotify only provides tracks for playlists you own or collaborate on.")
        )
        await #expect(throws: SpotifyError.forbidden) {
            try await store.ensurePlaylistLoaded("followed", requireEditable: true)
        }
        store.retire()
        await client.close()
    }

    @Test func discoveryUsesAlbumSearchForFreshAndPropagatesCancellation() async throws {
        let searchReply =
            #"{"tracks":{"items":[],"next":null},"albums":{"items":[{"id":"freshalb1","uri":"spotify:album:freshalb1","name":"Fresh LP","release_date":"2026-11-01","total_tracks":1,"artists":[{"id":"art1","uri":"spotify:artist:art1","name":"Nova"}]}],"next":null},"artists":{"items":[],"next":null},"playlists":{"items":[],"next":null}}"#
        let albumTracksReply =
            #"{"items":[{"id":"freshtrk1","uri":"spotify:track:freshtrk1","name":"Sunrise","duration_ms":180000,"track_number":1,"artists":[{"id":"art1","uri":"spotify:artist:art1","name":"Nova"}]}],"next":null}"#
        MusicHTTPStub.state.reset(routes: [
            "GET /v1/search": [.init(body: searchReply), .init(body: searchReply)],
            "GET /v1/albums/freshalb1/tracks": [.init(body: albumTracksReply)],
        ])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MusicHTTPStub.self]
        let client = SpotifyClient(configuration: config) { _ in "synthetic" }
        let profile = try JSONDecoder().decode(
            SpotifyProfile.self, from: Data(#"{"id":"owner","display_name":"Test"}"#.utf8))
        let store = SpotifyLibraryStore(client: client, profile: profile)
        let seedArtist = MusicArtist(id: "art1", uri: "spotify:artist:art1", name: "Nova")
        let snapshot = try await store.discover(
            seedTitle: "Nova", seedTrack: nil, seedArtist: seedArtist,
            mode: .fresh, selectedGenre: nil, hideLiked: false)
        let searchRequests = MusicHTTPStub.state.requests.filter { $0.url?.path == "/v1/search" }
        #expect(
            searchRequests.contains {
                let query = $0.url?.query?.removingPercentEncoding ?? $0.url?.query ?? ""
                return query.contains("tag:new") && query.contains("type=album")
            })
        #expect(snapshot.items.first { $0.track.id == "freshtrk1" }?.reasonKind == .freshRelease)

        let cancelledTask = Task { @MainActor in
            try await store.discover(
                seedTitle: "Nova", seedTrack: nil, seedArtist: seedArtist,
                mode: .fresh, selectedGenre: nil, hideLiked: true)
        }
        cancelledTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledTask.value
        }
        store.retire()
        await client.close()
    }

    @Test func globalSpotifySearchResetsLocalCollectionFilter() async throws {
        let searchReply =
            #"{"tracks":{"items":[{"id":"found1","uri":"spotify:track:found1","name":"Found Song","duration_ms":180000,"track_number":1,"artists":[{"id":"a1","uri":"spotify:artist:a1","name":"Artist"}],"album":{"id":"alb1","uri":"spotify:album:alb1","name":"Album","artists":[]}}],"next":null},"albums":{"items":[],"next":null},"artists":{"items":[],"next":null}}"#
        MusicHTTPStub.state.reset(routes: [
            "GET /v1/search": [.init(body: searchReply)]
        ])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MusicHTTPStub.self]
        let client = SpotifyClient(configuration: config) { _ in "synthetic" }
        let profile = try JSONDecoder().decode(
            SpotifyProfile.self, from: Data(#"{"id":"owner","display_name":"Test"}"#.utf8))
        let store = SpotifyLibraryStore(client: client, profile: profile)
        let model = MusicViewModel(store: store)
        model.collectionFilterQuery = "nonexistent-previous-filter"
        model.query = "Found"
        model.search()
        #expect(model.collectionFilterQuery.isEmpty)
        for _ in 0..<50 where model.contents.tracks.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.contents.tracks.map(\.id) == ["found1"])
        store.retire()
        await client.close()
    }

    @Test func disconnectDoesNotAllowPendingOptimisticResultToRestoreOldLibrary() async throws {
        let store = SuspendedMusicStore()
        let model = MusicViewModel(store: store)
        let track = try #require(model.catalog.tracks.first)
        model.toggleTrack(track, anchor: "test")
        while store.resume == nil { await Task.yield() }
        model.replaceStore(DisconnectedMusicLibraryStore())
        store.resume?.resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(model.library.likedTrackIDs.isEmpty)
        #expect(model.catalog.tracks.isEmpty)
        #expect(!model.isMutating)
    }

    private var playlist: MusicPlaylist {
        MusicPlaylist(
            id: "playlist", uri: "spotify:playlist:playlist", title: "Test", ownerID: "owner",
            trackIDs: ["other", "track"])
    }
    private func makeClient(_ responses: [MusicHTTPStub.Reply]) -> SpotifyClient {
        MusicHTTPStub.state.reset(responses)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MusicHTTPStub.self]
        return SpotifyClient(configuration: config, token: { _ in "test-only" })
    }
}

@MainActor
private final class SuspendedMusicStore: MusicLibraryStore {
    let catalog = MusicDemo.catalog
    var library = MusicDemo.library
    var resume: CheckedContinuation<Void, Never>?
    func apply(_ mutations: [LibraryMutation]) async throws {
        await withCheckedContinuation { resume = $0 }
        library.apply(mutations)
    }
    func createPlaylist(title: String, trackID: String) async throws -> MusicPlaylist {
        throw SpotifyError.unavailable
    }
}
