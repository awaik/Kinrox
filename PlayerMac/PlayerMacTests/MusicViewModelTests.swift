import Foundation
import MusicCore
import Testing

@testable import Kinrox

@MainActor
struct MusicViewModelTests {
    @Test func unlikeStaysInVisibleListAndUndoRestoresMembership() async throws {
        let model = MusicViewModel()
        model.select(.liked)
        let track = try #require(model.contents.tracks.first { $0.id == "evening-2" })
        let before = model.library
        model.toggleTrack(track, anchor: "test")
        #expect(!model.library.likedTrackIDs.contains(track.id))
        #expect(model.likeOptionsTrackID == nil)
        #expect(model.statusMessage == nil)
        #expect(model.contents.tracks.contains(track))
        await settle(model)
        model.undo()
        await settle(model)
        #expect(model.library == before)
        #expect(!model.canUndo)
        model.toggleTrack(track, anchor: "test")
        await settle(model)
        model.refreshContents()
        #expect(!model.contents.tracks.contains(track))
    }

    @Test func closingLikeOptionsNeverUndoesChanges() async throws {
        let model = MusicViewModel()
        let track = try #require(model.catalog.tracks.first { $0.id == "evening-1" })
        model.toggleTrack(track, anchor: "deck")
        #expect(model.library.likedTrackIDs.contains(track.id))
        #expect(model.likeOptionsTrackID == track.id)
        await settle(model)
        model.setMembership(trackID: track.id, playlistID: "focus", included: true)
        await settle(model)
        model.setFollowed(track.artists[0], followed: true)
        await settle(model)
        model.likeOptionsTrackID = nil
        #expect(model.library.likedTrackIDs.contains(track.id))
        #expect(
            model.library.playlists.first { $0.id == "focus" }?.trackIDs.contains(track.id) == true)
        #expect(model.library.followedArtistIDs.contains(track.artists[0].id))
    }

    @Test func failureRollsBackOptimisticChangeAndRetrySucceeds() async throws {
        let store = FailingMusicStore()
        let model = MusicViewModel(store: store)
        let track = try #require(model.catalog.tracks.first { $0.id == "evening-1" })
        let before = model.library
        model.toggleTrack(track, anchor: "test")
        #expect(model.library.likedTrackIDs.contains(track.id))
        await settle(model)
        #expect(model.library == before)
        #expect(model.favoriteFeedbackID == nil)
        #expect(model.statusMessage != nil)
        #expect(model.likeOptionsTrackID == nil)
        store.shouldFail = false
        model.retry()
        await settle(model)
        #expect(model.library.likedTrackIDs.contains(track.id))
        #expect(model.statusMessage == nil)
    }

    @Test func albumPlaybackStartsAtFirstTrackAndBrowsingDoesNotChangeIt() async throws {
        let model = MusicViewModel()
        var playbackRequests = 0
        model.beforeDemoPlayback = { playbackRequests += 1 }
        let album = try #require(model.catalog.albums.first { $0.id == "evening" })
        model.playAlbum(album)
        for _ in 0..<100 where playbackRequests == 0 { await Task.yield() }
        #expect(model.currentTrack?.id == album.trackIDs.first)
        #expect(playbackRequests == 1)
        model.select(.liked)
        model.query = "lune"
        model.search()
        #expect(playbackRequests == 1)
        #expect(model.currentTrack?.id == album.trackIDs.first)
        #expect(!model.paused)
        model.togglePause()
        for _ in 0..<100 where !model.paused { await Task.yield() }
        #expect(model.paused)
    }

    @Test func modeSwitchOnlyChangesViewAndVideoGatesStayIntact() {
        let session = PlayerSession(recents: RecentFilesStore(), demoMusic: true)
        let current = session.music.currentTrack
        session.mode = .music
        #expect(session.canControl)
        #expect(!session.trackShortcutsAllowed)
        session.isOpenPanelShown = true
        #expect(!session.canControl)
        session.isOpenPanelShown = false
        session.mode = .video
        #expect(!session.canControl)
        #expect(session.music.currentTrack == current)
    }

    private func settle(_ model: MusicViewModel) async {
        for _ in 0..<1_000 where model.isMutating { await Task.yield() }
        #expect(!model.isMutating)
    }
}

@MainActor
private final class FailingMusicStore: MusicLibraryStore {
    enum Failure: Error { case request }
    let catalog = MusicDemo.catalog
    var library = MusicDemo.library
    var shouldFail = true

    func apply(_ mutations: [LibraryMutation]) async throws {
        if shouldFail { throw Failure.request }
        library.apply(mutations)
    }

    func createPlaylist(title: String, trackID: String) async throws -> MusicPlaylist {
        throw Failure.request
    }
}
