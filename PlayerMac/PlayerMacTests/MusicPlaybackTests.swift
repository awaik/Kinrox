import Foundation
import MediaPlayer
import MusicCore
import Testing

@testable import Kinrox

@Suite("Music playback coordination", .timeLimit(.minutes(1)))
@MainActor
struct MusicPlaybackTests {
    @Test(arguments: ["volume", "seek", "pause"])
    func engineReplacementDiscardsFailedMutationAndLoadsCurrentOccurrence(command: String)
        async throws
    {
        let model = MusicViewModel()
        let old = FakeMusicEngine()
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: model)
        model.connect(engine: old)
        let item = try #require(model.queue.current)
        model.receive(
            .init(
                uri: item.track.uri, position: 35, duration: item.track.duration, paused: true,
                volume: 0, deviceName: "Mac", occurrenceID: item.id))
        old.volumeError = SoloistFailure.unavailable
        old.seekError = SoloistFailure.unavailable
        old.pauseError = SoloistFailure.unavailable
        switch command {
        case "volume": model.setVolume(25)
        case "seek": model.seek(25)
        default: model.setPaused(true)
        }
        await coordinator.settle()
        #expect(model.retryPlayback != nil)
        await model.shutdownPlayback()
        #expect(model.retryPlayback == nil)
        #expect(model.pendingVolume == nil && model.pendingSeek == nil)
        let replacement = FakeMusicEngine()
        model.connect(engine: replacement)
        if let retry = model.retryPlayback { retry() } else { model.setPaused(false) }
        await coordinator.settle()
        #expect(replacement.commands == [.play(model.queue.items.map(\.id), 35)])
        await coordinator.close()
    }

    @Test func engineReplacementPreservesFailedNewQueueStart() async throws {
        let model = MusicViewModel()
        let old = FakeMusicEngine()
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: model)
        model.connect(engine: old)
        old.playError = SoloistFailure.unavailable
        let track = try #require(model.catalog.tracks.last)
        model.play([track])
        await coordinator.settle()
        #expect(model.retryPlayback != nil)
        await model.shutdownPlayback()
        #expect(model.retryPlayback != nil)
        let replacement = FakeMusicEngine()
        model.connect(engine: replacement)
        model.retryPlayback?()
        await coordinator.settle()
        #expect(model.currentTrack == track)
        #expect(replacement.commands == [.play(model.queue.items.map(\.id), 0)])
        await coordinator.close()
    }

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

@MainActor
struct MusicProgressClockTests {
    @Test func localClockLeavesConfirmedAnchorUntouched() {
        let model = MusicViewModel()
        model.paused = false
        model.position = 10
        model.lastPositionTimestamp = .now.advanced(by: .seconds(-20))
        #expect(model.position == 10)
        #expect(model.displayedPosition >= 30 && model.displayedPosition < 31)
        model.paused = true
        #expect(model.displayedPosition == 10)
    }
    @Test(arguments: [false, true]) func slidersOnlyDispatchFirstAndLatest(seek: Bool) async throws
    {
        let model = MusicViewModel()
        let engine = FakeMusicEngine()
        model.connect(engine: engine)
        model.receive(
            .init(
                uri: nil, position: 0, duration: 0, paused: true,
                volume: 0, deviceName: "Test output", occurrenceID: nil))
        engine.waitsForSlider = true
        if seek { model.seek(10) } else { model.setVolume(10) }
        for _ in 0..<1000 where engine.sliderGate == nil { await Task.yield() }
        #expect(engine.sliderGate != nil)
        for value in 11...90 {
            if seek { model.seek(Double(value)) } else { model.setVolume(Double(value)) }
        }
        #expect(engine.commands == [seek ? .seek(10) : .volume(10)])
        engine.waitsForSlider = false
        engine.sliderGate?.resume()
        engine.sliderGate = nil
        for _ in 0..<1000 where model.seekScheduled || model.volumeScheduled { await Task.yield() }
        #expect(
            engine.commands == [seek ? .seek(10) : .volume(10), seek ? .seek(90) : .volume(90)])
        await model.shutdownPlayback()
    }
}

extension MusicProgressClockTests {
    @Test func queueEditsDoNotResetTheConfirmedPositionClock() async throws {
        let model = MusicViewModel()
        let engine = FakeMusicEngine()
        model.connect(engine: engine)
        let track = try #require(model.currentTrack)
        model.receive(
            .init(
                uri: track.uri, position: 10, duration: track.duration, paused: false,
                volume: 0, deviceName: "Mac", occurrenceID: model.queue.current?.id))
        model.lastPositionTimestamp = .now.advanced(by: .seconds(-20))
        model.addToQueue(track)
        for _ in 0..<1000 where engine.commands.isEmpty || model.isPlaybackBusy {
            await Task.yield()
        }
        #expect(model.position == 10)
        #expect(model.displayedPosition >= 30)
        await model.shutdownPlayback()
    }
}
