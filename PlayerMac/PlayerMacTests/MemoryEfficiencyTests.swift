import AppKit
import Foundation
import Testing

@testable import Kinrox

@Suite(
    "Memory efficiency: lazy mpv, parking, and Soloist session release", .serialized,
    .timeLimit(.minutes(1)))
@MainActor
struct MemoryEfficiencyTests {
    @Test("LazyMPVPlayer defers initialization until load and releases engine on stop and park")
    func lazyMPVPlayerLifecycle() async throws {
        let engine = LazyMPVPlayer()
        #expect(!engine.isActive)
        #expect(engine.videoLayer == nil)

        try engine.setVolume(0)
        #expect(!engine.isActive)

        // Invalid path must fail before constructing libmpv or OpenGL.
        #expect(throws: (any Error).self) {
            try engine.load(url: URL(fileURLWithPath: "/kinrox-missing-\(UUID()).mkv"))
        }
        #expect(!engine.isActive)
        #expect(engine.videoLayer == nil)

        let model = PlayerViewModel(engine: engine)
        let host = VideoHostView(videoLayer: engine.videoLayer)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 640, height: 360),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .floating
        window.orderFrontRegardless()
        do {
            #expect(model.open(url: try media("h264.mp4")))
            #expect(engine.isActive)
            let firstLayer = try #require(engine.videoLayer)
            host.setVideoLayer(firstLayer)
            try await waitUntil { model.hasMedia && model.position > 0.25 }
            #expect(model.playbackVolume == 0)
            #expect(firstLayer.resources.renderedFrameCount > 2)

            // Closing video releases libmpv and detaches the OpenGL layer.
            #expect(model.closeVideo())
            host.setVideoLayer(engine.videoLayer)
            #expect(!engine.isActive)
            #expect(engine.videoLayer == nil)
            #expect(!model.hasMedia)

            // Reopening creates a fresh engine and preserves remembered volume.
            #expect(model.open(url: try media("h264.mp4")))
            let secondLayer = try #require(engine.videoLayer)
            #expect(secondLayer !== firstLayer)
            host.setVideoLayer(secondLayer)
            try await waitUntil { model.hasMedia && model.position > 0.25 }
            #expect(model.playbackVolume == 0)
            #expect(secondLayer.resources.renderedFrameCount > 2)
        } catch {
            window.close()
            await model.shutdown()
            throw error
        }
        window.close()
        await model.shutdown()
        #expect(!engine.isActive)
        #expect(engine.videoLayer == nil)
    }

    @Test("Paused video parks after idle timeout, preserves state, and unparks on resume or return")
    func idleParkingAndTransparentUnpark() async throws {
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(
            engine: engine, playlistProvider: { FolderPlaylist(items: [$0], current: $0) })
        #expect(model.idleParkDelay == .seconds(30 * 60))
        model.idleParkDelay = .milliseconds(40)

        var recorded: [WatchProgress] = []
        model.writeWatchProgress = { recorded.append($0) }

        let url = URL(fileURLWithPath: "/tmp/Episode.mkv")
        #expect(model.open(url: url))
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.property(.title, .text("Episode")))
        model.receive(.property(.duration, .number(1200)))
        model.receive(.property(.position, .number(42.5)))
        model.receive(.property(.paused, .flag(false)))

        // Playing video must never park.
        try await Task.sleep(for: .milliseconds(80))
        #expect(!model.isParked)
        #expect(engine.parkCount == 0)

        // Pausing schedules parking after the idle delay.
        model.receive(.property(.paused, .flag(true)))
        try await waitUntil { model.isParked }
        #expect(engine.parkCount == 1)
        #expect(model.hasMedia)
        #expect(model.paused)
        #expect(model.position == 42.5)
        #expect(model.duration == 1200)
        #expect(model.displayTitle == "Episode")
        #expect(recorded.last?.position == 42.5)

        // Show Home and seek while parked in Home must not wake the engine.
        #expect(model.showHome())
        #expect(model.isShowingHome)
        let loadCountBeforeSeek = engine.openedURLs.count
        #expect(model.seek(by: 10))
        #expect(model.position == 52.5)
        #expect(model.isParked)
        #expect(engine.openedURLs.count == loadCountBeforeSeek)

        // Returning to video from Home unparks paused at the updated position.
        #expect(model.returnToVideo())
        #expect(!model.isParked)
        #expect(!model.isShowingHome)
        #expect(engine.openedURLs.count == loadCountBeforeSeek + 1)
        #expect(engine.commands.contains(.paused(true)))
        model.receive(.started)
        model.receive(.loaded)
        #expect(engine.commands.contains(.seekAbsolute(52.5)))

        // Park again and verify Play unparks and starts playback immediately.
        model.receive(.property(.position, .number(52.5)))
        model.receive(.property(.paused, .flag(true)))
        try await waitUntil { model.isParked }
        #expect(engine.parkCount == 2)

        let loadsBeforePlay = engine.openedURLs.count
        #expect(model.setPaused(false))
        #expect(!model.isParked)
        #expect(engine.openedURLs.count == loadsBeforePlay + 1)
        model.receive(.started)
        model.receive(.loaded)
        #expect(engine.commands.last == .seekAbsolute(52.5))

        await model.shutdown()
    }

    @Test("Parked video at EOF restarts from beginning on Play and closes cleanly")
    func parkedEOFAndClose() async throws {
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(
            engine: engine, playlistProvider: { FolderPlaylist(items: [$0], current: $0) })
        model.idleParkDelay = .milliseconds(40)

        let url = URL(fileURLWithPath: "/tmp/Final.mkv")
        #expect(model.open(url: url))
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.property(.duration, .number(600)))
        model.receive(.property(.position, .number(600)))
        model.receive(.property(.endReached, .flag(true)))

        try await waitUntil { model.isParked }
        #expect(engine.parkCount == 1)

        // Play on parked EOF restarts from 0 rather than seeking to end.
        let loadsBeforePlay = engine.openedURLs.count
        #expect(model.togglePause())
        #expect(!model.isParked)
        #expect(engine.openedURLs.count == loadsBeforePlay + 1)
        model.receive(.started)
        model.receive(.loaded)
        #expect(!engine.commands.contains(.seekAbsolute(600)))

        // Park once more and verify closeVideo clears state without calling stop().
        model.receive(.property(.position, .number(10)))
        model.receive(.property(.paused, .flag(true)))
        try await waitUntil { model.isParked }
        let stopsBeforeClose = engine.commands.filter { $0 == .stop }.count
        #expect(model.closeVideo())
        #expect(!model.hasMedia)
        #expect(!model.isParked)
        #expect(engine.commands.filter { $0 == .stop }.count == stopsBeforeClose)

        await model.shutdown()
    }

    @Test(
        "SoloistProcessSupervisor releases URLSession on stop so WebSocket tasks do not accumulate")
    func soloistStopReleasesURLSession() async {
        let root = URL(fileURLWithPath: "/tmp")
        let config = SoloistProcessSupervisor.Configuration(
            installation: .init(
                binary: root.appendingPathComponent("soloist"), digest: "", version: "1.0",
                buildDate: Date()),
            profile: root, cache: root, reaper: root, hostRequirement: "", deviceName: "Test",
            key: { "" })
        let supervisor = SoloistProcessSupervisor(config: config)
        let first = await supervisor.activeSession()
        await supervisor.stop()
        let second = await supervisor.activeSession()
        #expect(first !== second)
        await supervisor.close()
    }

    @Test("Failed open while parked preserves parked video and Home state")
    func failedOpenPreservesParkedVideo() async throws {
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(
            engine: engine, playlistProvider: { FolderPlaylist(items: [$0], current: $0) })
        model.idleParkDelay = .milliseconds(30)

        let original = URL(fileURLWithPath: "/tmp/Original.mkv")
        #expect(model.open(url: original))
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.property(.duration, .number(300)))
        model.receive(.property(.position, .number(45)))
        model.receive(.property(.paused, .flag(true)))
        #expect(model.showHome())
        try await waitUntil { model.isParked }

        engine.loadError = MPVError("File unavailable")
        #expect(!model.open(url: URL(fileURLWithPath: "/tmp/Missing.mkv")))
        #expect(model.errorMessage == "File unavailable")
        #expect(model.hasMedia)
        #expect(model.isParked)
        #expect(model.isShowingHome)

        engine.loadError = nil
        #expect(model.setPaused(false))
        #expect(!model.isParked)
        #expect(engine.openedURLs.last == original)
        await model.shutdown()
    }

    @Test("Cold load ignores initial idle-active before started")
    func coldLoadIgnoresInitialIdle() async {
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(
            engine: engine, playlistProvider: { FolderPlaylist(items: [$0], current: $0) })
        #expect(model.open(url: URL(fileURLWithPath: "/tmp/Cold.mkv")))
        #expect(model.isLoading)
        model.receive(.property(.idle, .flag(true)))
        #expect(model.isLoading)
        model.receive(.started)
        model.receive(.loaded)
        #expect(model.hasMedia && !model.isLoading)
        await model.shutdown()
    }

    @Test("Returning to parked EOF video preserves EOF for Play and clears it on seek")
    func parkedEOFReturnPreservesRestart() async throws {
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(
            engine: engine, playlistProvider: { FolderPlaylist(items: [$0], current: $0) })
        model.idleParkDelay = .milliseconds(30)

        let url = URL(fileURLWithPath: "/tmp/Short.mkv")
        #expect(model.open(url: url))
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.property(.duration, .number(12)))
        model.receive(.property(.position, .number(11.967)))
        model.receive(.property(.endReached, .flag(true)))
        #expect(model.showHome())
        model.receive(.property(.paused, .flag(true)))
        try await waitUntil { model.isParked }

        // Back to Video unparks paused and preserves isAtEnd even if mpv reports eof=false on seek.
        #expect(model.returnToVideo())
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.property(.paused, .flag(true)))
        model.receive(.property(.endReached, .flag(false)))
        #expect(model.isAtEnd)

        // Pressing Play restarts from 0.
        #expect(model.togglePause())
        #expect(engine.commands.contains(.seekAbsolute(0)))
        #expect(engine.commands.last == .paused(false))
        model.receive(.property(.paused, .flag(false)))
        model.receive(.property(.endReached, .flag(false)))

        // Explicit seek clears restored EOF state.
        model.receive(.property(.endReached, .flag(true)))
        try await waitUntil { model.isParked }
        #expect(model.returnToVideo())
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.property(.paused, .flag(true)))
        #expect(model.isAtEnd)
        #expect(model.seek(to: 4))
        #expect(!model.isAtEnd)
        await model.shutdown()
    }

    @Test("Visible video surface prevents parking; hiding allows parking; showing restores frame")
    func videoVisibilityControlsParking() async throws {
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(
            engine: engine, playlistProvider: { FolderPlaylist(items: [$0], current: $0) })
        model.idleParkDelay = .milliseconds(40)
        model.setVideoSurfaceVisible(true)

        #expect(model.open(url: URL(fileURLWithPath: "/tmp/Visible.mkv")))
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.property(.position, .number(20)))
        model.receive(.property(.paused, .flag(true)))

        try await Task.sleep(for: .milliseconds(90))
        #expect(!model.isParked)

        model.setVideoSurfaceVisible(false)
        try await waitUntil { model.isParked }
        #expect(engine.parkCount == 1)

        // Bringing the video surface back automatically unparks paused.
        let loads = engine.openedURLs.count
        model.setVideoSurfaceVisible(true)
        #expect(!model.isParked)
        #expect(engine.openedURLs.count == loads + 1)
        await model.shutdown()
    }

    @Test("Parking preserves external subtitle and subtitle-off selection when remember is off")
    func parkingPreservesTrackSelectionWithoutFolderRemember() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinrox-track-park-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let video = dir.appendingPathComponent("Movie.mkv")
        let srt = dir.appendingPathComponent("Custom.srt")
        try Data().write(to: video)
        try Data("1\n00:00:00,000 --> 00:00:01,000\nHi\n".utf8).write(to: srt)

        let engine = FakePlayerEngine()
        let model = PlayerViewModel(
            engine: engine, playlistProvider: { FolderPlaylist(items: [$0], current: $0) })
        model.idleParkDelay = .milliseconds(30)

        #expect(model.open(url: video))
        model.receive(.started)
        model.receive(.loaded)
        let embeddedAudio = MediaTrack(
            number: 1, kind: .audio, title: "English", language: "eng", codec: "aac",
            isDefault: true, isSelected: true, externalURL: nil)
        let externalSub = MediaTrack(
            number: 2, kind: .subtitle, title: "Custom.srt", language: "", codec: "subrip",
            isDefault: false, isSelected: true, externalURL: srt)
        model.receive(.tracksLoaded(path: video.path, tracks: [embeddedAudio, externalSub]))
        model.trackController.setRemember(false)
        model.receive(.property(.paused, .flag(true)))
        try await waitUntil { model.isParked }

        // Unpark and verify external SRT is re-added even with remember == false.
        #expect(model.returnToVideo())
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.tracksLoaded(path: video.path, tracks: [embeddedAudio]))
        let added = engine.commands.contains {
            if case .addTrack(let addedURL, .subtitle, _) = $0 {
                return VideoFiles.key(addedURL) == VideoFiles.key(srt)
            }
            return false
        }
        #expect(added)

        // Park with subtitles disabled (Off) and verify unpark disables default subtitle.
        let embeddedSub = MediaTrack(
            number: 3, kind: .subtitle, title: "Default", language: "eng", codec: "subrip",
            isDefault: true, isSelected: false, externalURL: nil)
        model.receive(.tracksLoaded(path: video.path, tracks: [embeddedAudio, embeddedSub]))
        model.receive(.property(.paused, .flag(true)))
        try await waitUntil { model.isParked }
        #expect(model.returnToVideo())
        model.receive(.started)
        model.receive(.loaded)
        let autoSelectedSub = MediaTrack(
            number: 3, kind: .subtitle, title: "Default", language: "eng", codec: "subrip",
            isDefault: true, isSelected: true, externalURL: nil)
        model.receive(.tracksLoaded(path: video.path, tracks: [embeddedAudio, autoSelectedSub]))
        let disabled = engine.commands.contains {
            if case .selectTrack(.subtitle, nil, _) = $0 { return true }
            return false
        }
        #expect(disabled)
        await model.shutdown()
    }

    @Test("Library resume with showTracks skips source switch and preserves short position")
    func resumeShowTracksSkipsSourceSwitchAndPreservesShortPosition() async throws {
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(
            engine: engine, playlistProvider: { FolderPlaylist(items: [$0], current: $0) })
        model.idleParkDelay = .milliseconds(30)

        var sourceSwitches = 0
        model.beforeStartingPlayback = { action in
            sourceSwitches += 1
            action()
            return true
        }

        let url = URL(fileURLWithPath: "/tmp/ShortPos.mkv")
        #expect(model.open(url: url))
        #expect(sourceSwitches == 1)
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.property(.duration, .number(120)))
        model.receive(.property(.position, .number(3.5)))
        model.receive(.property(.paused, .flag(true)))
        try await waitUntil { model.isParked }

        // Opening track panel from library must not trigger beforeStartingPlayback (pausing music)
        // and must seek to 3.5s (< 5s).
        #expect(model.resume(url, from: nil, showTracks: true))
        #expect(sourceSwitches == 1)
        model.receive(.started)
        model.receive(.loaded)
        #expect(engine.commands.contains(.seekAbsolute(3.5)))
        #expect(model.trackController.presentation == .quick)

        // Regular resume must trigger beforeStartingPlayback and preserve 3.5s.
        model.trackController.presentation = nil
        model.receive(.property(.position, .number(3.5)))
        model.receive(.property(.paused, .flag(true)))
        try await waitUntil { model.isParked }
        #expect(model.resume(url, from: nil, showTracks: false))
        #expect(sourceSwitches == 2)
        model.receive(.started)
        model.receive(.loaded)
        #expect(engine.commands.last == .seekAbsolute(3.5))
        await model.shutdown()
    }

    @Test("Corrupted file releases LazyMPVPlayer after decode failure")
    func corruptedFileReleasesLazyEngine() async throws {
        let engine = LazyMPVPlayer()
        try engine.setVolume(0)
        let model = PlayerViewModel(
            engine: engine, playlistProvider: { FolderPlaylist(items: [$0], current: $0) })
        #expect(model.open(url: URL(fileURLWithPath: #filePath)))
        try await waitUntil { model.errorMessage != nil && !engine.isActive }
        #expect(!model.hasMedia && model.currentURL == nil)
        #expect(engine.videoLayer == nil)
        await model.shutdown()
    }

    private func media(_ name: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("DerivedData/M1Media/\(name)")
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "First run bash Scripts/make-test-media.sh")
        return url
    }

    private func waitUntil(
        _ condition: () -> Bool,
        message: Comment = "State not reached within 10 seconds",
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), message, sourceLocation: sourceLocation)
    }
}
