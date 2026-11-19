import AVFoundation
import AppKit
import Foundation
import MediaPlayer
import MetaBrainzAPI
import RemoteProtocol
import Testing

@testable import Kinrox

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LocalAudioPlaybackTests {
    @Test func manualNextAndNaturalEOFEachAdvanceOneOccurrence() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let player = LocalAudioViewModel(artwork: ArtworkCache(directory: root), initialVolume: 0)
        let session = PlayerSession(
            recents: RecentFilesStore(fileURL: root.appendingPathComponent("recents.json")))
        session.playback.connect(video: nil, music: session.music, localAudio: player)
        let first = try wave("First", seconds: 4, directory: root)
        let second = try wave("Second", seconds: 0.7, directory: root)
        let third = try wave("Third", seconds: 5, directory: root)
        #expect(player.play([first, second, third]))
        await session.playback.settle()
        #expect(player.currentTrack?.title == "First")
        #expect(!player.paused)
        #expect(player.next())
        await session.playback.settle()
        #expect(player.currentTrack?.title == "Second")
        #expect(try await eventually { player.currentTrack?.title == "Third" && !player.paused })
        #expect(player.queue.history.map(\.track.title) == ["First", "Second"])
        #expect(player.volume == 0)
        await session.playback.close()
    }

    @Test func idleRetirementRestoresPositionAtZeroGainAndCloseReleasesEngine() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var engines: [FakeLocalAudioEngine] = []
        var gains: [Double] = []
        let player = LocalAudioViewModel(
            artwork: ArtworkCache(directory: root), initialVolume: 0, parkDelay: .milliseconds(35)
        ) { gain in
            if let previous = engines.last { #expect(previous.didShutdown) }
            let engine = FakeLocalAudioEngine()
            engines.append(engine)
            gains.append(gain)
            return engine
        }
        let session = PlayerSession(
            recents: RecentFilesStore(fileURL: root.appendingPathComponent("recents.json")))
        session.playback.connect(video: nil, music: session.music, localAudio: player)
        #expect(player.play([track("Example", in: root)]))
        await session.playback.settle()
        engines.first?.send(.position(42))
        #expect(try await eventually { player.position == 42 })
        #expect(player.setPaused(true))
        #expect(try await eventually { engines.first?.didShutdown == true })
        #expect(player.setPaused(false))
        await session.playback.settle()
        #expect(gains == [0, 0])
        #expect(engines.last?.loads == [42])
        #expect(!player.paused)
        await session.playback.beginClose().value
        #expect(engines.last?.didShutdown == true)
        #expect(player.currentTrack == nil)
    }

    @Test func remoteUsesStandardMediaStateAndCommandsWithoutExposingFileURIs() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recents = RecentFilesStore(fileURL: root.appendingPathComponent("recents.json"))
        let session = PlayerSession(recents: recents)
        let model = PlayerViewModel(engine: FakePlayerEngine())
        let player = LocalAudioViewModel(artwork: ArtworkCache(directory: root), initialVolume: 0) {
            _ in
            FakeLocalAudioEngine()
        }
        let server = RemoteServer(recents: recents, pairing: PairingCenter())
        session.playback.connect(video: model, music: session.music, localAudio: player)
        server.connect(to: model)
        server.connectLocalAudio(player) { session.playback.activeSource == .localAudio }
        #expect(player.play([track("Example", in: root), track("Next", in: root)]))
        await session.playback.settle()
        #expect(server.snapshot.hasMedia)
        #expect(server.snapshot.title == "Example")
        #expect(server.snapshot.source == .video)
        #expect(server.snapshot.music == nil)
        #expect(server.execute(.setPaused(paused: true)) == nil)
        #expect(player.paused)
        #expect(server.execute(.seekAbsolute(seconds: 24)) == nil)
        #expect(server.snapshot.position == 24)
        #expect(server.execute(.setVolume(volume: 0)) == nil)
        #expect(server.execute(.next) == nil)
        await session.playback.settle()
        #expect(server.snapshot.title == "Next")
        await session.playback.close()
        await model.shutdown()
    }

    @Test func startingVideoPausesLocalAudioAndHomeSearchOwnsUnmodifiedShortcuts() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = PlayerSession(
            recents: RecentFilesStore(fileURL: root.appendingPathComponent("recents.json")))
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine)
        session.model = model
        let player = LocalAudioViewModel(artwork: ArtworkCache(directory: root), initialVolume: 0) {
            _ in
            FakeLocalAudioEngine()
        }
        session.playback.connect(video: model, music: session.music, localAudio: player)
        #expect(player.play([track("Example", in: root)]))
        await session.playback.settle()
        #expect(!player.paused)
        #expect(model.open(url: root.appendingPathComponent("Movie.mkv")))
        await session.playback.settle()
        #expect(player.paused)
        #expect(engine.openedURLs.count == 1)
        session.isHomeSearchFocused = true
        #expect(!session.canControl)
        #expect(!session.trackShortcutsAllowed)
        session.leaveHomeSearch()
        #expect(session.trackShortcutsAllowed)
        session.isLibrarySheetShown = true
        #expect(!session.trackShortcutsAllowed)
        await session.playback.close()
        await model.shutdown()
    }

    @Test func matrixBlocksLocalTransportAndOpeningAnotherFileExitsIt() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recents = RecentFilesStore(fileURL: root.appendingPathComponent("recents.json"))
        let session = PlayerSession(recents: recents)
        let model = PlayerViewModel(engine: FakePlayerEngine())
        let player = LocalAudioViewModel(artwork: ArtworkCache(directory: root), initialVolume: 0) {
            _ in FakeLocalAudioEngine()
        }
        let server = RemoteServer(recents: recents, pairing: PairingCenter())
        session.playback.connect(video: model, music: session.music, localAudio: player)
        server.connect(to: model)
        server.connectLocalAudio(player) { session.playback.activeSource == .localAudio }

        #expect(model.startMatrix())
        #expect(player.play([track("First", in: root), track("Second", in: root)]))
        await session.playback.settle()
        #expect(model.screensaver == .off)
        #expect(!player.paused)
        #expect(model.startMatrix())
        #expect(model.isStartingScreensaver)
        #expect(server.execute(.setPaused(paused: false)) == .internal)
        let started = await withCheckedContinuation { continuation in
            model.startMatrix { continuation.resume(returning: $0) }
        }
        #expect(started)
        #expect(model.screensaver == .matrix)
        #expect(player.paused)
        #expect(server.execute(.togglePause) == .internal)
        #expect(server.execute(.seekAbsolute(seconds: 12)) == .internal)
        #expect(server.execute(.next) != nil)
        #expect(!player.performNowPlaying(.play, position: nil))
        #expect(!player.performNowPlaying(.nextTrack, position: nil))
        #expect(server.execute(.setPaused(paused: true)) == nil)
        #expect(server.execute(.setVolume(volume: 0)) == nil)
        await session.playback.settle()
        #expect(model.screensaver == .matrix)
        #expect(player.paused)
        #expect(player.currentTrack?.title == "First")
        #expect(player.position == 0)
        model.stopScreensaver()
        #expect(player.paused)
        #expect(player.performNowPlaying(.play, position: nil))
        await session.playback.settle()
        #expect(!player.paused)
        await session.playback.close()
        await model.shutdown()
    }

    @Test func adHocFileRetainsTagsWhenReturningToItsQueueOccurrence() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/M1Media/tagged.mp3")
        let file = root.appendingPathComponent("Untagged filename.mp3")
        try FileManager.default.copyItem(at: fixture, to: file)
        let library = MediaLibraryStore(limiter: MusicBrainzRateLimiter(), storage: (root, root))
        let player = LocalAudioViewModel(artwork: library.artwork, initialVolume: 0) {
            _ in FakeLocalAudioEngine()
        }
        #expect(player.play([file, root.appendingPathComponent("Next.wav")], using: library))
        #expect(try await eventually { player.currentTrack?.title == "Fixture title" })
        let expectedSize = try #require(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(player.currentTrack?.file.size == Int64(expectedSize))
        #expect(player.next())
        #expect(try await eventually { !player.loading && player.currentTrack?.title == "Next" })
        let original = try #require(player.queue.history.last)
        #expect(player.title(for: original.track) == "Fixture title")
        #expect(player.previous())
        #expect(
            try await eventually {
                !player.loading && player.currentTrack?.title == "Fixture title"
            })
        await player.shutdownPlayback()
    }

    @Test func localAudioAlertDoesNotExposeEngineDiagnostics() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostic = "Engine failure at \(root.path)"
        let engine = FakeLocalAudioEngine()
        engine.loadFailure = diagnostic
        let player = LocalAudioViewModel(artwork: ArtworkCache(directory: root), initialVolume: 0) {
            _ in engine
        }
        #expect(player.play([track("Example", in: root)]))
        #expect(try await eventually { player.errorMessage != nil })
        let alert = try #require(player.errorMessage)
        #expect(!alert.isEmpty)
        #expect(!alert.contains(root.path))
        await player.shutdownPlayback()
    }

    @Test func localCoverPublishesToNowPlayingAndSpotifyStartPausesLocalAudio() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let artwork = ArtworkCache(directory: root)
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.orange, atX: 1, y: 1)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let key = try #require(try await artwork.store(data))
        var media = track("Cover", in: root).file
        media.audio?.artworkPath = key
        let player = LocalAudioViewModel(artwork: artwork, initialVolume: 0) { _ in
            FakeLocalAudioEngine()
        }
        let music = MusicViewModel()
        let spotify = FakeMusicEngine()
        music.connect(engine: spotify)
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: music, localAudio: player)
        let center = FakeNowPlayingCenter()
        coordinator.connectNowPlaying(NowPlayingController(center: center))
        #expect(player.play([LocalAudioTrack(file: media, metadata: nil, isOffline: false)]))
        await coordinator.settle()
        #expect(try await eventually { player.artworkData != nil })
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
        #expect(center.send(.pause) == .success)
        #expect(player.paused)
        #expect(player.setPaused(false))
        await coordinator.settle()
        #expect(!player.paused)
        music.play(music.catalog.tracks)
        await coordinator.settle()
        #expect(player.paused)
        #expect(coordinator.activeSource == .music)
        #expect(spotify.commands.last != nil)
        await coordinator.close()
    }

    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<120 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KinroxLocalAudio-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func track(_ name: String, in directory: URL) -> LocalAudioTrack {
        let path = directory.appendingPathComponent(name + ".wav").path
        return LocalAudioTrack(
            file: MediaLibraryFile(
                path: path, size: 1, modified: Date(), added: Date(),
                audio: LocalAudioTags(title: name, duration: 60)),
            metadata: nil, isOffline: false)
    }

    private func wave(_ name: String, seconds: Double, directory: URL) throws -> LocalAudioTrack {
        let track = track(name, in: directory)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
        ]
        let file = try AVAudioFile(forWriting: track.file.url, settings: settings)
        let length = AVAudioFrameCount(seconds * 8_000)
        let samples = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: length))
        samples.frameLength = length
        samples.floatChannelData?[0].update(repeating: 0, count: Int(length))
        try file.write(from: samples)
        return track
    }
}

@MainActor
private final class FakeLocalAudioEngine: LocalAudioEngine {
    let events: AsyncStream<LocalAudioEvent>
    let continuation: AsyncStream<LocalAudioEvent>.Continuation
    var loads: [Double] = []
    var didShutdown = false
    var loadFailure: String?

    init() { (events, continuation) = AsyncStream.makeStream() }

    func load(_ url: URL, id: UUID, position: Double) throws {
        loads.append(position)
        send(loadFailure.map { .failed(id, $0) } ?? .loaded(id))
    }

    func setPaused(_ paused: Bool) throws {}
    func seek(_ position: Double) throws {}
    func setVolume(_ volume: Double) throws {}
    func send(_ event: LocalAudioEvent) { continuation.yield(event) }

    func shutdown() async {
        try? await Task.sleep(for: .milliseconds(30))
        didShutdown = true
        continuation.finish()
    }
}
