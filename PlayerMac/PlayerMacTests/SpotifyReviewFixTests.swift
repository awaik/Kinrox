import Foundation
import MusicCore
import SpotifyWebAPI
import Testing

@testable import Kinrox

extension SpotifyLibraryTests {
    @Test func partialSavedAlbumRefreshPreservesCompleteTracks() async throws {
        let client = routedClient([:])
        let store = SpotifyLibraryStore(client: client, profile: try profile)
        let full = try JSONDecoder().decode(
            SpotifyAlbum.self,
            from: Data(
                #"{"id":"album","uri":"spotify:album:album","name":"Album","artists":[],"tracks":{"items":[],"next":null}}"#
                    .utf8))
        store.catalog.merge(albums: [full.model(trackIDs: (0..<75).map { "track\($0)" })])
        store.mark("album:album", ttl: 86400)
        let partial = try JSONDecoder().decode(
            SpotifyAlbum.self,
            from: Data(
                #"{"id":"album","uri":"spotify:album:album","name":"Album","artists":[],"tracks":{"items":[{"id":"track0","uri":"spotify:track:track0","name":"Track","duration_ms":1000,"artists":[]}],"next":"https://api.spotify.com/v1/albums/album/tracks?offset=50"}}"#
                    .utf8))
        store.mergeAlbum(partial)
        #expect(store.catalog.album(id: "album")?.trackIDs.count == 75)
        #expect(store.fresh("album:album"))
        store.catalog = MusicCatalog(albums: [partial.model(trackIDs: ["track0"])])
        store.mergeAlbum(partial)
        #expect(!store.fresh("album:album"))
        store.retire()
        await client.close()
    }

    @Test func playlistSelectionLoadsAndPublishesAlreadyKnownTracks() async throws {
        let client = routedClient([
            "GET /v1/playlists/playlist": [
                .init(body: playlistMetadata("v1")), .init(body: playlistMetadata("v1")),
            ],
            "GET /v1/playlists/playlist/items": [.init(body: itemPage(["A"]))],
        ])
        let store = SpotifyLibraryStore(client: client, profile: try profile)
        let page = try JSONDecoder().decode(
            SpotifyPage<SpotifyPlaylistItem>.self, from: Data(itemPage(["A"]).utf8))
        store.catalog.merge(
            tracks: page.items.compactMap { $0.value?.model() },
            albums: page.items.compactMap { $0.value?.album?.model() })
        store.library.playlists = [
            MusicPlaylist(
                id: "playlist", uri: "spotify:playlist:playlist", title: "Playlist",
                ownerID: "owner", snapshotID: "v1", trackIDs: [])
        ]
        let model = MusicViewModel(store: DisconnectedMusicLibraryStore())
        model.replaceStore(store)
        model.select(.playlist("playlist"))
        await model.browsingTask?.value
        #expect(model.contents.tracks.map(\.id) == ["A"])
        // A publication outside refresh must also update rows with an unchanged catalog.
        store.library.playlists[0].trackIDs = []
        model.acceptLibrary(store)
        #expect(model.contents.tracks.isEmpty)
        store.retire()
        await client.close()
    }

    @Test func pausedEndSeekDoesNotEmitEnd() async throws {
        let ended = playback(playing: false).replacingOccurrences(
            of: "\"progress_ms\":0", with: "\"progress_ms\":179000")
        let client = connectClient([
            .init(body: playback(playing: false)), .init(status: 204), .init(body: ended),
        ])
        var queue = MusicQueue()
        queue.start([connectTrack])
        let engine = try warmEngine(client, queue: queue)
        try await engine.seek(absolute: 180)
        #expect(!engine.endReported)
        #expect(engine.lastState?.paused == true)
        // Later observations (for example a volume command) must not reinterpret this as EOF.
        engine.publish(
            try JSONDecoder().decode(SpotifyPlayback.self, from: Data(ended.utf8)),
            detectAdvance: true)
        #expect(!engine.endReported)
        await client.close()
        await engine.shutdown()
    }

    @Test func duplicateSeekRejectsOldStartPosition() async throws {
        let old = playback(playing: true).replacingOccurrences(
            of: "\"progress_ms\":0", with: "\"progress_ms\":3000")
        let sought = playback(playing: true).replacingOccurrences(
            of: "\"progress_ms\":0", with: "\"progress_ms\":179000")
        let client = connectClient([
            .init(body: old), .init(status: 204), .init(body: old), .init(body: sought),
        ])
        var queue = MusicQueue()
        queue.start([connectTrack, connectTrack])
        let engine = try warmEngine(client, queue: queue)
        try await engine.seek(absolute: 180)
        #expect(engine.cursor == 0)
        #expect(engine.lastState?.position == 179)
        #expect(MusicHTTPStub.state.requests.count == 4)
        engine.boundaryTask?.cancel()
        await client.close()
        await engine.shutdown()
    }

    @Test func rewindRearmsEndDetection() async throws {
        let client = connectClient([
            .init(body: playback(playing: false)), .init(status: 204),
            .init(body: playback(playing: false)),
        ])
        var queue = MusicQueue()
        queue.start([connectTrack])
        let engine = try warmEngine(client, queue: queue)
        engine.endReported = true
        try await engine.seek(absolute: 0)
        #expect(!engine.endReported)
        await client.close()
        await engine.shutdown()
    }

    @Test(arguments: [false, true]) func pausedRewriteCannotBeConfirmedByIncrementalEdit(
        repeatOnly: Bool
    ) async throws {
        let client = connectClient(
            repeatOnly
                ? [.init(status: 204)]
                : [.init(body: helper), .init(body: #"{"snapshot_id":"v2"}"#)])
        var queue = MusicQueue()
        queue.start([connectTrack, connectTrack])
        let engine = try warmEngine(client, queue: queue)
        engine.confirmedQueue = nil
        if repeatOnly { queue.repeatMode = .all } else { queue.add(connectTrack) }
        try await engine.updateQueue(queue, position: 42, paused: true)
        #expect(!engine.canResume(queue))
        await client.close()
        await engine.shutdown()
    }

    @Test func demoPausePreservesElapsedPosition() async throws {
        let model = MusicViewModel()
        model.paused = false
        model.position = 10
        model.lastPositionTimestamp = .now.advanced(by: .seconds(-5))
        try await model.pauseForSourceChange()
        #expect(model.paused)
        #expect(model.position >= 15 && model.position < 16)
    }
}

extension SpotifyLibraryTests {
    @Test func warmResumeRearmsEndWithoutRewind() async throws {
        let client = connectClient([
            .init(body: playback(playing: false)), .init(body: helper),
            .init(status: 204), .init(body: playback(playing: true)),
        ])
        var queue = MusicQueue()
        queue.start([connectTrack])
        let engine = try warmEngine(client, queue: queue)
        engine.endReported = true
        try await engine.setPaused(false)
        #expect(!engine.endReported)
        let ended = playback(playing: false).replacingOccurrences(
            of: "\"progress_ms\":0", with: "\"progress_ms\":179000")
        engine.publish(
            try JSONDecoder().decode(SpotifyPlayback.self, from: Data(ended.utf8)),
            detectAdvance: true)
        #expect(engine.endReported)
        engine.boundaryTask?.cancel()
        await client.close()
        await engine.shutdown()
    }

    @Test func incrementalQueueInsertCannotExceedLimit() async throws {
        let client = connectClient([])
        var queue = MusicQueue()
        queue.start(Array(repeating: connectTrack, count: 10_000))
        let engine = try warmEngine(client, queue: queue)
        queue.add(connectTrack)
        do {
            try await engine.updateQueue(queue, position: 0, paused: true)
            Issue.record("Oversized queue was accepted")
        } catch SpotifyPlaybackError.queueTooLarge {} catch { throw error }
        #expect(MusicHTTPStub.state.requests.isEmpty)
        await client.close()
        await engine.shutdown()
    }
}
