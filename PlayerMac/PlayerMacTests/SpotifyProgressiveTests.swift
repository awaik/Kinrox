import Foundation
import MusicCore
import SpotifyWebAPI
import Testing

@testable import Kinrox

extension SpotifyLibraryTests {
    var savedAlbumPage: String {
        #"{"items":[{"album":{"id":"album","uri":"spotify:album:album","name":"Album","artists":[],"total_tracks":1,"tracks":{"items":[{"id":"track","uri":"spotify:track:track","name":"Track","artists":[],"duration_ms":180000}],"next":null}}}],"next":null}"#
    }
    func routedClient(_ routes: [String: [MusicHTTPStub.Reply]]) -> SpotifyClient {
        MusicHTTPStub.state.reset(routes: routes)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MusicHTTPStub.self]
        return SpotifyClient(configuration: config) { _ in "synthetic" }
    }
    var profile: SpotifyProfile {
        get throws {
            try JSONDecoder().decode(
                SpotifyProfile.self, from: Data(#"{"id":"owner","display_name":"Test"}"#.utf8))
        }
    }
    func waitFor(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<2000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw SpotifyPlaybackError.unconfirmed
    }
    @Test func embeddedTracksRestoreBeforeAnyNetworkAndConditional304RetainsThem() async throws {
        let client = routedClient([
            "GET /v1/me/albums": [
                .init(body: savedAlbumPage, headers: ["ETag": "albums-v1"]),
                .init(status: 304),
            ]
        ])
        let cache = SpotifyCacheStore(
            clientID: "test", userID: "owner", displayName: "Test",
            root: FileManager.default.temporaryDirectory.appendingPathComponent(
                "kinrox-warm-test-\(UUID())"))
        let store = SpotifyLibraryStore(client: client, profile: try profile, cache: cache)
        try await store.loadCollection("albums")
        try await store.loadAlbum("album")
        #expect(MusicHTTPStub.state.requests.count == 1)
        try await store.loadCollection("albums", force: true)
        #expect(
            MusicHTTPStub.state.requests.last?.value(forHTTPHeaderField: "If-None-Match")
                == "albums-v1")
        let restored = SpotifyLibraryStore(
            client: client, profile: try profile, cache: cache, connected: false)
        await restored.restore()
        #expect(restored.catalog.album(id: "album")?.trackIDs == ["track"])
        #expect(restored.library.savedAlbumIDs == ["album"])
        #expect(MusicHTTPStub.state.requests.count == 2)
        await #expect(throws: SpotifyError.authentication) {
            _ = try await restored.change(.album("album", saved: false))
        }
        store.retire()
        restored.retire()
        await client.close()
    }
    @Test func albumsPublishAndIndependentMutationSucceedsBeforeLikedCompletes() async throws {
        let gate = MusicResponseGate()
        let empty = #"{"items":[],"next":null}"#
        let client = routedClient([
            "GET /v1/me/albums": [.init(body: savedAlbumPage), .init(body: empty)],
            "GET /v1/me/playlists": [.init(body: empty)],
            "GET /v1/me/tracks": [.init(body: empty, gate: gate)],
            "GET /v1/me/following": [.init(body: #"{"artists":{"items":[],"next":null}}"#)],
            "DELETE /v1/me/library": [.init(status: 204)],
        ])
        let store = SpotifyLibraryStore(client: client, profile: try profile)
        let model = MusicViewModel(store: DisconnectedMusicLibraryStore())
        model.replaceStore(store)
        model.syncLibrary()
        try await waitFor {
            MusicHTTPStub.state.requests.contains { $0.url?.path == "/v1/me/tracks" }
        }
        #expect(model.catalog.album(id: "album")?.trackIDs == ["track"])
        #expect(!model.isInitialLoading && model.isRefreshing && model.canMutate)
        model.toggleAlbum(try #require(model.catalog.album(id: "album")))
        try await waitFor { !model.isMutating }
        #expect(!model.library.savedAlbumIDs.contains("album"))
        #expect(model.isRefreshing)
        await gate.release()
        await model.syncTask?.value
        store.retire()
        await client.close()
    }
    @Test func concurrentAlbumSubscribersShareRequestAndCancellationIsIsolated() async throws {
        let gate = MusicResponseGate()
        let album =
            #"{"id":"album","uri":"spotify:album:album","name":"Album","artists":[],"tracks":{"items":[],"next":null}}"#
        let client = routedClient(["GET /v1/albums/album": [.init(body: album, gate: gate)]])
        let store = SpotifyLibraryStore(client: client, profile: try profile)
        let first = Task { try await store.loadAlbum("album") }
        try await waitFor { MusicHTTPStub.state.requests.count == 1 }
        let second = Task { try await store.loadAlbum("album") }
        try await waitFor { store.subscriptions.values.first?.count == 2 }
        first.cancel()
        await gate.release()
        try await second.value
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(store.catalog.album(id: "album") != nil)
        #expect(MusicHTTPStub.state.requests.count == 1)
        store.retire()
        await client.close()
    }
    func playlistMetadata(_ version: String) -> String {
        #"{"id":"playlist","uri":"spotify:playlist:playlist","name":"Playlist","owner":{"id":"owner"},"snapshot_id":"\#(version)"}"#
    }
    func itemPage(_ ids: [String]) -> String {
        let items = ids.map { id in
            #"{"item":{"id":"\#(id)","uri":"spotify:track:\#(id)","name":"Track","duration_ms":1000,"artists":[],"album":{"id":"album","uri":"spotify:album:album","name":"Album","artists":[]}}}"#
        }.joined(separator: ",")
        return #"{"items":[\#(items)],"next":null}"#
    }
    @Test(arguments: [false, true]) func refreshCrossingInsertNeverReplaysIt(alreadyInserted: Bool)
        async throws
    {
        let gate = MusicResponseGate()
        let client = routedClient([
            "GET /v1/playlists/playlist": [
                .init(body: playlistMetadata("v0"), gate: gate),
                .init(body: playlistMetadata("v1")), .init(body: playlistMetadata("v0")),
            ],
            "GET /v1/playlists/playlist/items": [
                .init(body: itemPage(alreadyInserted ? ["A", "X", "B"] : ["A", "B"]))
            ],
            "POST /v1/playlists/playlist/items": [.init(body: #"{"snapshot_id":"v1"}"#)],
            "GET /v1/me/playlists": [
                .init(body: #"{"items":[\#(playlistMetadata("v1"))],"next":null}"#)
            ],
        ])
        let store = SpotifyLibraryStore(client: client, profile: try profile)
        store.library.playlists = [
            MusicPlaylist(
                id: "playlist", uri: "spotify:playlist:playlist",
                title: "Playlist", ownerID: "owner", snapshotID: "v0", trackIDs: ["A", "B"])
        ]
        // No complete index: the older refresh has to read all pages.
        let refresh = Task { try await store.ensurePlaylistLoaded("playlist") }
        try await waitFor { MusicHTTPStub.state.requests.count == 1 }
        try await store.apply([
            .playlistInsert(playlistID: "playlist", trackID: "X", positions: [1])
        ])
        try await waitFor { store.revalidationTask == nil }
        await gate.release()
        try await refresh.value
        #expect(store.library.playlists.first?.trackIDs == ["A", "X", "B"])
        #expect(store.index.trackIDs(playlistID: "playlist", snapshotID: "v1") == ["A", "X", "B"])
        #expect(MusicHTTPStub.state.requests.filter { $0.httpMethod == "POST" }.count == 1)
        store.retire()
        await client.close()
    }
    @Test func membershipLoadsBeforePolicyAndStaleUndoCannotWrite() async throws {
        let client = routedClient([
            "GET /v1/playlists/playlist": [
                .init(body: playlistMetadata("v1")), .init(body: playlistMetadata("v1")),
                .init(body: playlistMetadata("v2")), .init(body: playlistMetadata("v2")),
            ],
            "GET /v1/playlists/playlist/items": [
                .init(body: itemPage(["A", "X", "B"])), .init(body: itemPage(["B", "A"])),
            ],
        ])
        let store = SpotifyLibraryStore(client: client, profile: try profile)
        let change = try await store.change(
            .membership(track: "X", playlist: "playlist", included: true))
        #expect(change.mutations.isEmpty)
        await #expect(throws: SpotifyError.invalidResponse) {
            _ = try await store.change(
                .undo(
                    [.playlistInsert(playlistID: "playlist", trackID: "X", positions: [1])],
                    snapshots: ["playlist": "v1"]))
        }
        #expect(MusicHTTPStub.state.requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(store.library.playlists.first?.trackIDs == ["B", "A"])
        store.retire()
        await client.close()
    }
}

extension SpotifyLibraryTests {
    @Test func cancelledPaginationNeverPublishesPartialLibraryOrOverwritesDisk() async throws {
        let gate = MusicResponseGate()
        let initial = savedAlbumPage.replacingOccurrences(
            of: #""next":null}"#,
            with: #""next":"https://api.spotify.com/v1/me/albums?offset=50"}"#, options: .backwards)
        let client = routedClient([
            "GET /v1/me/albums": [
                .init(body: savedAlbumPage), .init(body: initial),
                .init(body: #"{"items":[],"next":null}"#, gate: gate),
            ]
        ])
        let cache = SpotifyCacheStore(
            clientID: "test", userID: "owner", displayName: "Test",
            root: FileManager.default.temporaryDirectory.appendingPathComponent(
                "kinrox-cancel-test-\(UUID())"))
        let store = SpotifyLibraryStore(client: client, profile: try profile, cache: cache)
        try await store.loadCollection("albums")
        let original = store.library
        let task = Task { try await store.loadCollection("albums", force: true) }
        try await waitFor { MusicHTTPStub.state.requests.count == 3 }
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(store.library == original)
        #expect(try await cache.restore().library == original)
        store.retire()
        await client.close()
    }
    @Test func retiredSyncCannotRecreateCacheAfterDisconnect() async throws {
        let gate = MusicResponseGate()
        let client = routedClient(["GET /v1/me/albums": [.init(body: savedAlbumPage, gate: gate)]])
        let cache = SpotifyCacheStore(
            clientID: "test", userID: "owner", displayName: "Test",
            root: FileManager.default.temporaryDirectory.appendingPathComponent(
                "kinrox-disconnect-test-\(UUID())"))
        let store = SpotifyLibraryStore(client: client, profile: try profile, cache: cache)
        await store.restore()
        let sync = Task { try await store.loadCollection("albums") }
        try await waitFor { MusicHTTPStub.state.requests.count == 1 }
        store.retire()
        await client.close()
        try await cache.destroyAccountCache()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await sync.value }
        #expect(store.catalog.tracks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
    }
}

extension SpotifyLibraryTests {
    @Test func unlikeWaitsForEveryEditablePlaylistBeforeSendingAnyMutation() async throws {
        let gate = MusicResponseGate()
        let client = routedClient([
            "GET /v1/me/playlists": [
                .init(body: #"{"items":[\#(playlistMetadata("v1"))],"next":null}"#)
            ],
            "GET /v1/playlists/playlist": [
                .init(body: playlistMetadata("v1")), .init(body: playlistMetadata("v1")),
            ],
            "GET /v1/playlists/playlist/items": [
                .init(body: itemPage(["A", "X", "B", "X"]), gate: gate)
            ],
            "DELETE /v1/me/library": [.init(status: 204)],
            "DELETE /v1/playlists/playlist/items": [.init(body: #"{"snapshot_id":"v2"}"#)],
        ])
        let store = SpotifyLibraryStore(client: client, profile: try profile)
        store.library.likedTrackIDs = ["X"]
        store.mark("liked")
        let task = Task { try await store.change(.track("X", liked: false)) }
        try await waitFor {
            MusicHTTPStub.state.requests.contains { $0.url?.path.hasSuffix("/items") == true }
        }
        #expect(MusicHTTPStub.state.requests.allSatisfy { $0.httpMethod == "GET" })
        await gate.release()
        let change = try await task.value
        #expect(store.library.playlists.first?.trackIDs == ["A", "B"])
        #expect(!store.library.likedTrackIDs.contains("X"))
        #expect(
            change.undo.contains(
                .playlistInsert(playlistID: "playlist", trackID: "X", positions: [1, 3])))
        #expect(store.confirmedMutationSnapshots == ["playlist": "v2"])
        store.retire()
        await client.close()
    }
    @Test func diskFailureDoesNotCompensateSuccessfulSpotifyWrite() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinrox-cache-file-\(UUID())")
        try Data().write(to: file)
        let cache = SpotifyCacheStore(
            clientID: "test", userID: "owner", displayName: "Test", root: file)
        let client = routedClient(["PUT /v1/me/library": [.init(status: 204)]])
        let store = SpotifyLibraryStore(client: client, profile: try profile, cache: cache)
        store.mark("liked")
        _ = try await store.change(.track("X", liked: true))
        #expect(store.library.likedTrackIDs == ["X"])
        #expect(store.cacheIsStale)
        #expect(!MusicHTTPStub.state.requests.contains { $0.httpMethod == "DELETE" })
        store.retire()
        await client.close()
    }
}

extension SpotifyLibraryTests {
    @Test func refreshCannotPublishWhileRollbackCompensationIsPending() async throws {
        let readGate = MusicResponseGate()
        let compensationGate = MusicResponseGate()
        let client = routedClient([
            "GET /v1/me/tracks": [.init(body: #"{"items":[],"next":null}"#, gate: readGate)],
            "DELETE /v1/me/library": [.init(status: 204)],
            "DELETE /v1/playlists/playlist/items": [.init(status: 403)],
            "PUT /v1/me/library": [.init(status: 204, gate: compensationGate)],
        ])
        let store = SpotifyLibraryStore(client: client, profile: try profile)
        store.library.likedTrackIDs = ["X"]
        store.library.playlists = [
            MusicPlaylist(
                id: "playlist", uri: "spotify:playlist:playlist",
                title: "Playlist", ownerID: "owner", snapshotID: "v0", trackIDs: ["X"])
        ]
        store.mark("liked")
        let read = Task { try await store.loadCollection("liked", force: true) }
        try await waitFor { MusicHTTPStub.state.requests.count == 1 }
        let mutation = Task {
            try await store.apply([
                .trackLiked(id: "X", false), .playlistRemove(playlistID: "playlist", trackID: "X"),
            ])
        }
        try await waitFor { MusicHTTPStub.state.requests.contains { $0.httpMethod == "PUT" } }
        await readGate.release()
        try await read.value
        #expect(store.pendingResources.contains("liked"))
        #expect(store.library.likedTrackIDs == ["X"])
        await compensationGate.release()
        await #expect(throws: SpotifyError.forbidden) { try await mutation.value }
        #expect(store.library.likedTrackIDs == ["X"])
        #expect(store.pendingResources.isEmpty)
        store.retire()
        await client.close()
    }
}
