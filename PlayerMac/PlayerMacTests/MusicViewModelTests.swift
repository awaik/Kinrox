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

    @Test func addedColumnVisibilityPerSourceSortingAndPersistence() throws {
        let defaults = try #require(
            UserDefaults(suiteName: "app.kinrox.tests.browsing.\(UUID())"))
        let model = MusicViewModel(store: DemoMusicLibraryStore(), defaults: defaults)
        #expect(!model.showsAddedColumn)

        model.select(.liked)
        #expect(model.showsAddedColumn)
        #expect(model.currentTrackSortOrder == .default)

        // First click on Added sorts newest-first (descending), second click sorts oldest-first.
        model.toggleTrackSort(.added)
        #expect(
            model.currentTrackSortOrder == TrackSortOrder(column: .added, ascending: false))
        #expect(model.contents.tracks.first?.id == "evening-0")
        #expect(model.contents.tracks.last?.id == "neon-0")

        model.toggleTrackSort(.added)
        #expect(
            model.currentTrackSortOrder == TrackSortOrder(column: .added, ascending: true))
        #expect(model.contents.tracks.first?.id == "neon-0")
        #expect(model.contents.tracks.last?.id == "evening-0")

        model.focusTrack("evening-4")
        #expect(model.focusedTrackID == "evening-4")

        // Playlist has its own independent sort order and also shows Added column.
        model.select(.playlist("evening"))
        #expect(model.showsAddedColumn)
        #expect(model.currentTrackSortOrder == .default)
        model.toggleTrackSort(.title)
        #expect(
            model.currentTrackSortOrder == TrackSortOrder(column: .title, ascending: true))

        // Artist and Queue hide the Added column.
        model.select(.artist("north"))
        #expect(!model.showsAddedColumn)
        model.select(.queue)
        #expect(!model.showsAddedColumn)

        // Return to Liked tracks before restarting to verify full state restoration.
        model.select(.liked)
        #expect(
            model.currentTrackSortOrder == TrackSortOrder(column: .added, ascending: true))
        #expect(model.focusedTrackID == "evening-4")

        let reopened = MusicViewModel(store: DemoMusicLibraryStore(), defaults: defaults)
        #expect(reopened.selection.source == .liked)
        #expect(reopened.showsAddedColumn)
        #expect(
            reopened.currentTrackSortOrder == TrackSortOrder(column: .added, ascending: true))
        #expect(reopened.focusedTrackID == "evening-4")
        #expect(reopened.contents.tracks.first?.id == "neon-0")
    }

    @Test func artistAndAlbumPreviewPopoversAndDirectNavigation() throws {
        let model = MusicViewModel()
        model.select(.liked)
        let track = try #require(model.contents.tracks.first { $0.id == "evening-2" })
        #expect(track.artists.count == 2)

        model.openArtistPreview(for: track, anchor: "artist-track-0")
        #expect(model.hasActivePopover)
        #expect(model.previewArtistAnchor == "artist-track-0")
        #expect(model.previewArtistID == track.artists[0].id)

        model.selectPreviewArtist(track.artists[1].id)
        #expect(model.previewArtistID == track.artists[1].id)

        model.openAlbumPreview(for: track, anchor: "album-track-0")
        #expect(model.previewArtistAnchor == nil)
        #expect(model.previewAlbumAnchor == "album-track-0")
        #expect(model.previewAlbumID == track.albumID)

        model.navigateToAlbum(albumID: track.albumID, trackID: track.id)
        #expect(!model.hasActivePopover)
        #expect(model.selection.source == .albums)
        #expect(model.selection.albumID == track.albumID)
        #expect(model.focusedTrackID == track.id)

        model.navigateToArtist(track.artists[1])
        #expect(model.selection.source == .artist(track.artists[1].id))
    }

    @Test func leftSectionExpansionQueueDropAndSimilarDiscovery() async throws {
        let model = MusicViewModel()
        model.expandLeftSection(.playlists)
        #expect(model.leftSection == .playlists)
        model.playlistFilter = .subscribed
        #expect(model.filteredLeftPlaylists.allSatisfy { !$0.isEditable(by: model.library.userID) })
        model.playlistFilter = .mine
        #expect(model.filteredLeftPlaylists.allSatisfy { $0.isEditable(by: model.library.userID) })
        model.collapseLeftSection()
        #expect(model.leftSection == .home)

        let album = try #require(model.catalog.albums.first { $0.id == "neon" })
        let beforeManual = model.queue.manual.count
        #expect(model.handleQueueDrop("album:\(album.id)"))
        for _ in 0..<50 where model.queue.manual.count == beforeManual { await Task.yield() }
        #expect(model.queue.manual.count == beforeManual + album.trackIDs.count)

        model.openSimilar(album: album)
        #expect(model.selection.source == .similar)
        #expect(model.discoverySnapshot != nil)
        #expect(!model.contents.tracks.isEmpty)
        model.setDiscoveryMode(.underground)
        #expect(model.discoveryMode == .underground)
        model.toggleDiscoveryHideLiked()
        #expect(model.discoveryHideLiked)
        #expect(
            model.contents.tracks.allSatisfy { !model.library.likedTrackIDs.contains($0.id) })

        model.select(.liked)
        #expect(!model.isAlbumsOverview)
        model.select(.albums)
        #expect(model.isAlbumsOverview)

        let firstUpcoming = try #require(model.queue.upcoming.first)
        #expect(model.handleQueueDrop(firstUpcoming.id.uuidString, before: nil))
        for _ in 0..<50 where model.queue.upcoming.last?.id != firstUpcoming.id {
            await Task.yield()
        }
        #expect(model.queue.upcoming.last?.id == firstUpcoming.id)
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
