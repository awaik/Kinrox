import AppKit
import Foundation
import MetaBrainzAPI
import MusicCore
import RemoteProtocol
import Testing

@testable import Kinrox

@Suite("Remote library review regression coverage", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct RemoteLibraryRegressionTests {
    @Test("Negative/out-of-range tags sanitize cleanly and never break Codec.encode")
    func unsanitizedTagsAndCountsEncodeCleanly() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let store = MediaLibraryStore(
            limiter: MusicBrainzRateLimiter(), defaults: defaults, storage: (root, root))
        let recents = RecentFilesStore(fileURL: root.appendingPathComponent("recents.json"))
        let now = Date()

        let badTrack = MediaLibraryFile(
            path: root.appendingPathComponent("bad.flac").path, size: 100, modified: now,
            added: now,
            audio: LocalAudioTags(
                title: "Bad Tag Track", artist: "Artist", album: "Broken Album", year: -5,
                track: -3, disc: -1, duration: 120, codec: "FLAC"))
        let badMovie = MediaLibraryFile(
            path: root.appendingPathComponent("badmovie.mkv").path, size: 100, modified: now,
            added: now,
            video: VideoTitle(title: "Ancient", year: 99_999))
        let badEp = MediaLibraryFile(
            path: root.appendingPathComponent("badep.mkv").path, size: 100, modified: now,
            added: now,
            video: VideoTitle(title: "NegShow", season: -2, episodes: [-4], episodeTitle: "Pilot"))

        store.snapshot = MediaLibraryDatabase.Snapshot(files: [badTrack, badMovie, badEp])
        let bridge = RemoteLibraryBridge(store: store, recents: recents, defaults: defaults)
        defer { bridge.disconnect() }

        let tracksPage = bridge.libraryPage(.init(section: .tracks), replyTo: UUID())
        let tracksDecoded = try Codec.decode(try Codec.encode(tracksPage))
        guard case .library(_, let tPage) = tracksDecoded else {
            Issue.record("Expected tracks library page")
            return
        }
        #expect(tPage.items.count == 1)
        #expect(tPage.items[0].trackNumber == nil && tPage.items[0].year == nil)

        let videosPage = bridge.libraryPage(.init(section: .videos), replyTo: UUID())
        let videosDecoded = try Codec.decode(try Codec.encode(videosPage))
        guard case .library(_, let vPage) = videosDecoded else {
            Issue.record("Expected videos library page")
            return
        }
        #expect(vPage.items.count == 2)
        for item in vPage.items {
            #expect(item.year == nil)
            let details = bridge.itemDetails(.init(id: item.id), replyTo: UUID())
            _ = try Codec.encode(details)
        }
        let trackDetails = bridge.itemDetails(.init(id: tPage.items[0].id), replyTo: UUID())
        _ = try Codec.encode(trackDetails)
        let epId = bridge.ids.id(kind: .episode, key: badEp.path)
        let epDetails = bridge.itemDetails(.init(id: epId), replyTo: UUID())
        let decodedEp = try Codec.decode(try Codec.encode(epDetails))
        if case .libraryItem(_, let resp) = decodedEp {
            #expect(resp.item.season == 0 && resp.item.episode == 0)
        } else {
            Issue.record("Expected valid episode details")
        }
    }

    @Test("CatalogIndex is lazy when idle, releases on stop, and coalesces metadata enrichment")
    func lazyIndexAndCoalescedEnrichment() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let store = MediaLibraryStore(
            limiter: MusicBrainzRateLimiter(), defaults: defaults, storage: (root, root))
        let recents = RecentFilesStore(fileURL: root.appendingPathComponent("recents.json"))
        let now = Date()
        let movie = MediaLibraryFile(
            path: root.appendingPathComponent("M.mkv").path, size: 1, modified: now, added: now,
            video: VideoTitle(title: "M"))
        store.snapshot = MediaLibraryDatabase.Snapshot(files: [movie])

        let server = RemoteServer(
            defaults: defaults, store: MemoryPairedDevices(), recents: recents,
            pairing: PairingCenter(), serverName: "LazyMac")
        server.connectLibrary(store)
        let bridge = try #require(server.libraryBridge)
        // Zero remotes connected: index stays unbuilt
        #expect(!bridge.hasCachedIndex)

        // Accessing state builds the index on demand, stop() releases it again
        #expect(bridge.state.videos == 1)
        #expect(bridge.hasCachedIndex)
        server.stop()
        #expect(!bridge.hasCachedIndex)

        // Enrichment notifications coalesce while connected and flush on metadataFinished
        var connected = true
        var changeCalls = 0
        let direct = RemoteLibraryBridge(
            store: store, recents: recents, defaults: defaults,
            metadataCoalesceInterval: 60)
        defer { direct.disconnect() }
        direct.hasConnectedClients = { connected }
        direct.changed = { changeCalls += 1 }
        _ = direct.state
        let revBefore = direct.libraryRevision
        for i in 0..<5 {
            store.snapshot.metadata[movie.metadataKey!] = MediaEnrichment(title: "M-\(i)")
            store.notifyMetadataChanged()
        }
        // Coalesced during enrichment: no per-item libraryRevision churn or rebuild
        #expect(direct.libraryRevision == revBefore)
        #expect(changeCalls == 0)
        store.notifyMetadataFinished()
        #expect(direct.libraryRevision != revBefore)
        #expect(changeCalls == 1)

        // With zero connected clients, metadata changes neither schedule timers nor bump eagerly
        connected = false
        let revIdle = direct.libraryRevision
        store.notifyMetadataChanged()
        store.notifyMetadataFinished()
        #expect(!direct.hasCachedIndex)
        #expect(direct.libraryRevision == revIdle)
        direct.clientConnected()
        #expect(direct.libraryRevision != revIdle)
    }

    @Test("Progress updates restart continueWatching and unwatched pages without resetting videos")
    func progressSensitivePaginationRestarts() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let store = MediaLibraryStore(
            limiter: MusicBrainzRateLimiter(), defaults: defaults, storage: (root, root))
        let recents = RecentFilesStore(fileURL: root.appendingPathComponent("recents.json"))
        let now = Date()
        var files: [MediaLibraryFile] = []
        var progress: [String: WatchProgress] = [:]
        for i in 0..<55 {
            let path = root.appendingPathComponent("Movie_\(String(format: "%02d", i)).mkv").path
            files.append(
                MediaLibraryFile(
                    path: path, size: 1, modified: now, added: now,
                    video: VideoTitle(title: "Movie \(String(format: "%02d", i))")))
            progress[path] = WatchProgress(
                path: path, position: 100, duration: 1000, completed: false,
                updated: now.addingTimeInterval(Double(-i)))
        }
        store.snapshot = MediaLibraryDatabase.Snapshot(files: files, progress: progress)
        let bridge = RemoteLibraryBridge(store: store, recents: recents, defaults: defaults)
        defer { bridge.disconnect() }

        let cw1 = try requirePage(
            bridge.libraryPage(.init(section: .continueWatching, offset: 0), replyTo: UUID()))
        let unw1 = try requirePage(
            bridge.libraryPage(
                .init(section: .videos, videoKind: .unwatched, offset: 0), replyTo: UUID()))
        let all1 = try requirePage(
            bridge.libraryPage(
                .init(section: .videos, videoKind: .all, offset: 0), replyTo: UUID()))
        #expect(cw1.nextOffset == 50 && unw1.nextOffset == 50 && all1.nextOffset == 50)

        // Complete Movie_00 -> progressRevision changes, libraryRevision stays identical
        let libRev = bridge.libraryRevision
        store.record(
            WatchProgress(
                path: files[0].path, position: 1000, duration: 1000, completed: true,
                updated: now.addingTimeInterval(10)))
        #expect(bridge.libraryRevision == libRev)

        let cw2 = try requirePage(
            bridge.libraryPage(
                .init(section: .continueWatching, offset: 50, revision: cw1.revision),
                replyTo: UUID()))
        let unw2 = try requirePage(
            bridge.libraryPage(
                .init(
                    section: .videos, videoKind: .unwatched, offset: 50, revision: unw1.revision),
                replyTo: UUID()))
        let all2 = try requirePage(
            bridge.libraryPage(
                .init(section: .videos, videoKind: .all, offset: 50, revision: all1.revision),
                replyTo: UUID()))
        #expect(cw2.offset == 0 && cw2.revision != cw1.revision)
        #expect(unw2.offset == 0 && unw2.revision != unw1.revision)
        #expect(all2.offset == 50 && all2.revision == all1.revision)
    }

    @Test(
        "Partially offline series, shuffled track pin, sameLoaded coordinator, resumeSource, ad-hoc bookmark, and ad-hoc audio tags"
    )
    func playbackAndAdHocEdgeCases() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let recents = RecentFilesStore(fileURL: root.appendingPathComponent("recents.json"))
        let videoEngine = FakePlayerEngine()
        let audioEngine = ControlledLocalAudioEngine()
        let session = PlayerSession(
            recents: recents, demoMusic: true, musicDefaults: defaults,
            initialLocalAudioVolume: 0, localAudioEngineFactory: { _ in audioEngine })
        let model = PlayerViewModel(engine: videoEngine, recents: recents)
        let server = RemoteServer(
            defaults: defaults, store: MemoryPairedDevices(), recents: recents,
            pairing: session.pairing, serverName: "EdgeMac")
        session.model = model
        session.remote = server
        session.wireRemoteLibraryCommands(ensurePlayer: {})
        session.mediaLibrary.setEnrichMetadata(false)

        let now = Date()
        let s1ep1 = root.appendingPathComponent("Show.S01E01.mkv")
        let s2ep1 = root.appendingPathComponent("Show.S02E01.mkv")
        let t1 = root.appendingPathComponent("01.flac")
        let t2 = root.appendingPathComponent("02.flac")
        let t3 = root.appendingPathComponent("03.flac")
        let adHocOrig = root.appendingPathComponent("Original.mkv")
        let adHocMoved = root.appendingPathComponent("Moved.mkv")
        let adHocDeleted = root.appendingPathComponent("Gone.mkv")
        for url in [s2ep1, t1, t2, t3, adHocOrig, adHocDeleted] { try Data([0]).write(to: url) }

        let s1File = MediaLibraryFile(
            path: VideoFiles.key(s1ep1), size: 1, modified: now, added: now,
            video: VideoTitle(title: "Show", season: 1, episodes: [1]))
        let s2File = MediaLibraryFile(
            path: VideoFiles.key(s2ep1), size: 1, modified: now, added: now,
            video: VideoTitle(title: "Show", season: 2, episodes: [1]))
        let trackFiles = [t1, t2, t3].enumerated().map { idx, url in
            MediaLibraryFile(
                path: VideoFiles.key(url), size: 1, modified: now, added: now,
                audio: LocalAudioTags(
                    title: "T\(idx + 1)", artist: "Band", album: "LP", track: idx + 1,
                    duration: 180))
        }
        session.mediaLibrary.snapshot = MediaLibraryDatabase.Snapshot(
            files: [s1File, s2File] + trackFiles,
            offlinePaths: [s1File.path],
            progress: [
                VideoFiles.key(adHocOrig): WatchProgress(
                    path: VideoFiles.key(adHocOrig), position: 42, duration: 600, completed: false,
                    updated: now)
            ])
        session.mediaLibrary.notifyCatalogChanged()
        let ids = try #require(server.libraryBridge?.ids)

        // 1. Partially offline series picks online S02E01 for seriesDetails and .resume
        let seriesId = ids.id(kind: .series, key: s1File.seriesKey!)
        let s2Id = ids.id(kind: .episode, key: s2File.path)
        let detailsMsg = try #require(
            server.libraryBridge?.itemDetails(.init(id: seriesId), replyTo: UUID()))
        if case .libraryItem(_, let resp) = detailsMsg {
            #expect(resp.details.nextEpisodeId == s2Id)
        } else {
            Issue.record("Expected series details")
        }
        #expect(server.execute(.playLibrary(itemId: seriesId, from: .resume, shuffle: nil)) == nil)
        await session.playback.settle()
        #expect(videoEngine.openedURLs.last == s2ep1)
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.property(.duration, .number(1000)))
        model.receive(.property(.position, .number(300)))
        model.receive(.property(.paused, .flag(true)))
        #expect(model.showHome())

        // 2. Track with shuffle == true pins selected track and shuffles remaining album tracks
        let t2Id = ids.id(kind: .track, key: trackFiles[1].path)
        #expect(server.execute(.playLibrary(itemId: t2Id, from: .start, shuffle: true)) == nil)
        await session.playback.settle()
        #expect(session.localAudio.currentTrack?.title == "T2")
        #expect(session.localAudio.queue.shuffled)
        #expect(session.localAudio.queue.items.count == 3)
        #expect(session.localAudio.queue.history.isEmpty)

        // 3. sameLoaded movie with from: .start executes seek(0) and returnToVideo via coordinator
        videoEngine.commands.removeAll()
        #expect(model.isShowingHome)
        #expect(server.execute(.playLibrary(itemId: s2Id, from: .start, shuffle: nil)) == nil)
        // Before coordinator settles, synchronous mutation has not dismissed Home or sought
        await session.playback.settle()
        #expect(!model.isShowingHome)
        #expect(videoEngine.commands.contains(.seekAbsolute(0)))
        #expect(videoEngine.commands.contains(.paused(false)))
        #expect(session.localAudio.paused)

        // 4. resumeSource(.localMusic) does not restart an in-flight load
        audioEngine.autoLoad = false
        audioEngine.loadCount = 0
        #expect(
            session.localAudio.play([
                LocalAudioTrack(file: trackFiles[0], metadata: nil, isOffline: false)
            ]))
        try await waitForRemote { session.localAudio.loading }
        let loadsDuringFlight = audioEngine.loadCount
        #expect(server.execute(.resumeSource(source: .localMusic)) == nil)
        await Task.yield()
        #expect(audioEngine.loadCount == loadsDuringFlight)
        audioEngine.finishPending()
        await session.playback.settle()

        // 5. resumeSource(.spotify) with disallowed resuming returns invalidPayload without exiting Matrix
        #expect(model.startMatrix())
        await session.playback.settle()
        #expect(model.screensaver == .matrix)
        session.music.receive(
            MusicPlaybackSnapshot(
                uri: session.music.currentTrack?.uri ?? "", position: 0, duration: 180,
                paused: true,
                volume: 50, deviceName: "Mac", occurrenceID: session.music.queue.current?.id,
                disallowedActions: ["resuming"]))
        #expect(server.execute(.resumeSource(source: .spotify)) == .invalidPayload)
        #expect(model.screensaver == .matrix)
        model.stopScreensaver()

        // 6. Ad-hoc recent renamed on same volume resolves via bookmark; deleted one refreshes recents
        recents.noteOpened(adHocOrig, at: now)
        recents.noteOpened(adHocDeleted, at: now)
        let origAdHocId = ids.id(kind: .movie, key: VideoFiles.key(adHocOrig))
        let deletedAdHocId = ids.id(kind: .movie, key: VideoFiles.key(adHocDeleted))
        try FileManager.default.moveItem(at: adHocOrig, to: adHocMoved)
        try FileManager.default.removeItem(at: adHocDeleted)
        #expect(
            server.execute(.playLibrary(itemId: origAdHocId, from: .resume, shuffle: nil)) == nil)
        await session.playback.settle()
        #expect(videoEngine.openedURLs.last.map(VideoFiles.key) == VideoFiles.key(adHocMoved))
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.property(.paused, .flag(true)))
        #expect(
            server.execute(.playLibrary(itemId: deletedAdHocId, from: .resume, shuffle: nil))
                == .itemNotFound)
        let deletedRecent = try #require(recents.items.first { $0.title == "Gone.mkv" })
        #expect(recents.unavailable.contains(deletedRecent.id))

        // 7. Ad-hoc local audio bridge reads parsed artist & live duration from LocalAudioViewModel
        let localBridge = try #require(server.localMusicBridge)
        let adHocAudio = LocalAudioTrack(
            file: MediaLibraryFile(
                path: root.appendingPathComponent("AdHoc.mp3").path, size: 123, modified: now,
                added: now,
                audio: LocalAudioTags(
                    title: "Parsed Title", artist: "Parsed Artist", album: "Parsed Album",
                    year: 2025, duration: 245, codec: "MP3")),
            metadata: nil, isOffline: false)
        audioEngine.autoLoad = true
        #expect(session.localAudio.play([adHocAudio]))
        await session.playback.settle()
        let emptyQueueTrack = MusicTrack(
            id: adHocAudio.id, uri: adHocAudio.file.url.absoluteString, title: "AdHoc",
            artists: [], albumID: "", albumTitle: "", duration: 0)
        let mapped = localBridge.remoteTrack(emptyQueueTrack)
        #expect(mapped.artists == ["Parsed Artist"])
        #expect(mapped.duration == 245)
        #expect(mapped.title == "Parsed Title")

        await session.playback.close()
        await model.shutdown()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KinroxRemoteReg-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "app.kinrox.tests.remotereg.\(UUID())"))
    }

    private func requirePage(_ message: Message) throws -> LibraryPage {
        guard case .library(_, let page) = message else {
            Issue.record("Expected library page, got \(message.type)")
            throw RemoteTestError.timeout
        }
        return page
    }
}

@MainActor
private final class ControlledLocalAudioEngine: LocalAudioEngine {
    let events: AsyncStream<LocalAudioEvent>
    let continuation: AsyncStream<LocalAudioEvent>.Continuation
    var autoLoad = true
    var loadCount = 0
    private var pendingId: UUID?

    init() { (events, continuation) = AsyncStream.makeStream() }

    func load(_ url: URL, id: UUID, position: Double) throws {
        loadCount += 1
        if autoLoad {
            continuation.yield(.loaded(id))
        } else {
            pendingId = id
        }
    }

    func finishPending() {
        guard let id = pendingId else { return }
        pendingId = nil
        continuation.yield(.loaded(id))
    }

    func setPaused(_ paused: Bool) throws {}
    func seek(_ position: Double) throws {}
    func setVolume(_ volume: Double) throws {}
    func shutdown() async { continuation.finish() }
}
