import AppKit
import MusicCore
import RemoteProtocol
import SwiftUI
import Testing

@testable import Kinrox

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct MusicReviewRegressionTests {
    @Test func collectionShuffleStartsOnceWithEveryOccurrence() async {
        let music = MusicViewModel()
        let engine = FakeMusicEngine()
        music.connect(engine: engine)
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: music)
        let tracks = music.contents.tracks
        music.shuffleCollection()
        await coordinator.settle()
        #expect(engine.commands == [.play(music.queue.items.map(\.id), 0)])
        #expect(music.queue.shuffled)
        #expect(music.queue.items.map(\.track.id).sorted() == tracks.map(\.id).sorted())
        #expect(music.queue.history.isEmpty)
        #expect(music.paused)  // State still comes from engine confirmation.
        await coordinator.close()
    }

    @Test func emptyCollectionShuffleDoesNotEditTheExistingQueue() async {
        let music = MusicViewModel()
        let engine = FakeMusicEngine()
        music.connect(engine: engine)
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: music)
        music.query = "no matching music"
        music.search()
        let original = music.queue
        #expect(music.contents.tracks.isEmpty)
        music.shuffleCollection()
        await coordinator.settle()
        #expect(music.queue == original)
        #expect(engine.commands.isEmpty)
        await coordinator.close()
    }

    @Test func sourceArrowsIncludeSearchBeforeLikedTracks() {
        let music = MusicViewModel()
        music.query = "evening"
        music.search()
        music.focusedColumn = .source
        music.moveFocus(by: 1)
        #expect(music.selection.source == .liked)
        music.moveFocus(by: -1)
        #expect(music.selection.source == .search("evening"))
        music.moveFocus(by: -1)
        #expect(music.selection.source == .search("evening"))
        music.leaveSearch()
        music.select(.liked)
        music.moveFocus(by: -1)
        #expect(music.selection.source == .liked)
    }

    @Test(arguments: [false, true])
    func favoritesResolveTracksOutsideTheCatalog(fromConfirmedQueue: Bool) async throws {
        let music = MusicViewModel()
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: music)
        music.play(music.catalog.tracks)
        await coordinator.settle()
        let bridge = RemoteMusicBridge(music: music, coordinator: coordinator)
        let track = try #require(music.queue.upcoming.first?.track)
        let artist = try #require(track.artists.first)
        let playlist = try #require(
            music.library.playlists.first { $0.isEditable(by: music.library.userID) })
        music.catalog = MusicCatalog()
        if fromConfirmedQueue {
            // A new, unconfirmed playback request must not invalidate the published queue.
            music.isPlaybackBusy = true
            music.queue.clear()
        }
        let liked = !music.library.likedTrackIDs.contains(track.id)
        #expect(bridge.execute(.setTrackLiked(trackId: track.id, liked: liked)) == nil)
        while music.isMutating { await Task.yield() }
        #expect(music.store.library.likedTrackIDs.contains(track.id) == liked)
        let reply = UUID()
        let message = bridge.likeOptionsPage(.init(trackId: track.id), replyTo: reply)
        #expect(throws: Never.self) { _ = try Codec.encode(message) }
        guard case .likeOptions(_, let page) = message else {
            Issue.record("Queue track has no favorite options")
            bridge.disconnect()
            await coordinator.close()
            return
        }
        #expect(page.replyTo == reply)
        #expect(page.items.contains { $0.id == artist.id && $0.kind == .artist })
        #expect(
            bridge.execute(
                .setPlaylistMembership(trackId: track.id, playlistId: playlist.id, included: true))
                == nil)
        while music.isMutating { await Task.yield() }
        #expect(
            music.store.library.playlists.first { $0.id == playlist.id }?.trackIDs.contains(
                track.id) == true)
        #expect(bridge.execute(.setArtistFollowed(artistId: artist.id, followed: true)) == nil)
        while music.isMutating { await Task.yield() }
        #expect(music.store.library.followedArtistIDs.contains(artist.id))
        #expect(bridge.execute(.createPlaylist(title: "Queue favorite", trackId: track.id)) == nil)
        while music.isMutating { await Task.yield() }
        #expect(
            music.store.library.playlists.contains {
                $0.title == "Queue favorite" && $0.trackIDs == [track.id]
            })
        #expect(bridge.execute(.setTrackLiked(trackId: "missing", liked: true)) == .itemNotFound)
        bridge.disconnect()
        await coordinator.close()
    }

    @Test func malformedOptionsNeverProduceAnUnsendableReply() throws {
        let store = ReviewMusicStore()
        let music = MusicViewModel(store: store)
        let coordinator = PlaybackCoordinator()
        let bridge = RemoteMusicBridge(music: music, coordinator: coordinator)
        defer { bridge.disconnect() }
        let track = try #require(music.catalog.tracks.first)
        let reply = UUID()
        let message = bridge.likeOptionsPage(.init(trackId: track.id), replyTo: reply)
        let encoded = try Codec.encode(message)
        #expect(encoded.count <= Codec.maxMessageBytes - 28)
        guard case .likeOptions(_, let page) = message else {
            Issue.record("Valid options were lost with malformed options")
            return
        }
        #expect(page.replyTo == reply)
        #expect(page.items.filter { $0.kind == .playlist }.map(\.id) == ["valid"])
    }

    @Test func returningToVideoRestoresTrafficLightsWithoutMouseMovement() async throws {
        let session = PlayerSession(recents: RecentFilesStore(), demoMusic: true)
        let controller = try PlayerWindowController(session: session) { _ in }
        controller.model.setVolume(0)
        let window = try #require(controller.window)
        let host = try #require(window.contentView as? NSHostingView<PlayerRootView>)
        let root = host.rootView
        root.video.chrome.setControlsVisible(false)
        session.mode = .music
        root.modeChanged(.music)
        try await Task.sleep(for: .milliseconds(400))
        #expect(window.standardWindowButton(.closeButton)?.alphaValue == 1)
        root.video.chrome.setControlsVisible(false)
        session.mode = .video
        root.modeChanged(.video)
        try await Task.sleep(for: .milliseconds(400))
        #expect(window.standardWindowButton(.closeButton)?.alphaValue == 0)
        root.video.chrome.setControlsVisible(true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(window.standardWindowButton(.closeButton)?.alphaValue == 1)
        controller.close()
        await controller.model.shutdown()
        await session.playback.close()
    }

    @Test func disconnectForgetsQueueBindingsAfterPendingWorkSettles() async throws {
        let defaults = try #require(UserDefaults(suiteName: "app.kinrox.tests.review.\(UUID())"))
        defaults.set("client", forKey: SpotifyAccount.preference)
        defaults.set("helper", forKey: "app.kinrox.spotify.queue.client.user")
        defaults.set("old-helper", forKey: "app.kinrox.spotify.queue.old-client.old-user")
        defaults.set("keep", forKey: "unrelated.preference")
        let credentials = ReviewSpotifyCredentials()
        let account = SpotifyAccount(credentials: credentials, defaults: defaults)
        account.beforeDisconnect = {
            await Task.yield()
            defaults.set("late-helper", forKey: "app.kinrox.spotify.queue.client.late-user")
        }
        account.disconnect()
        while account.isConnecting { await Task.yield() }
        #expect(defaults.object(forKey: SpotifyAccount.preference) == nil)
        #expect(
            defaults.dictionaryRepresentation().keys.filter {
                $0.hasPrefix("app.kinrox.spotify.queue.")
            }.isEmpty)
        #expect(defaults.string(forKey: "unrelated.preference") == "keep")
        #expect(credentials.removed == ["client"])
    }
}

@MainActor
private final class ReviewSpotifyCredentials: SpotifyCredentialStore {
    var removed: [String] = []
    func refreshToken(clientID: String) throws -> String? { nil }
    func save(_ token: String, clientID: String) throws {}
    func remove(clientID: String) throws { removed.append(clientID) }
}

@MainActor
private final class ReviewMusicStore: MusicLibraryStore {
    let catalog = MusicDemo.catalog
    let library = LibrarySnapshot(
        userID: "owner",
        playlists: [
            .init(id: "invalid/id", uri: "", title: "Invalid ID", ownerID: "owner"),
            .init(id: "blank", uri: "", title: " \n ", ownerID: "owner"),
            .init(id: "valid", uri: "", title: "Valid", ownerID: "owner"),
        ])
    func apply(_ mutations: [LibraryMutation]) async throws {}
    func createPlaylist(title: String, trackID: String) async throws -> MusicPlaylist {
        throw DisconnectedMusicLibraryStore.Failure.disconnected
    }
}
