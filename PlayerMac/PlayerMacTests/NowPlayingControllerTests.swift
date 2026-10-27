import AppKit
import MediaPlayer
import Testing

@testable import Kinrox

@Suite("System playback center", .timeLimit(.minutes(1)))
@MainActor
struct NowPlayingControllerTests {
    private let episodes = (1...3).map { URL(fileURLWithPath: "/tmp/Series/E\($0).mkv") }

    private final class Clock {
        var now: TimeInterval = 100
    }

    private func makeModel(_ engine: FakePlayerEngine) -> PlayerViewModel {
        let items = episodes
        return PlayerViewModel(engine: engine) { url in FolderPlaylist(items: items, current: url) }
    }

    private func open(_ url: URL, in model: PlayerViewModel) async throws {
        model.open(url: url)
        model.receive(.started)
        model.receive(.loaded)
        for _ in 0..<100 where model.playlist?.current != url {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.playlist?.current == url)
    }

    @Test("Metadata, logo, late title, and pause are confirmed by engine")
    func metadataAndPause() async throws {
        let engine = FakePlayerEngine()
        let active = makeModel(engine)
        let center = FakeNowPlayingCenter()
        let controller = NowPlayingController(center: center)
        controller.connect(to: active)
        try await open(episodes[0], in: active)
        active.receive(.property(.title, .text("Episode 1")))
        active.receive(.property(.duration, .number(120)))
        active.receive(.property(.position, .number(12)))
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Episode 1")
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyArtist] as? String == "Series")
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double == 120)
        #expect(
            center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 12)
        #expect(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(
            center.nowPlayingInfo?[MPNowPlayingInfoPropertyMediaType] as? UInt
                == MPNowPlayingInfoMediaType.video.rawValue)
        let artwork = try #require(
            center.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        #expect(artwork.image(at: NSSize(width: 64, height: 64)) != nil)
        #expect(center.playbackState == .playing)
        #expect(center.send(.pause) == .success)
        #expect(center.playbackState == .playing)
        active.receive(.property(.position, .number(12.05)))
        active.receive(.property(.paused, .flag(true)))
        #expect(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(
            center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 12.05)
        #expect(center.playbackState == .paused)
        active.receive(.property(.paused, .flag(false)))
        #expect(center.playbackState == .playing)
        await active.shutdown()
    }

    @Test("Single file receives Kinrox artist and filename prior to media-title")
    func singleFile() async throws {
        let model = PlayerViewModel(engine: FakePlayerEngine()) {
            FolderPlaylist(items: [$0], current: $0)
        }
        let center = FakeNowPlayingCenter()
        let controller = NowPlayingController(center: center)
        controller.connect(to: model)
        try await open(episodes[0], in: model)
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "E1.mkv")
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyArtist] as? String == "Kinrox")
        #expect(!center.enabled.contains(.nextTrack) && !center.enabled.contains(.previousTrack))
        await model.shutdown()
    }

    @Test("50 regular ticks do not write dictionary; time jump writes exact position")
    func extrapolation() async {
        let model = makeModel(FakePlayerEngine())
        let center = FakeNowPlayingCenter()
        let clock = Clock()
        let controller = NowPlayingController(center: center, clock: { clock.now })
        controller.connect(to: model)
        model.receive(.loaded)
        model.receive(.property(.duration, .number(120)))
        let writes = center.infoWrites
        for step in 1...50 {
            clock.now = 100 + Double(step) / 10
            model.receive(.property(.position, .number(Double(step) / 10)))
        }
        #expect(center.infoWrites == writes)
        // UI might not have updated yet: center still uses latest time-pos.
        model.receive(.property(.position, .number(30)))
        #expect(center.infoWrites == writes + 1)
        #expect(
            center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 30)
        await model.shutdown()
    }

    @Test(
        "Short seek confirmed by restart and time-pos in either order",
        arguments: [true, false])
    func shortSeek(positionFirst: Bool) async {
        let model = makeModel(FakePlayerEngine())
        let center = FakeNowPlayingCenter()
        let controller = NowPlayingController(center: center, clock: { 100 })
        controller.connect(to: model)
        model.receive(.loaded)
        if positionFirst { model.receive(.property(.position, .number(0.5))) }
        model.receive(.playbackRestarted)
        if !positionFirst { model.receive(.property(.position, .number(0.5))) }
        #expect(
            center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 0.5)
        await model.shutdown()
    }

    @Test("Pause, playback, toggle, ±10, and scrubber reach engine")
    func commands() async {
        let engine = FakePlayerEngine()
        let model = makeModel(engine)
        let center = FakeNowPlayingCenter()
        let controller = NowPlayingController(center: center)
        controller.connect(to: model)
        model.receive(.loaded)
        model.receive(.property(.duration, .number(100)))
        #expect(center.send(.pause) == .success)
        #expect(center.send(.play) == .success)
        #expect(center.send(.togglePlayPause) == .success)
        #expect(center.send(.skipForward) == .success)
        #expect(center.send(.skipBackward) == .success)
        #expect(center.send(.changePlaybackPosition, position: 42) == .success)
        #expect(center.send(.changePlaybackPosition, position: 200) == .success)
        #expect(center.send(.changePlaybackPosition, position: -.infinity) == .commandFailed)
        #expect(center.send(.changePlaybackPosition) == .commandFailed)
        #expect(
            engine.commands == [
                .paused(true), .paused(false), .paused(true), .seekRelative(10), .seekRelative(-10),
                .seekAbsolute(42), .seekAbsolute(100),
            ])
        await model.shutdown()
    }

    @Test("Playlist boundaries, next and previous, metadata change")
    func playlistCommands() async throws {
        let engine = FakePlayerEngine()
        let model = makeModel(engine)
        let center = FakeNowPlayingCenter()
        let controller = NowPlayingController(center: center)
        controller.connect(to: model)
        try await open(episodes[0], in: model)
        #expect(!center.enabled.contains(.previousTrack))
        #expect(center.enabled.contains(.nextTrack))
        #expect(center.send(.previousTrack) == .commandFailed)
        #expect(center.send(.nextTrack) == .success)
        #expect(engine.openedURLs.last == episodes[1])
        model.receive(.started)
        #expect(center.nowPlayingInfo == nil)
        model.receive(.loaded)
        #expect(center.enabled.contains(.previousTrack) && center.enabled.contains(.nextTrack))
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "E2.mkv")
        #expect(center.send(.previousTrack) == .success)
        #expect(engine.openedURLs.last == episodes[0])
        try await open(episodes[2], in: model)
        #expect(center.enabled.contains(.previousTrack))
        #expect(!center.enabled.contains(.nextTrack))
        #expect(center.send(.nextTrack) == .commandFailed)
        model.receive(.property(.endReached, .flag(true)))
        #expect(center.playbackState == .paused)
        #expect(center.send(.play) == .success)
        #expect(engine.commands.suffix(2) == [.seekAbsolute(0), .paused(false)])
        await model.shutdown()
    }

    @Test("Empty center, file cleanup, shutdown, and reconnection")
    func lifecycle() async {
        let model = makeModel(FakePlayerEngine())
        let center = FakeNowPlayingCenter()
        let controller = NowPlayingController(center: center)
        controller.connect(to: model)
        #expect(center.nowPlayingInfo == nil && center.playbackState == .stopped)
        #expect(center.enabled.isEmpty)
        for command in NowPlayingCommand.allCases {
            #expect(center.send(command) == .noActionableNowPlayingItem)
        }
        model.receive(.loaded)
        model.receive(.ended(error: nil))
        #expect(center.nowPlayingInfo == nil && center.playbackState == .stopped)
        #expect(center.enabled.isEmpty)
        model.receive(.loaded)
        let stale = center.handler
        controller.disconnect()
        #expect(center.handler == nil && center.nowPlayingInfo == nil)
        #expect(center.playbackState == .stopped)
        let newModel = makeModel(FakePlayerEngine())
        controller.connect(to: newModel)
        newModel.receive(.loaded)
        #expect(stale?(.pause, nil) == .noActionableNowPlayingItem)
        await model.shutdown()
        #expect(center.playbackState == .playing)
        await newModel.shutdown()
        #expect(center.handler == nil && center.nowPlayingInfo == nil)
        #expect(center.playbackState == .stopped && center.enabled.isEmpty)
        newModel.receive(.loaded)
        #expect(center.nowPlayingInfo == nil)
    }

    @Test("Connecting empty model disables commands after installing handlers")
    func emptyConnectionDisablesCommands() async {
        let model = makeModel(FakePlayerEngine())
        let center = FakeNowPlayingCenter()
        center.enabledOnInstall = Set(NowPlayingCommand.allCases)
        let controller = NowPlayingController(center: center)
        controller.connect(to: model)
        #expect(center.handler != nil)
        #expect(center.enabled.isEmpty)
        model.receive(.loaded)
        #expect(center.enabled.contains(.play))
        let newModel = makeModel(FakePlayerEngine())
        controller.connect(to: newModel)
        #expect(center.handler != nil)
        #expect(center.enabled.isEmpty)
        await model.shutdown()
        await newModel.shutdown()
    }

    @Test("Command failure is returned to system, stale message does not interfere")
    func commandFailures() async throws {
        let engine = FakePlayerEngine()
        let model = makeModel(engine)
        let center = FakeNowPlayingCenter()
        let controller = NowPlayingController(center: center)
        controller.connect(to: model)
        try await open(episodes[0], in: model)
        engine.commandError = MPVError("Command rejected")
        #expect(center.send(.pause) == .commandFailed)
        #expect(center.send(.skipForward) == .commandFailed)
        #expect(center.send(.changePlaybackPosition, position: 1) == .commandFailed)
        #expect(model.errorMessage == "Command rejected")
        engine.commandError = nil
        #expect(center.send(.pause) == .success)
        engine.loadError = MPVError("File unavailable")
        #expect(center.send(.nextTrack) == .commandFailed)
        #expect(model.currentURL == episodes[0])
        await model.shutdown()
    }

    @Test("Handler on main and background thread returns synchronous status")
    func callbackIsolation() async {
        let handler: NowPlayingCommandHandler = { command, position in
            #expect(Thread.isMainThread)
            #expect(command == .changePlaybackPosition && position == 42)
            return .commandFailed
        }
        #expect(
            SystemNowPlayingCenter.deliver(.changePlaybackPosition, position: 42, to: handler)
                == .commandFailed)
        let status = await Task.detached {
            SystemNowPlayingCenter.deliver(.changePlaybackPosition, position: 42, to: handler)
        }.value
        #expect(status == .commandFailed)
    }

    @Test("MediaPlayer can request artwork from background queue without capturing MainActor")
    func backgroundArtwork() async throws {
        let image = try #require(NSImage(named: "KinroxLogo"))
        let data = try #require(image.tiffRepresentation)
        let size = image.size
        let valid = await Task.detached {
            let artwork = NowPlayingArtwork.make(data: data, size: size)
            return artwork.image(at: CGSize(width: 64, height: 64))?.isValid == true
        }.value
        #expect(valid)
    }
}
