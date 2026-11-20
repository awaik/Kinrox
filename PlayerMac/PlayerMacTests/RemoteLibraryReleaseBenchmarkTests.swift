import AppKit
import Darwin
import Foundation
import MetaBrainzAPI
import RemoteProtocol
import RemoteTransport
import Testing

@testable import Kinrox

/// Opt-in orchestrator measurements for the remote media library (Release configuration).
/// Run with `TEST_RUNNER_KINROX_REMOTE_LIBRARY_BENCH=1`; media comes from
/// `TEST_RUNNER_KINROX_BENCH_MEDIA_DIR` (`Scripts/make-test-media.sh` output).
@Suite("Remote library Release measurements", .serialized, .timeLimit(.minutes(10)))
@MainActor
struct RemoteLibraryReleaseBenchmarkTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["KINROX_REMOTE_LIBRARY_BENCH"] == "1"))
    func measureRemoteLibraryInRelease() async throws {
        let env = ProcessInfo.processInfo.environment
        let outPath =
            env["KINROX_REMOTE_LIBRARY_BENCH_OUT"]
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("kinrox-remote-library-bench.json").path
        let mediaDir = URL(fileURLWithPath: try #require(env["KINROX_BENCH_MEDIA_DIR"]))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KinroxRemoteLibraryBench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "app.kinrox.bench.remote.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(false, forKey: MediaLibraryStore.enrichKey)
        defaults.set(false, forKey: MediaLibraryStore.autoWatchKey)

        let recents = RecentFilesStore(fileURL: root.appendingPathComponent("recents.json"))
        let session = PlayerSession(
            recents: recents, musicDefaults: defaults, initialLocalAudioVolume: 0)
        let store = session.mediaLibrary
        store.setEnrichMetadata(false)
        store.setAutoWatchFolders(false)
        #expect(session.localAudio.setVolume(0))
        let videoModel = PlayerViewModel(engine: try MPVPlayer(), recents: recents)
        #expect(videoModel.setVolume(0))
        session.model = videoModel
        session.playback.connectNowPlaying(NowPlayingController(center: FakeNowPlayingCenter()))

        // Library: 2,000 videos (200 with distinct posters, 30 in progress) + 5,000 tracks,
        // plus one real movie and one real album track for playLibrary.
        let realMovie = root.appendingPathComponent("Bench Movie.mp4")
        let realTrack = root.appendingPathComponent("Bench Track.mp3")
        try FileManager.default.copyItem(
            at: mediaDir.appendingPathComponent("h264.mp4"), to: realMovie)
        try FileManager.default.copyItem(
            at: mediaDir.appendingPathComponent("tagged.mp3"), to: realTrack)
        let fixture = try await makeLibrary(root: root, store: store)
        let now = Date()
        let movieFile = MediaLibraryFile(
            path: VideoFiles.key(realMovie), size: 1, modified: now, added: now,
            video: VideoTitle(title: "Zz Bench Movie"))
        let trackFile = MediaLibraryFile(
            path: VideoFiles.key(realTrack), size: 1, modified: now, added: now,
            audio: LocalAudioTags(
                title: "Bench Track", artist: "Bench", album: "Bench Album", track: 1, disc: 1,
                duration: 5))
        var snapshot = fixture.snapshot
        snapshot.files += [movieFile, trackFile]
        store.snapshot = snapshot
        store.notifyCatalogChanged()

        var report: [String: Any] = ["pid": getpid()]

        // 1. Idle with no remote connected: server without library vs with library.
        let bare = RemoteServer(
            defaults: defaults, store: MemoryPairedDevices(), recents: recents,
            pairing: PairingCenter(), serverName: "Kinrox-BenchA-\(UUID().uuidString.prefix(6))")
        bare.connect(to: videoModel)
        bare.connectLocalAudio(session.localAudio) { false }
        bare.start(monitorSystem: false)
        try await waitForRemote { bare.isOnline }
        try await Task.sleep(for: .seconds(2))
        let idleWithout = try await sampleWindow(seconds: 8)
        bare.stop()

        try await Task.sleep(for: .seconds(2))
        let beforeConnect = BenchResources.capture()
        let server = RemoteServer(
            defaults: defaults, store: MemoryPairedDevices(), recents: recents,
            pairing: session.pairing,
            serverName: "Kinrox-BenchB-\(UUID().uuidString.prefix(6))")
        session.remote = server
        session.wireRemoteLibraryCommands(ensurePlayer: {})
        server.start(monitorSystem: false)
        try await waitForRemote { server.isOnline }
        try await Task.sleep(for: .seconds(2))
        let idleWith = try await sampleWindow(seconds: 8)
        report["idle_no_remote"] = [
            "without_library": idleWithout, "with_library": idleWith,
            "footprint_delta_after_connect_library_mib": round2(
                (idleWith["phys_footprint_mib"] ?? 0) - mib(beforeConnect.footprint)),
        ]
        #expect(server.libraryBridge?.state.videos == 2_001)

        // Pair a library.v1 client over the real encrypted transport.
        let browser = BonjourBrowser()
        defer {
            browser.stop()
            server.stop()
        }
        browser.start()
        try await waitForRemote {
            browser.servers.contains { $0.id == server.serverId && $0.isAvailable }
        }
        let discovered = try #require(
            browser.servers.first { $0.id == server.serverId && $0.isAvailable })
        let client = try TransportClient(
            server: discovered, deviceId: UUID(), deviceName: "iPhone", appVersion: "1.0",
            mode: .pair, saveToken: { _ in })
        defer { client.close() }
        let inbox = BenchInbox()
        client.onEvent = { if case .message(let message) = $0 { inbox.receive(message) } }
        client.start()
        try await waitForRemote { client.state == .awaitingPIN && session.pairing.prompt != nil }
        try await client.submitPIN(#require(session.pairing.prompt?.code))
        try await waitForRemote { client.state == .connected }
        try await client.send(.requestState(.init(), .init(features: ["library.v1"])))
        try await Task.sleep(for: .milliseconds(500))

        // 2. requestLibrary round trips (50-item pages).
        let requests: [(String, LibraryRequest)] = [
            ("continueWatching", .init(section: .continueWatching)),
            ("videos", .init(section: .videos)),
            ("videos_offset_1000", .init(section: .videos, offset: 1_000)),
            ("albums", .init(section: .albums)),
            ("tracks_search", .init(section: .tracks, query: "Track 12")),
        ]
        var libraryReport: [String: Any] = [:]
        let hitches = BenchHitchTracker()
        hitches.start()
        for (name, request) in requests {
            var samples: [Double] = []
            var items = 0
            for _ in 0..<40 {
                let header = Message.Header()
                let sent = ContinuousClock.now
                try await client.send(.requestLibrary(header, request))
                try await waitForRemote { inbox.replies[header.id] != nil }
                let reply = try #require(inbox.replies[header.id])
                samples.append(ms(sent, reply.at))
                if case .library(_, let page) = reply.message { items = page.items.count }
            }
            libraryReport[name] = stats(samples).merging(["items": Double(items)]) { $1 }
        }
        libraryReport["max_mainactor_gap_ms"] = round2(hitches.stop())
        report["request_library"] = libraryReport

        // 3. Artwork: 200 cold requests, 4 in flight.
        let libraryIds = try #require(server.libraryBridge?.ids)
        let posterIds = fixture.posterPaths.map { libraryIds.id(kind: .movie, key: $0) }
        try await Task.sleep(for: .seconds(2))
        let before = BenchResources.capture()
        let peak = BenchPeakSampler()
        peak.start()
        var artworkSamples: [Double] = []
        var sentAt: [UUID: ContinuousClock.Instant] = [:]
        var next = 0
        var done = 0
        var withJPEG = 0
        var maxBytes = 0
        while done < posterIds.count {
            while sentAt.count < 4, next < posterIds.count {
                let header = Message.Header()
                sentAt[header.id] = .now
                try await client.send(
                    .requestArtwork(header, .init(id: posterIds[next], maxPixel: 360)))
                next += 1
            }
            try await Task.sleep(for: .milliseconds(1))
            for (id, sent) in sentAt {
                guard let reply = inbox.replies[id] else { continue }
                sentAt[id] = nil
                done += 1
                artworkSamples.append(ms(sent, reply.at))
                if case .artwork(_, let response) = reply.message, let jpeg = response.jpeg {
                    withJPEG += 1
                    maxBytes = max(maxBytes, jpeg.count)
                }
            }
        }
        let peakFootprint = peak.stop()
        try await Task.sleep(for: .seconds(60))
        let settled = BenchResources.capture()
        report["artwork_200_cold"] = stats(artworkSamples).merging([
            "with_jpeg": Double(withJPEG), "max_jpeg_bytes": Double(maxBytes),
            "baseline_footprint_mib": mib(before.footprint),
            "peak_footprint_delta_mib": round2(mib(peakFootprint) - mib(before.footprint)),
            "after_60s_footprint_delta_mib": round2(
                mib(settled.footprint) - mib(before.footprint)),
        ]) { $1 }
        #expect(client.state == .connected)

        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: outPath))

        // 4. playLibrary → confirmed state.
        let ids = try #require(server.libraryBridge?.ids)
        let albumId = ids.id(kind: .album, key: try #require(trackFile.albumKey))
        let movieId = ids.id(kind: .movie, key: movieFile.path)
        var playReport: [String: Double] = [:]
        playReport["local_audio_cold_ms"] = try await measurePlay(
            client: client, inbox: inbox, itemId: albumId
        ) { $0.source == .music && $0.music?.origin == .local && !$0.paused }
        playReport["video_ms"] = try await measurePlay(
            client: client, inbox: inbox, itemId: movieId
        ) { $0.source == .video && $0.hasMedia && !$0.paused && $0.title.contains("Bench Movie") }
        #expect(session.localAudio.paused)
        #expect(videoModel.playbackVolume == 0)
        playReport["local_audio_from_video_ms"] = try await measurePlay(
            client: client, inbox: inbox, itemId: albumId
        ) { $0.source == .music && $0.music?.origin == .local && !$0.paused }
        #expect(videoModel.paused)
        #expect(session.localAudio.volume == 0)
        #expect(!videoModel.isFullscreen)
        report["play_library"] = playReport

        _ = session.localAudio.setPaused(true)
        _ = videoModel.setPaused(true)
        await session.localAudio.shutdownPlayback()
        let json = try JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: URL(fileURLWithPath: outPath))
    }

    private func measurePlay(
        client: TransportClient, inbox: BenchInbox, itemId: String,
        confirmed: @escaping (PlayerState) -> Bool
    ) async throws -> Double {
        let header = Message.Header()
        let sent = ContinuousClock.now
        let mark = inbox.states.count
        try await client.send(
            .command(header, .playLibrary(itemId: itemId, from: .start, shuffle: nil)))
        var at: ContinuousClock.Instant?
        do {
            try await waitForRemote {
                at = inbox.states.dropFirst(mark).first { confirmed($0.state) }?.at
                return at != nil
            }
        } catch {
            let reply = inbox.replies[header.id].map { String(describing: $0.message) } ?? "none"
            let last = inbox.states.last.map {
                "source=\(String(describing: $0.state.source)) origin="
                    + "\(String(describing: $0.state.music?.origin)) paused=\($0.state.paused) "
                    + "hasMedia=\($0.state.hasMedia) title=\($0.state.title)"
            }
            Issue.record(
                "playLibrary not confirmed; reply: \(reply); last state: \(last ?? "none")")
            return -1
        }
        if case .error(_, let error)? = inbox.replies[header.id]?.message {
            Issue.record("playLibrary failed: \(error.code)")
        }
        try await Task.sleep(for: .seconds(1))
        return round2(ms(sent, try #require(at)))
    }

    private func makeLibrary(root: URL, store: MediaLibraryStore) async throws -> (
        snapshot: MediaLibraryDatabase.Snapshot, posterPaths: [String]
    ) {
        let now = Date()
        var snapshot = MediaLibraryDatabase.Snapshot()
        var posterPaths: [String] = []
        for i in 0..<2_000 {
            let path = root.appendingPathComponent("Videos/Movie \(i).mkv").path
            let file = MediaLibraryFile(
                path: path, size: 1, modified: now, added: now,
                video: VideoTitle(title: "Movie \(i)", year: 2000 + i % 25))
            snapshot.files.append(file)
            if i < 200, let key = file.metadataKey {
                let poster = try await store.artwork.store(noisyPNG(seed: UInt64(i + 1)))
                snapshot.metadata[key] = MediaEnrichment(
                    title: "Movie \(i)", posterPath: poster)
                posterPaths.append(path)
            }
            if i % 60 == 5 {
                snapshot.progress[path] = WatchProgress(
                    path: path, position: 600, duration: 6_000, completed: false, updated: now)
            }
        }
        for i in 0..<5_000 {
            snapshot.files.append(
                MediaLibraryFile(
                    path: root.appendingPathComponent("Music/Album \(i / 10)/\(i).flac").path,
                    size: 1, modified: now, added: now,
                    audio: LocalAudioTags(
                        title: "Track \(i)", artist: "Artist \(i / 50)", album: "Album \(i / 10)",
                        year: 2024, track: i % 10 + 1, disc: 1, duration: 210, codec: "FLAC",
                        sampleRate: 96_000, bitDepth: 24, isLossless: true)))
        }
        store.snapshot = snapshot
        store.notifyCatalogChanged()
        return (snapshot, posterPaths)
    }

    private func noisyPNG(seed: UInt64) -> Data {
        let size = 480
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        if let pointer = bitmap.bitmapData {
            var state = seed &* 0x9E37_79B9_7F4A_7C15
            for i in 0..<(bitmap.bytesPerRow * size) {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                pointer[i] = UInt8(truncatingIfNeeded: state >> 56)
            }
        }
        return bitmap.representation(using: .png, properties: [:])!
    }

    private func sampleWindow(seconds: Double) async throws -> [String: Double] {
        let start = BenchResources.capture()
        try await Task.sleep(for: .seconds(seconds))
        let end = BenchResources.capture()
        let wall = Double(end.wallNs - start.wallNs) / 1e9
        return [
            "phys_footprint_mib": mib(end.footprint),
            "rss_mib": mib(end.rss),
            "cpu_pct_one_core": round2(Double(end.cpuNs - start.cpuNs) / 1e9 / wall * 100),
            "interrupt_wakeups_per_s": round2(Double(end.wakeups - start.wakeups) / wall),
        ]
    }

    private func stats(_ samples: [Double]) -> [String: Double] {
        let sorted = samples.sorted()
        func pct(_ p: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        return [
            "count": Double(sorted.count), "p50_ms": round2(pct(0.5)), "p95_ms": round2(pct(0.95)),
            "max_ms": round2(sorted.last ?? 0),
        ]
    }

    private func ms(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
        let c = start.duration(to: end).components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    private func mib(_ bytes: UInt64) -> Double { round2(Double(bytes) / 1_048_576) }
    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

@MainActor
private final class BenchInbox {
    struct Reply {
        let message: Message
        let at: ContinuousClock.Instant
    }
    var replies: [UUID: Reply] = [:]
    var states: [(state: PlayerState, at: ContinuousClock.Instant)] = []

    func receive(_ message: Message) {
        let at = ContinuousClock.now
        switch message {
        case .library(_, let page): replies[page.replyTo] = Reply(message: message, at: at)
        case .artwork(_, let art): replies[art.replyTo] = Reply(message: message, at: at)
        case .ack(_, let ack): replies[ack.replyTo] = Reply(message: message, at: at)
        case .error(_, let error):
            if let id = error.replyTo { replies[id] = Reply(message: message, at: at) }
        case .state(_, let state): states.append((state, at))
        default: break
        }
    }
}

private struct BenchResources {
    let footprint: UInt64
    let rss: UInt64
    let cpuNs: UInt64
    let wakeups: UInt64
    let wallNs: UInt64

    static func capture() -> BenchResources {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        precondition(rc == 0)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let num = UInt64(max(1, timebase.numer))
        let den = UInt64(max(1, timebase.denom))
        func ns(_ ticks: UInt64) -> UInt64 { (ticks / den) * num + ((ticks % den) * num) / den }
        return BenchResources(
            footprint: info.ri_phys_footprint, rss: info.ri_resident_size,
            cpuNs: ns(info.ri_user_time &+ info.ri_system_time),
            wakeups: info.ri_interrupt_wkups, wallNs: ns(mach_continuous_time()))
    }
}

/// Polls physical footprint off the main actor to catch the burst peak.
private final class BenchPeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var running = true
    private var thread: Thread?

    func start() {
        let thread = Thread { [self] in
            while self.isRunning {
                self.record(BenchResources.capture().footprint)
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        self.thread = thread
        thread.start()
    }

    func stop() -> UInt64 {
        lock.withLock { running = false }
        Thread.sleep(forTimeInterval: 0.05)
        return lock.withLock { peak }
    }

    private var isRunning: Bool { lock.withLock { running } }
    private func record(_ value: UInt64) { lock.withLock { peak = max(peak, value) } }
}

@MainActor
private final class BenchHitchTracker {
    private var timer: Timer?
    private var lastTick = ContinuousClock.now
    private var maxGapMs: Double = 0

    func start() {
        lastTick = .now
        maxGapMs = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ContinuousClock.now
                let c = self.lastTick.duration(to: now).components
                let gap = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
                self.maxGapMs = max(self.maxGapMs, gap)
                self.lastTick = now
            }
        }
    }

    func stop() -> Double {
        timer?.invalidate()
        timer = nil
        return maxGapMs
    }
}
