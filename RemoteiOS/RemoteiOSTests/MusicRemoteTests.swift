import Foundation
import RemoteProtocol
import Testing

@testable import RemoteiOS

@MainActor
struct MusicRemoteTests {
    @Test func heartWaitsForMacStateAndOldMacHasNoCapability() async throws {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        #expect(!h.model.supportsMusic)
        h.current.emit(musicState)
        h.model.toggleMusicLike(trackId: "track", currentlyLiked: false)
        await settleTasks()
        #expect(h.model.state.music?.liked == false && !h.model.showsLikeOptions)
        let command = try #require(h.current.messages.first)
        h.current.onEvent?(.message(.ack(.init(), .init(replyTo: command.header.id))))
        await settleTasks()
        #expect(h.model.state.music?.liked == false && !h.model.showsLikeOptions)
        var confirmed = musicState
        confirmed.music?.liked = true
        confirmed.music?.libraryRevision = UUID()
        h.current.emit(confirmed)
        #expect(h.model.showsLikeOptions && h.model.likeOptionsTrackID == "track")
        h.model.showsLikeOptions = false
        h.model.toggleMusicLike(trackId: "track", currentlyLiked: true)
        await settleTasks()
        #expect(!h.model.showsLikeOptions)
    }

    @Test func pagesIgnoreUnsolicitedAndOldRepliesAndResetOnRevision() async throws {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        h.current.emit(musicState)
        h.model.requestMusicQueue()
        await settleTasks()
        let request = try #require(h.current.messages.last)
        let revision = UUID()
        let first = RemoteQueueItem(id: UUID(), section: .current, track: track)
        let page = QueuePage(
            replyTo: request.header.id, revision: revision, offset: 0, total: 2, nextOffset: 1,
            items: [first])
        h.current.onEvent?(.message(.queue(.init(), page)))
        #expect(h.model.musicQueue == [first])
        h.model.requestMusicQueue(offset: 1)
        await settleTasks()
        let secondRequest = try #require(h.current.messages.last)
        let replacement = RemoteQueueItem(id: UUID(), section: .current, track: track)
        let restarted = QueuePage(
            replyTo: secondRequest.header.id, revision: UUID(), offset: 0, total: 1,
            nextOffset: nil, items: [replacement])
        h.current.onEvent?(.message(.queue(.init(), restarted)))
        #expect(h.model.musicQueue == [replacement])
        h.current.onEvent?(.message(.queue(.init(), page)))
        #expect(h.model.musicQueue == [replacement])
        h.model.returnToPlayers()
        h.current.onEvent?(.message(.queue(.init(), restarted)))
        #expect(h.model.musicQueue.isEmpty && !h.model.showsLikeOptions)
    }

    @Test func demoUnlikeRemovesMembershipButKeepsArtistsAndDuplicateQueueIdentity() throws {
        let model = RemoteAppModel(isDemo: true)
        model.start()
        model.select(try #require(model.players.first))
        model.enableMusicDemo()
        let current = try #require(model.state.music?.track)
        model.toggleMusicLike(trackId: current.id, currentlyLiked: model.state.music?.liked == true)
        model.send(.setTrackLiked(trackId: current.id, liked: true))
        let demo = try #require(model.musicDemo)
        let artists = demo.library.followedArtistIDs
        model.send(.setTrackLiked(trackId: current.id, liked: false))
        #expect(!demo.library.likedTrackIDs.contains(current.id))
        #expect(
            demo.library.playlists.filter { $0.isEditable(by: demo.library.userID) }.allSatisfy {
                !$0.trackIDs.contains(current.id)
            })
        #expect(demo.library.followedArtistIDs == artists)
        #expect(Set(model.musicQueue.map(\.id)).count == model.musicQueue.count)
        model.stop()
    }
    @Test func restrictedMusicControlsDoNotSendCommands() async {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        var state = musicState
        state.music?.disallowedActions = [
            "seeking", "resuming", "pausing", "toggling_shuffle", "volume",
        ]
        h.current.emit(state)
        h.model.seek(to: 12)
        h.model.togglePause()
        h.model.send(.setShuffle(shuffle: true))
        h.model.setVolume(50)
        await settleTasks()
        #expect(h.current.messages.isEmpty)
        state.source = .video
        state.music = nil
        h.current.emit(state)
        h.model.togglePause()
        await settleTasks()
        #expect(h.current.messages.count == 1)
    }

    private var track: RemoteMusicTrack {
        .init(
            id: "track", title: "Test", artists: ["Artist"], album: "Album", year: "2025",
            duration: 180)
    }
    private var musicState: PlayerState {
        .init(
            title: "Test", position: 42, duration: 180, paused: false, volume: 0, fullscreen: false,
            hasMedia: true, canNext: true, canPrevious: false, source: .music,
            music: .init(
                track: track, nextTrack: track, liked: false, shuffle: false, repeatMode: .off,
                queueCount: 2, queueRevision: UUID(), libraryRevision: UUID(),
                outputName: "Test Mac"))
    }
}
