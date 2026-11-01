import Foundation
import MediaPlayer
import MusicCore
import Testing

@testable import Kinrox

@Suite("Music playback coordination", .timeLimit(.minutes(1)))
@MainActor
struct MusicPlaybackTests {
    @Test func musicWaitsForConfirmedVideoPause() async throws {
        let engine = FakePlayerEngine()
        let video = PlayerViewModel(engine: engine)
        video.receive(.loaded)
        video.receive(.property(.paused, .flag(false)))
        let music = MusicViewModel()
        let musicEngine = FakeMusicEngine()
        music.connect(engine: musicEngine)
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: video, music: music)
        music.play(music.catalog.tracks)
        for _ in 0..<100 where !engine.commands.contains(.paused(true)) { await Task.yield() }
        #expect(engine.commands.contains(.paused(true)))
        #expect(musicEngine.commands.isEmpty)
        video.receive(.property(.paused, .flag(true)))
        await coordinator.settle()
        #expect(musicEngine.commands.count == 1)
        #expect(coordinator.activeSource == .music)
        #expect(music.paused)  // No optimistic playback state.
        await coordinator.close()
        await video.shutdown()
    }

    @Test func videoWaitsForMusicPauseAndFailureBlocksIt() async throws {
        let engine = FakePlayerEngine()
        let video = PlayerViewModel(engine: engine)
        let music = MusicViewModel()
        let musicEngine = FakeMusicEngine()
        musicEngine.waitsForPause = true
        music.connect(engine: musicEngine)
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: video, music: music)
        let url = URL(fileURLWithPath: "/tmp/coordination.mkv")
        #expect(video.open(url: url))
        for _ in 0..<100 where musicEngine.pauseGate == nil { await Task.yield() }
        #expect(engine.openedURLs.isEmpty)
        musicEngine.pauseGate?.resume()
        musicEngine.pauseGate = nil
        await coordinator.settle()
        #expect(engine.openedURLs == [url])
        musicEngine.waitsForPause = false
        musicEngine.pauseError = PlaybackTransitionError.pauseRejected
        video.open(url: URL(fileURLWithPath: "/tmp/blocked.mkv"))
        await coordinator.settle()
        #expect(engine.openedURLs == [url])
        #expect(video.errorMessage != nil)
        await coordinator.close()
        await video.shutdown()
    }

    @Test func queuedVideoStartCannotOvertakePendingMusicRequest() async throws {
        let video = PlayerViewModel(engine: FakePlayerEngine())
        let music = MusicViewModel()
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: video, music: music)
        var gate: CheckedContinuation<Void, Never>?
        var order: [String] = []
        coordinator.start(.music) {
            order.append("music requested")
            await withCheckedContinuation { gate = $0 }
            order.append("music confirmed")
        }
        for _ in 0..<100 where gate == nil { await Task.yield() }
        coordinator.start(.video) { order.append("video started") }
        #expect(order == ["music requested"])
        gate?.resume()
        await coordinator.settle()
        #expect(order == ["music requested", "music confirmed", "video started"])
        #expect(music.paused)
        await coordinator.close()
        await video.shutdown()
    }

    @Test func oneNowPlayingSessionUsesConfirmedMusicAndRoutesMediaKeys() async throws {
        let music = MusicViewModel()
        let engine = FakeMusicEngine()
        music.connect(engine: engine)
        let center = FakeNowPlayingCenter()
        let controller = NowPlayingController(center: center)
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: music)
        coordinator.connectNowPlaying(controller)
        music.play(music.catalog.tracks)
        await coordinator.settle()
        let item = try #require(music.queue.current)
        music.receive(
            MusicPlaybackSnapshot(
                uri: item.track.uri, position: 42, duration: 120,
                paused: false, volume: 0, deviceName: "Test Mac", occurrenceID: item.id))
        #expect(center.playbackState == .playing)
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == item.track.title)
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil)
        #expect(
            center.nowPlayingInfo?[MPNowPlayingInfoPropertyMediaType] as? UInt
                == MPNowPlayingInfoMediaType.audio.rawValue)
        #expect(center.send(.pause) == .success)
        await coordinator.settle()
        #expect(engine.commands.last == .pause(true))
        #expect(center.playbackState == .playing)
        await coordinator.close()
        #expect(engine.shutdownCount == 1)
        #expect(center.nowPlayingInfo == nil)
    }

    @Test func reopenedWindowWaitsForRetiringMusicEngine() async {
        let oldVideo = PlayerViewModel(engine: FakePlayerEngine())
        let newVideo = PlayerViewModel(engine: FakePlayerEngine())
        let music = MusicViewModel()
        let engine = FakeMusicEngine()
        music.connect(engine: engine)
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: oldVideo, music: music)
        var gate: CheckedContinuation<Void, Never>?
        coordinator.start(.music) { await withCheckedContinuation { gate = $0 } }
        for _ in 0..<100 where gate == nil { await Task.yield() }
        let close = coordinator.beginClose()
        coordinator.connect(video: newVideo, music: music)
        var startedAfterShutdown = false
        coordinator.start(.video) { startedAfterShutdown = engine.shutdownCount == 1 }
        #expect(!startedAfterShutdown)
        gate?.resume()
        await close.value
        await coordinator.settle()
        #expect(startedAfterShutdown)
        #expect(newVideo.beforeStartingPlayback != nil)
        await coordinator.close()
        await oldVideo.shutdown()
        await newVideo.shutdown()
    }
}
