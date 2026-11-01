import Foundation
import MusicCore
import RemoteProtocol
import Testing

@testable import Kinrox

@MainActor
struct RemoteMusicTests {
    @Test func queuePagesFitFramesAndRestartAfterReorder() async throws {
        let music = MusicViewModel()
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: music)
        let track = try #require(music.catalog.tracks.first)
        music.play(Array(repeating: track, count: 55))
        await coordinator.settle()
        let bridge = RemoteMusicBridge(music: music, coordinator: coordinator)
        guard case .queue(_, let first) = bridge.queuePage(.init(), replyTo: UUID()) else {
            Issue.record("Missing page")
            return
        }
        #expect(first.items.count == 20 && first.total == 55 && first.nextOffset == 20)
        #expect(Set(first.items.map(\.id)).count == 20)
        #expect(try Codec.encode(.queue(.init(), first)).count <= Codec.maxMessageBytes - 28)
        music.moveQueue(music.queue.upcoming.last!.id, before: music.queue.upcoming[0].id)
        await coordinator.settle()
        guard
            case .queue(_, let restarted) = bridge.queuePage(
                .init(offset: 20, revision: first.revision), replyTo: UUID())
        else {
            Issue.record("Missing page")
            return
        }
        #expect(restarted.offset == 0 && restarted.revision != first.revision)
        bridge.disconnect()
        await coordinator.close()
    }

    @Test func favoritesStayConfirmedAndNeverExposeForeignPlaylists() async throws {
        let music = MusicViewModel()
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: music)
        music.play(music.catalog.tracks)
        await coordinator.settle()
        let bridge = RemoteMusicBridge(music: music, coordinator: coordinator)
        let track = try #require(music.currentTrack)
        let oldLiked = bridge.state.liked
        #expect(bridge.execute(.setTrackLiked(trackId: track.id, liked: !oldLiked)) == nil)
        #expect(bridge.state.liked == oldLiked)
        for _ in 0..<100 where music.isMutating { await Task.yield() }
        #expect(bridge.state.liked != oldLiked)
        guard
            case .likeOptions(_, let options) = bridge.likeOptionsPage(
                .init(trackId: track.id), replyTo: UUID())
        else {
            Issue.record("Missing options")
            return
        }
        #expect(
            options.items.filter { $0.kind == .playlist }.allSatisfy { option in
                music.store.library.playlists.contains {
                    $0.id == option.id && $0.isEditable(by: music.store.library.userID)
                }
            })
        #expect(
            bridge.execute(
                .setPlaylistMembership(trackId: track.id, playlistId: "foreign", included: true))
                == .itemNotFound)
        bridge.disconnect()
        await coordinator.close()
    }
}
