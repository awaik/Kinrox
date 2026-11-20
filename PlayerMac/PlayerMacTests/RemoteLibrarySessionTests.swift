import AppKit
import Foundation
import MetaBrainzAPI
import MusicCore
import RemoteProtocol
import RemoteTransport
import Testing

@testable import Kinrox

@Suite(
    "Remote library server, projection, playback, and artwork burst", .serialized,
    .timeLimit(.minutes(2)))
@MainActor
struct RemoteLibrarySessionTests {
    @Test(
        "Simultaneous legacy and library.v1 clients: initial state, local music projection, queue, and privacy"
    )
    func projectionAndLocalMusicQueue() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let recents = RecentFilesStore(fileURL: root.appendingPathComponent("recents.json"))
        let engine = FakePlayerEngine()
        let audioEngine = FakeSessionAudioEngine()
        let session = PlayerSession(
            recents: recents, demoMusic: true, musicDefaults: defaults,
            initialLocalAudioVolume: 0, localAudioEngineFactory: { _ in audioEngine })
        let model = PlayerViewModel(engine: engine, recents: recents)
        let server = RemoteServer(
            defaults: defaults, store: MemoryPairedDevices(), recents: recents,
            pairing: session.pairing, serverName: "Kinrox-Proj-\(UUID().uuidString.prefix(6))")
        session.model = model
        session.remote = server

        let track1URL = root.appendingPathComponent("01.flac")
        let track2URL = root.appendingPathComponent("02.flac")
        let track3URL = root.appendingPathComponent("03.flac")
        for url in [track1URL, track2URL, track3URL] { try Data([0]).write(to: url) }
        let coverKey = try #require(
            try await session.mediaLibrary.artwork.store(makeNoisyPNG(size: 320)))

        let now = Date()
        let files = [track1URL, track2URL, track3URL].enumerated().map { idx, url in
            MediaLibraryFile(
                path: VideoFiles.key(url), size: 100, modified: now, added: now,
                audio: LocalAudioTags(
                    title: "Track \(idx + 1)", artist: "Mira", album: "Horizon", year: 2025,
                    track: idx + 1, disc: 1, duration: 180, codec: "FLAC", sampleRate: 96_000,
                    bitDepth: 24, isLossless: true, artworkPath: idx == 0 ? coverKey : nil))
        }
        session.mediaLibrary.snapshot = MediaLibraryDatabase.Snapshot(files: files)
        session.mediaLibrary.notifyCatalogChanged()

        let browser = BonjourBrowser()
        var legacyMessages: [Message] = []
        var modernMessages: [Message] = []
        var clients: [TransportClient] = []
        defer {
            for c in clients { c.close() }
            browser.stop()
            server.stop()
        }
        server.start(monitorSystem: false)
        browser.start()
        try await waitForRemote {
            server.isOnline
                && browser.servers.contains { $0.id == server.serverId && $0.isAvailable }
        }
        let discovered = try #require(
            browser.servers.first { $0.id == server.serverId && $0.isAvailable })

        func pairClient(_ inbox: @escaping @MainActor (Message) -> Void) async throws
            -> TransportClient
        {
            let client = try TransportClient(
                server: discovered, deviceId: UUID(), deviceName: "iPhone", appVersion: "1.0",
                mode: .pair, saveToken: { _ in })
            client.onEvent = { if case .message(let msg) = $0 { inbox(msg) } }
            clients.append(client)
            client.start()
            try await waitForRemote {
                client.state == .awaitingPIN && session.pairing.prompt != nil
            }
            try await client.submitPIN(#require(session.pairing.prompt?.code))
            try await waitForRemote { client.state == .connected }
            return client
        }

        let legacy = try await pairClient { legacyMessages.append($0) }
        try await waitForRemote { legacyMessages.count >= 2 }
        // Initial pre-requestState frame ALREADY carries library != nil (zero "Update Mac" flash)
        if case .state(_, let initial) = legacyMessages[0] {
            #expect(initial.library != nil && initial.sources != nil)
        } else {
            Issue.record("First message must be state")
        }

        let modern = try await pairClient { modernMessages.append($0) }
        try await waitForRemote { modernMessages.count >= 2 }
        modernMessages.removeAll()
        try await modern.send(.requestState(.init(), .init(features: ["library.v1"])))
        try await waitForRemote { !modernMessages.isEmpty }

        // Start local audio; verify projected state for legacy vs modern
        legacyMessages.removeAll()
        modernMessages.removeAll()
        #expect(session.localAudio.play(session.mediaLibrary.audioTracks, at: 0, shuffled: false))
        await session.playback.settle()
        try await waitForRemote {
            modernMessages.contains {
                if case .state(_, let s) = $0 {
                    s.source == .music && s.music?.origin == .local
                        && s.music?.track?.title == "Track 1"
                } else {
                    false
                }
            }
                && legacyMessages.contains {
                    if case .state(_, let s) = $0 {
                        s.source == .video && s.music == nil && s.title == "Track 1"
                    } else {
                        false
                    }
                }
        }
        let foundModernState = modernMessages.reversed().compactMap { msg -> PlayerState? in
            if case .state(_, let s) = msg, s.music?.origin == .local { s } else { nil }
        }.first
        let modernState = try #require(foundModernState)
        #expect(modernState.music?.track?.format == "FLAC · 24/96")
        #expect(modernState.music?.track?.id.hasPrefix("t_") == true)
        #expect(modernState.music?.track?.albumID?.hasPrefix("a_") == true)
        #expect(modernState.sources?.localMusic?.artwork == modernState.music?.track?.id)

        // Queue page routes to local music bridge (never Spotify) and contains no POSIX paths
        let qReq = Message.Header()
        try await modern.send(.requestQueue(qReq, .init(offset: 0)))
        try await waitForRemote {
            modernMessages.contains {
                if case .queue(_, let p) = $0 { p.replyTo == qReq.id } else { false }
            }
        }
        let qMsg = try #require(
            modernMessages.first {
                if case .queue(_, let p) = $0 { p.replyTo == qReq.id } else { false }
            })
        let qWire = String(decoding: try Codec.encode(qMsg), as: UTF8.self)
        #expect(!qWire.contains(root.path) && !qWire.contains(coverKey))
        guard case .queue(_, let qPage) = qMsg else { return }
        #expect(qPage.items.count == 3 && qPage.items[0].track.title == "Track 1")

        // requestLikeOptions and Spotify-only commands rejected with invalidPayload
        let likeReq = Message.Header()
        try await modern.send(.requestLikeOptions(likeReq, .init(trackId: qPage.items[0].track.id)))
        try await waitForRemote {
            modernMessages.contains {
                if case .error(_, let e) = $0 { e.replyTo == likeReq.id } else { false }
            }
        }
        if case .error(_, let err) = modernMessages.first(where: {
            if case .error(_, let e) = $0 { e.replyTo == likeReq.id } else { false }
        }) {
            #expect(err.code == .invalidPayload)
        }
        #expect(
            server.execute(.setTrackLiked(trackId: qPage.items[0].track.id, liked: true))
                == .invalidPayload)
        #expect(server.execute(.setSimilar(active: true)) == .invalidPayload)

        // Queue mutations (setShuffle, setRepeat, queueMove, queueRemove) update modern without spamming legacy
        legacyMessages.removeAll()
        modernMessages.removeAll()
        let id2 = qPage.items[1].id
        let id3 = qPage.items[2].id
        #expect(server.execute(.queueMove(itemId: id3, beforeId: id2)) == nil)
        #expect(server.execute(.setRepeat(repeatMode: .all)) == nil)
        #expect(server.execute(.setShuffle(shuffle: true)) == nil)
        #expect(server.execute(.queueRemove(itemId: id2)) == nil)
        #expect(server.execute(.queueRemove(itemId: UUID())) == .itemNotFound)
        try await waitForRemote {
            modernMessages.contains {
                if case .state(_, let s) = $0 {
                    s.music?.repeatMode == .all && s.music?.shuffle == true
                        && s.music?.queueCount == 2
                } else {
                    false
                }
            }
        }
        // Give any spurious legacy broadcast time to arrive, then confirm none arrived
        try await Task.sleep(for: .milliseconds(80))
        let legacyQueueSpams = legacyMessages.filter {
            if case .state(_, let s) = $0 { s.source == .video && s.music == nil } else { false }
        }
        #expect(legacyQueueSpams.isEmpty)

        // Inactive local audio shutdown updates sources.localMusic to nil
        let videoURL = root.appendingPathComponent("V.mkv")
        try Data([0]).write(to: videoURL)
        #expect(model.open(url: videoURL))
        model.receive(.started)
        model.receive(.loaded)
        await session.playback.settle()
        #expect(server.snapshot.sources?.localMusic?.paused == true)
        await session.localAudio.shutdownPlayback()
        #expect(server.snapshot.sources?.localMusic == nil)

        await session.playback.close()
        await model.shutdown()
    }

    @Test(
        "playLibrary and resumeSource: movie, series restart, album/track/all-music, Matrix exit, offline/missing"
    )
    func playLibraryAndResumeSource() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let recents = RecentFilesStore(fileURL: root.appendingPathComponent("recents.json"))
        let videoEngine = FakePlayerEngine()
        let audioEngine = FakeSessionAudioEngine()
        let session = PlayerSession(
            recents: recents, demoMusic: true, musicDefaults: defaults,
            initialLocalAudioVolume: 0, localAudioEngineFactory: { _ in audioEngine })
        let model = PlayerViewModel(engine: videoEngine, recents: recents)
        let server = RemoteServer(
            defaults: defaults, store: MemoryPairedDevices(), recents: recents,
            pairing: session.pairing, serverName: "MacTest")
        session.model = model
        session.remote = server

        var ensurePlayerCount = 0
        var fullscreenToggled = 0
        model.onToggleFullscreen = { fullscreenToggled += 1 }
        var mountedFolderIds: Set<UUID> = []

        let folder = WatchedFolder(
            id: UUID(), path: VideoFiles.key(root), displayName: "Local", volumeUUID: nil,
            isRemovable: false)
        mountedFolderIds.insert(folder.id)
        session.wireRemoteLibraryCommands(
            ensurePlayer: { ensurePlayerCount += 1 },
            isFolderAvailable: { mountedFolderIds.contains($0.id) })

        session.mediaLibrary.setEnrichMetadata(false)
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let movieURL = root.appendingPathComponent("Movie.mkv")
        let missingURL = root.appendingPathComponent("Deleted.mkv")
        let ep1URL = root.appendingPathComponent("Show.S01E01.mkv")
        let ep2URL = root.appendingPathComponent("Show.S01E02.mkv")
        let track1URL = root.appendingPathComponent("01.flac")
        let track2URL = root.appendingPathComponent("02.flac")
        let soloURL = root.appendingPathComponent("Solo.mp3")
        for url in [movieURL, ep1URL, ep2URL, track1URL, track2URL, soloURL] {
            try Data([0]).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        }

        let movieFile = MediaLibraryFile(
            path: VideoFiles.key(movieURL), size: 1, modified: now, added: now,
            video: VideoTitle(title: "Movie"))
        let missingFile = MediaLibraryFile(
            path: VideoFiles.key(missingURL), size: 1, modified: now, added: now,
            video: VideoTitle(title: "Deleted"))
        let ep1File = MediaLibraryFile(
            path: VideoFiles.key(ep1URL), size: 1, modified: now, added: now,
            video: VideoTitle(title: "Show", season: 1, episodes: [1]))
        let ep2File = MediaLibraryFile(
            path: VideoFiles.key(ep2URL), size: 1, modified: now, added: now,
            video: VideoTitle(title: "Show", season: 1, episodes: [2]))
        let t1File = MediaLibraryFile(
            path: VideoFiles.key(track1URL), size: 1, modified: now, added: now,
            audio: LocalAudioTags(title: "One", artist: "A", album: "Alb", track: 1, duration: 60))
        let t2File = MediaLibraryFile(
            path: VideoFiles.key(track2URL), size: 1, modified: now, added: now,
            audio: LocalAudioTags(title: "Two", artist: "A", album: "Alb", track: 2, duration: 60))
        let soloFile = MediaLibraryFile(
            path: VideoFiles.key(soloURL), size: 1, modified: now, added: now,
            audio: LocalAudioTags(title: "Solo", artist: "B", duration: 60))

        _ = try await session.mediaLibrary.database.add(folder)
        _ = try await session.mediaLibrary.database.apply(
            [movieFile, missingFile, ep1File, ep2File, t1File, t2File, soloFile],
            folder: folder.id, validate: { true })
        for p in [
            WatchProgress(
                path: movieFile.path, position: 120, duration: 1000, completed: false, updated: now),
            WatchProgress(
                path: ep1File.path, position: 500, duration: 500, completed: true, updated: now),
            WatchProgress(
                path: ep2File.path, position: 500, duration: 500, completed: true, updated: now),
        ] { try await session.mediaLibrary.database.save(p) }
        try await session.mediaLibrary.reload()

        let ids = try #require(server.libraryBridge?.ids)
        let movieId = ids.id(kind: .movie, key: movieFile.path)
        let missingId = ids.id(kind: .movie, key: missingFile.path)
        let seriesId = ids.id(kind: .series, key: ep1File.seriesKey!)
        let albumId = ids.id(kind: .album, key: t1File.albumKey!)
        let track2Id = ids.id(kind: .track, key: t2File.path)
        let soloId = ids.id(kind: .track, key: soloFile.path)

        // Missing file on mounted folder returns itemNotFound without calling engine.load and triggers rescan
        #expect(
            server.execute(.playLibrary(itemId: missingId, from: .resume, shuffle: nil))
                == .itemNotFound)
        #expect(videoEngine.openedURLs.isEmpty)
        try await waitForRemote { !session.mediaLibrary.isScanning }
        #expect(server.libraryBridge?.resolvePlayTarget(missingId) == nil)

        // Unmounted folder returns unavailable
        mountedFolderIds.remove(folder.id)
        #expect(
            server.execute(.playLibrary(itemId: movieId, from: .resume, shuffle: nil))
                == .unavailable)
        #expect(
            RemoteServer.message(for: .unavailable) == "The drive with this file is not connected.")
        mountedFolderIds.insert(folder.id)

        // Play movie (resume) opens normal window without toggling fullscreen
        #expect(server.execute(.playLibrary(itemId: movieId, from: .resume, shuffle: nil)) == nil)
        await session.playback.settle()
        #expect(ensurePlayerCount == 1 && fullscreenToggled == 0)
        #expect(videoEngine.openedURLs.last == movieURL)
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.property(.duration, .number(1000)))
        model.receive(.property(.paused, .flag(true)))

        // Play same movie with from: .start seeks to 0 and unpauses
        videoEngine.commands.removeAll()
        #expect(server.execute(.playLibrary(itemId: movieId, from: .start, shuffle: nil)) == nil)
        await session.playback.settle()
        #expect(videoEngine.commands.contains(.seekAbsolute(0)))
        #expect(videoEngine.commands.contains(.paused(false)))

        // All-watched series falls back to first episode
        #expect(server.execute(.playLibrary(itemId: seriesId, from: .resume, shuffle: nil)) == nil)
        await session.playback.settle()
        #expect(videoEngine.openedURLs.last == ep1URL)
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.property(.paused, .flag(false)))

        // Track plays album starting at that track index, pausing video via coordinator
        #expect(server.execute(.playLibrary(itemId: track2Id, from: .start, shuffle: false)) == nil)
        model.receive(.property(.paused, .flag(true)))
        await session.playback.settle()
        #expect(session.localAudio.currentTrack?.title == "Two")
        #expect(
            session.localAudio.queue.history.count == 1
                && session.localAudio.queue.items.count == 1)

        // Standalone track plays alone; album shuffles; all-music plays all 3 shuffled
        #expect(server.execute(.playLibrary(itemId: soloId, from: .start, shuffle: false)) == nil)
        await session.playback.settle()
        #expect(
            session.localAudio.currentTrack?.title == "Solo"
                && session.localAudio.queue.items.count == 1)
        #expect(server.execute(.playLibrary(itemId: albumId, from: .start, shuffle: true)) == nil)
        await session.playback.settle()
        #expect(session.localAudio.queue.shuffled && session.localAudio.queue.items.count == 2)
        #expect(
            server.execute(.playLibrary(itemId: "all-music", from: .start, shuffle: nil)) == nil)
        await session.playback.settle()
        #expect(session.localAudio.queue.shuffled && session.localAudio.queue.items.count == 3)

        // Matrix screensaver is exited cleanly by resumeSource across localMusic, video, and spotify
        #expect(model.startMatrix())
        await session.playback.settle()
        #expect(model.screensaver == .matrix && session.localAudio.paused)
        #expect(server.execute(.resumeSource(source: .localMusic)) == nil)
        await session.playback.settle()
        #expect(model.screensaver == .off && !session.localAudio.paused)

        #expect(model.startMatrix())
        await session.playback.settle()
        #expect(model.screensaver == .matrix)
        #expect(server.execute(.resumeSource(source: .video)) == nil)
        await session.playback.settle()
        #expect(model.screensaver == .off)

        #expect(model.startMatrix())
        await session.playback.settle()
        #expect(server.execute(.resumeSource(source: .spotify)) == nil)
        await session.playback.settle()
        #expect(model.screensaver == .off)
        session.music.acceptsPlayback = false
        #expect(server.execute(.resumeSource(source: .spotify)) == .noMedia)

        await session.playback.close()
        await model.shutdown()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KinroxRemoteSession-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "app.kinrox.tests.remotesess.\(UUID())"))
    }

    private func makeNoisyPNG(size: Int) -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        if let ptr = bitmap.bitmapData {
            var state: UInt64 = 0x1234_5678_9ABC_DEF0
            for i in 0..<(bitmap.bytesPerRow * size) {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                ptr[i] = UInt8(truncatingIfNeeded: state >> 56)
            }
        }
        return bitmap.representation(using: .png, properties: [:])!
    }
}

@MainActor
private final class FakeSessionAudioEngine: LocalAudioEngine {
    let events: AsyncStream<LocalAudioEvent>
    let continuation: AsyncStream<LocalAudioEvent>.Continuation
    init() { (events, continuation) = AsyncStream.makeStream() }
    func load(_ url: URL, id: UUID, position: Double) throws { continuation.yield(.loaded(id)) }
    func setPaused(_ paused: Bool) throws {}
    func seek(_ position: Double) throws {}
    func setVolume(_ volume: Double) throws {}
    func shutdown() async { continuation.finish() }
}
