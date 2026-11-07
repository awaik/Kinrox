import Foundation
import MusicCore
import RemoteProtocol
import SpotifyWebAPI
import Testing

@testable import Kinrox

@Suite("Standalone music model contracts", .timeLimit(.minutes(1)))
@MainActor
struct MusicStandaloneContractTests {
    @Test func wakeRequiresExplicitPlayAndRestoresThePreSleepPosition() async throws {
        let driver = FakeSoloistDriver()
        let runtime = SoloistRuntime(driver: driver)
        let engine = SoloistMusicEngine(runtime: runtime, observeSystemSleep: false)
        let model = MusicViewModel()
        try await engine.play(queue: model.queue, position: 35)
        engine.willSleep()
        await #expect(throws: SoloistFailure.unavailable) { try await engine.setPaused(false) }
        await engine.didWake()
        #expect(await driver.stops == 1)
        #expect(await driver.starts == 1)
        let paused = await runtime.confirmedSnapshot()
        #expect(paused.paused && paused.position >= 35 && paused.position < 36)
        try await engine.setPaused(false)
        #expect(await driver.starts == 2)
        #expect(await driver.overlaps == 0)
        #expect(await runtime.confirmedSnapshot().position >= 35)
        await engine.shutdown()
    }

    @Test func videoOpensWhenNativeMusicHasNeverStarted() async throws {
        let driver = FakeSoloistDriver()
        let runtime = SoloistRuntime(driver: driver)
        let music = MusicViewModel()
        music.queue.clear()
        music.connect(engine: SoloistMusicEngine(runtime: runtime))
        let videoEngine = FakePlayerEngine()
        let video = PlayerViewModel(engine: videoEngine)
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: video, music: music)
        let url = URL(fileURLWithPath: "/tmp/standalone-video.mkv")
        #expect(video.open(url: url))
        await coordinator.settle()
        #expect(videoEngine.openedURLs == [url])
        #expect(video.errorMessage == nil)
        #expect(music.engineAvailability == .ready)
        #expect(await driver.starts == 0)
        #expect(await driver.commands.isEmpty)
        await coordinator.close()
        await video.shutdown()
    }

    @Test func emptyQueueTransportDoesNotDispatch() async {
        let model = MusicViewModel()
        model.queue.clear()
        let engine = FakeMusicEngine()
        model.connect(engine: engine)
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: model)
        model.seek(10)
        model.stop()
        model.togglePause()
        model.next()
        model.previous()
        await coordinator.settle()
        #expect(engine.commands.isEmpty)
        #expect(model.nowPlayingCommands.isEmpty)
        #expect(!model.canTogglePause && !model.canSeek && !model.canStop)
        #expect(!model.canNext && !model.canPrevious && !model.canShuffle && !model.canRepeat)
        #expect(model.canPlayLibrary)
        model.play(model.catalog.tracks)
        await coordinator.settle()
        #expect(engine.commands.count == 1)
        await coordinator.close()
    }

    @Test func deviceStateIsPublishedWithoutMatchingOccurrence() async {
        let model = MusicViewModel()
        let item = model.queue.current
        model.volume = 10
        model.position = 12
        var notifications = 0
        let observation = model.observePlayback { _ in notifications += 1 }
        model.receive(
            .init(
                uri: "spotify:track:foreign", position: 90, duration: 180, paused: false,
                volume: 37, deviceName: "Owned output", occurrenceID: UUID()))
        #expect(model.volume == 37)
        #expect(model.outputName == "Owned output")
        #expect(model.position == 12)
        #expect(model.queue.current == item)
        #expect(notifications == 1)
        model.removePlaybackObserver(observation)
    }

    @Test func unknownVolumeAndFailedCommitNeverBecomeConfirmed() async {
        let model = MusicViewModel()
        let engine = FakeMusicEngine()
        model.connect(engine: engine)
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: model)
        #expect(!model.volumeKnown && !model.canAdjustVolume)
        #expect(model.effectiveDisallowedActions.contains("volume"))
        model.setVolume(40)
        await coordinator.settle()
        #expect(engine.commands.isEmpty)
        model.receive(
            .init(
                uri: nil, position: 0, duration: 0, paused: true,
                volume: 27, deviceName: "Output", occurrenceID: nil))
        #expect(model.volumeKnown && model.canAdjustVolume)
        engine.volumeError = SpotifyPlaybackError.unconfirmed
        model.setVolume(40)
        await coordinator.settle()
        #expect(engine.commands == [.volume(40)])
        #expect(model.volume == 27)
        #expect(model.statusMessage != nil)
        model.receive(
            .init(
                uri: nil, position: 0, duration: 0, paused: true,
                volume: nil, deviceName: "Output", occurrenceID: nil))
        #expect(model.volume == 27 && model.volumeKnown)
        await coordinator.close()
    }

    @Test func availabilityAndRetiredEventsCannotEnableControls() async {
        let model = MusicViewModel()
        let old = FakeMusicEngine()
        model.connect(engine: old)
        old.continuation.yield(.availability(.needsPairing))
        for _ in 0..<1000 where model.engineAvailability != .needsPairing { await Task.yield() }
        #expect(!model.canTogglePause && !model.canPlayLibrary && !model.canAdjustVolume)
        let replacement = FakeMusicEngine()
        model.connect(engine: replacement)
        old.continuation.yield(.availability(.failed("Retired")))
        old.continuation.yield(.failure("Retired"))
        replacement.continuation.yield(.availability(.ready))
        for _ in 0..<100 { await Task.yield() }
        #expect(model.engineAvailability == .ready)
        #expect(model.statusMessage == nil)
        await old.shutdown()
        await model.shutdownPlayback()
    }

    @Test func staleEndCannotAdvanceCurrentOccurrence() async throws {
        let model = MusicViewModel()
        let engine = FakeMusicEngine()
        model.connect(engine: engine)
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: model)
        let current = try #require(model.queue.current)
        engine.continuation.yield(.ended(occurrenceID: UUID()))
        // Ordered sentinel event proves the obsolete EOF has been consumed.
        engine.continuation.yield(.failure("Marker"))
        for _ in 0..<1000 where model.statusMessage != "Marker" { await Task.yield() }
        #expect(model.statusMessage == "Marker")
        await coordinator.settle()
        #expect(model.queue.current == current && engine.commands.isEmpty)
        await coordinator.close()
    }

    @Test func finishingOldShutdownCannotResetReplacementState() async throws {
        let model = MusicViewModel()
        let old = FakeMusicEngine()
        old.waitsForShutdown = true
        model.connect(engine: old)
        let shutdown = Task { await model.shutdownPlayback() }
        for _ in 0..<1000 where old.shutdownGate == nil { await Task.yield() }
        #expect(old.shutdownGate != nil)
        let replacement = FakeMusicEngine()
        model.connect(engine: replacement)
        model.receive(
            .init(
                uri: model.currentTrack?.uri, position: 11, duration: 120, paused: false,
                volume: 42, deviceName: "New output", occurrenceID: model.queue.current?.id))
        old.shutdownGate?.resume()
        old.shutdownGate = nil
        await shutdown.value
        #expect(model.musicEngine === replacement)
        #expect(!model.paused && model.volumeKnown && model.volume == 42)
        #expect(model.lastSnapshot?.deviceName == "New output")
        await model.shutdownPlayback()
    }

    @Test func legacyLANDisablesUnknownVolumeAndUnavailableTransport() async throws {
        let model = MusicViewModel()
        model.queue.clear()
        model.volume = 80
        model.volumeKnown = false
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: model)
        let bridge = RemoteMusicBridge(music: model, coordinator: coordinator)
        let state = bridge.snapshot(fullscreen: false, screensaver: .off)
        #expect(state.volume == 0)
        #expect(state.music?.volumeKnown == false)
        #expect(state.music?.disallowedActions?.contains("volume") == true)
        #expect(state.music?.disallowedActions?.contains("resuming") == true)
        #expect(!state.hasMedia && !state.canNext && !state.canPrevious)
        let message = Message.state(.init(), state)
        #expect(try Codec.decode(Codec.encode(message)) == message)
        #expect(Version.current == 1)
        bridge.disconnect()
        await coordinator.close()
    }

    @Test func remoteSnapshotEncodesWhenMusicVolumeUnknownAcrossModes() async throws {
        let defaults = try #require(UserDefaults(suiteName: "app.kinrox.tests.remote.\(UUID())"))
        let recents = RecentFilesStore()
        let session = PlayerSession(recents: recents, demoMusic: true, musicDefaults: defaults)
        let video = PlayerViewModel(engine: FakePlayerEngine())
        let remote = RemoteServer(
            defaults: defaults, store: MemoryPairedDevices(), recents: recents,
            pairing: session.pairing, serverName: "Test Mac")
        session.model = video
        session.remote = remote
        session.music.volumeKnown = false

        session.mode = .video
        let videoSnapshot = remote.snapshot
        #expect(videoSnapshot.source == .video && videoSnapshot.music == nil)
        let videoMessage = Message.state(.init(), videoSnapshot)
        #expect(try Codec.decode(Codec.encode(videoMessage)) == videoMessage)

        session.mode = .music
        let musicSnapshot = remote.snapshot
        #expect(musicSnapshot.source == .music && musicSnapshot.volume == 0)
        #expect(musicSnapshot.music?.volumeKnown == false)
        let musicMessage = Message.state(.init(), musicSnapshot)
        #expect(try Codec.decode(Codec.encode(musicMessage)) == musicMessage)

        session.model = nil
        let closedSnapshot = remote.snapshot
        #expect(closedSnapshot.source == .video && closedSnapshot.music == nil)
        #expect(!closedSnapshot.hasMedia && !closedSnapshot.canNext && closedSnapshot.paused)
        #expect(remote.execute(.togglePause) == .noMedia)

        await video.shutdown()
        await session.playback.close()
    }

    @Test(arguments: [MusicRepeat.off, .one, .all])
    func endOfFinalOccurrenceStopsOrRestarts(mode: MusicRepeat) async throws {
        let model = MusicViewModel()
        let track = try #require(model.currentTrack)
        model.queue.start([track])
        model.queue.repeatMode = mode
        model.paused = false
        model.position = track.duration
        let engine = FakeMusicEngine()
        model.connect(engine: engine)
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: model)
        let current = try #require(model.queue.current)
        engine.continuation.yield(.ended(occurrenceID: current.id))
        engine.continuation.yield(.failure("Marker"))
        for _ in 0..<1000 where model.statusMessage != "Marker" { await Task.yield() }
        await coordinator.settle()
        if mode == .off {
            #expect(engine.commands == [.stop])
            #expect(model.paused && model.position == 0)
            #expect(model.queue.current == current)
        } else {
            #expect(engine.commands == [.play(model.queue.items.map(\.id), 0)])
            #expect((model.queue.current?.id == current.id) == (mode == .one))
        }
        await coordinator.close()
    }

    @Test func automaticAdvanceSkipsUnplayableTracksAndStopsWhenRemainingAreRestricted()
        async throws
    {
        let model = MusicViewModel()
        let base = try #require(model.catalog.tracks.first)
        let playable1 = MusicTrack(
            id: "t1", uri: "spotify:track:1", title: "One", artists: base.artists,
            albumID: base.albumID, albumTitle: base.albumTitle, duration: 100, isPlayable: true)
        let restricted2 = MusicTrack(
            id: "t2", uri: "spotify:track:2", title: "Two", artists: base.artists,
            albumID: base.albumID, albumTitle: base.albumTitle, duration: 100, isPlayable: false)
        let playable3 = MusicTrack(
            id: "t3", uri: "spotify:track:3", title: "Three", artists: base.artists,
            albumID: base.albumID, albumTitle: base.albumTitle, duration: 100, isPlayable: true)
        let restricted4 = MusicTrack(
            id: "t4", uri: "spotify:track:4", title: "Four", artists: base.artists,
            albumID: base.albumID, albumTitle: base.albumTitle, duration: 100, isPlayable: false)
        model.queue.start([playable1, restricted2, playable3, restricted4])
        model.paused = false
        let engine = FakeMusicEngine()
        model.connect(engine: engine)
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: model)

        let firstID = try #require(model.queue.current?.id)
        engine.continuation.yield(.ended(occurrenceID: firstID))
        engine.continuation.yield(.failure("Marker1"))
        for _ in 0..<1000 where model.statusMessage != "Marker1" { await Task.yield() }
        await coordinator.settle()
        #expect(model.currentTrack?.id == "t3")
        #expect(engine.commands.count == 1)

        let thirdID = try #require(model.queue.current?.id)
        engine.continuation.yield(.ended(occurrenceID: thirdID))
        engine.continuation.yield(.failure("Marker2"))
        for _ in 0..<1000 where model.statusMessage != "Marker2" { await Task.yield() }
        await coordinator.settle()
        #expect(engine.commands.last == .stop)
        #expect(model.paused && model.position == 0)
        await coordinator.close()
    }

    @Test func resumingStoppedOccurrenceAtTrackEndAdvancesQueue() async throws {
        let model = MusicViewModel()
        let tracks = Array(model.catalog.tracks.prefix(2))
        #expect(tracks.count == 2)
        model.queue.start(tracks)
        let first = try #require(model.queue.current)
        let engine = FakeMusicEngine()
        model.connect(engine: engine)
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: model)
        model.receive(
            .init(
                uri: first.track.uri, position: first.track.duration - 0.4,
                duration: first.track.duration, paused: true, volume: 0,
                deviceName: "Mac", occurrenceID: first.id))
        model.engineAvailability = .failed("Soloist playback stopped.")
        model.togglePause()
        await coordinator.settle()
        #expect(model.currentTrack?.id == tracks[1].id)
        #expect(engine.commands == [.play(model.queue.items.map(\.id), 0)])
        await coordinator.close()
    }
}

extension SpotifyLibraryTests {
    @Test(arguments: [false, true])
    func standaloneBaselineHasNoExternalDevice(volume: Bool) async throws {
        let replies: [MusicHTTPStub.Reply] =
            volume
            ? [.init(body: #"{"devices":[]}"#)]
            : [.init(status: 204), .init(body: #"{"devices":[]}"#)]
        let client = connectClient(replies)
        let engine = SpotifyConnectMusicEngine(
            client: client, clientID: "test", userID: "owner",
            defaults: try #require(UserDefaults(suiteName: "app.kinrox.tests.\(UUID())")),
            localDeviceName: "Test Mac")
        var queue = MusicQueue()
        queue.start([connectTrack])
        await #expect(throws: SpotifyError.noDevice) {
            if volume {
                try await engine.setVolume(0)
            } else {
                try await engine.play(queue: queue, position: 0)
            }
        }
        #expect(!MusicHTTPStub.state.requests.contains { $0.httpMethod != "GET" })
        await engine.shutdown()
        await client.close()
    }

    @Test func confirmedDeviceVolumeSurvivesOutsideHelperContext() async throws {
        let client = connectClient([
            .init(body: devices), .init(status: 204),
            .init(
                body: playback(playing: false).replacingOccurrences(
                    of: "spotify:playlist:helper", with: "spotify:album:elsewhere")),
        ])
        let engine = SpotifyConnectMusicEngine(
            client: client, clientID: "test", userID: "owner",
            defaults: try #require(UserDefaults(suiteName: "app.kinrox.tests.\(UUID())")),
            localDeviceName: "Test Mac", confirmationDelays: [.milliseconds(1)])
        try await engine.setVolume(0)
        #expect(engine.lastState?.volume == 0)
        #expect(engine.lastState?.occurrenceID == nil)
        await engine.shutdown()
        await client.close()
    }
}
