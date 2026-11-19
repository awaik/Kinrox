import AVFoundation
import AppKit
import Darwin
import Foundation
import MetaBrainzAPI
import SwiftUI
import Testing

@testable import Kinrox

@Suite("Unified Home Release measurements", .serialized, .timeLimit(.minutes(10)))
@MainActor
struct HomeReleaseBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KINROX_HOME_RELEASE_BENCH"] == "1"))
    func measureUnifiedHomeScanAndLocalAudioInRelease() async throws {
        let env = ProcessInfo.processInfo.environment
        let outPath =
            env["KINROX_HOME_BENCH_OUT"]
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("kinrox-home-bench.json").path
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KinroxHomeBench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let defaultsName = "app.kinrox.bench.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(false, forKey: MediaLibraryStore.enrichKey)
        defaults.set(false, forKey: MediaLibraryStore.autoWatchKey)

        let dataDir = workDir.appendingPathComponent("Data", isDirectory: true)
        let recents = RecentFilesStore(fileURL: dataDir.appendingPathComponent("recents.json"))
        let session = PlayerSession(recents: recents, musicDefaults: defaults)
        let store = session.mediaLibrary
        store.setEnrichMetadata(false)
        store.setAutoWatchFolders(false)
        let localAudio = session.localAudio
        #expect(localAudio.setVolume(0))
        let videoPlayer = try MPVPlayer()
        let videoModel = PlayerViewModel(engine: videoPlayer, recents: recents)
        #expect(videoModel.setVolume(0))
        session.model = videoModel
        let nowPlaying = NowPlayingController(center: FakeNowPlayingCenter())
        session.playback.connectNowPlaying(nowPlaying)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 940),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(
            rootView: HomeWorkspaceView(
                session: session, model: videoModel, actions: PlayerActions()
            ).preferredColorScheme(.dark))
        window.contentView = host
        window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 940), display: true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(1))

        var report: [String: Any] = ["pid": getpid()]

        // 1. Empty 0-folder Home idle window (4s)
        report["empty_home_idle"] = try await sampleWindow(seconds: 4)

        // 2. Build 240 mixed fixtures (120 videos + 120 silent audio files across 20 albums)
        let mediaRoot = workDir.appendingPathComponent("LibraryMedia", isDirectory: true)
        let flacTracks = try await createMixedFixtures(
            root: mediaRoot, cacheArtworkIn: store.artwork)
        let watched = try #require(MediaFolderScanner.folder(mediaRoot))
        _ = try await store.database.add(watched)

        // Cold initial scan + MainActor responsiveness probe
        let hitchTracker = HitchTracker()
        hitchTracker.start()
        let coldStart = ContinuousClock.now
        let coldResult = try await Task.detached(priority: .utility) {
            try await MediaFolderScanner.scan(
                watched, database: store.database, artwork: store.artwork
            ) { _ in }
        }.value
        let coldScanMs = milliseconds(from: coldStart)
        let maxMainActorGapMs = hitchTracker.stop()
        #expect(coldResult == .ready)
        try await store.reload()

        // Warm 0-change rescan
        let warmZeroStart = ContinuousClock.now
        _ = try await Task.detached(priority: .utility) {
            try await MediaFolderScanner.scan(
                watched, database: store.database, artwork: store.artwork
            ) { _ in }
        }.value
        let warmZeroScanMs = milliseconds(from: warmZeroStart)

        // Warm 1-file delta rescan
        let extraMovie = mediaRoot.appendingPathComponent("Movies/Arrival.2016.1080p.mkv")
        try Data([0, 1, 2, 3]).write(to: extraMovie)
        let warmDeltaStart = ContinuousClock.now
        _ = try await Task.detached(priority: .utility) {
            try await MediaFolderScanner.scan(
                watched, database: store.database, artwork: store.artwork
            ) { _ in }
        }.value
        let warmDeltaScanMs = milliseconds(from: warmDeltaStart)
        try await store.reload()

        report["scan"] = [
            "indexed_files": store.snapshot.files.count,
            "cold_scan_ms": round2(coldScanMs),
            "cold_scan_max_mainactor_tick_ms": round2(maxMainActorGapMs),
            "warm_zero_change_ms": round2(warmZeroScanMs),
            "warm_one_file_delta_ms": round2(warmDeltaScanMs),
        ]

        // Render populated library in session's Home view and measure populated idle (4s)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(1))
        host.layoutSubtreeIfNeeded()
        report["populated_home_idle"] = try await sampleWindow(seconds: 4)

        // 3. Local FLAC playback via real MPVAudioEngine at volume = 0
        #expect(localAudio.volume == 0)
        let startBegan = ContinuousClock.now
        #expect(localAudio.play(flacTracks, using: store))
        #expect(try await waitUntil { !localAudio.paused && !localAudio.loading })
        let coldAudioStartMs = milliseconds(from: startBegan)
        #expect(localAudio.volume == 0)

        let playingMetrics = try await sampleWindow(seconds: 6)

        let seekBegan = ContinuousClock.now
        #expect(localAudio.seek(4.0))
        #expect(try await waitUntil { abs(localAudio.position - 4.0) < 1.0 })
        let seekMs = milliseconds(from: seekBegan)

        let nextBegan = ContinuousClock.now
        let firstID = localAudio.currentTrack?.id
        #expect(localAudio.next())
        #expect(
            try await waitUntil {
                !localAudio.paused && !localAudio.loading && localAudio.currentTrack?.id != firstID
            })
        let nextMs = milliseconds(from: nextBegan)

        let pauseBegan = ContinuousClock.now
        #expect(localAudio.setPaused(true))
        #expect(try await waitUntil { localAudio.paused })
        let pauseMs = milliseconds(from: pauseBegan)

        let shortPauseMetrics = try await sampleWindow(seconds: 4)

        let warmResumeBegan = ContinuousClock.now
        #expect(localAudio.setPaused(false))
        #expect(try await waitUntil { !localAudio.paused && !localAudio.loading })
        let warmResumeMs = milliseconds(from: warmResumeBegan)

        // Seek to 5.2s, pause, and wait >20s for production engine parking teardown
        #expect(localAudio.seek(5.2))
        try await Task.sleep(for: .milliseconds(250))
        #expect(localAudio.setPaused(true))
        try await Task.sleep(for: .milliseconds(21_200))
        let parkedIdleMetrics = try await sampleWindow(seconds: 4)

        // Resume from parked state: verify zero gain + saved position restored
        let parkedResumeBegan = ContinuousClock.now
        #expect(localAudio.setPaused(false))
        #expect(try await waitUntil { !localAudio.paused && !localAudio.loading })
        let parkedResumeMs = milliseconds(from: parkedResumeBegan)
        #expect(localAudio.volume == 0)
        #expect(localAudio.position >= 4.8)

        report["local_audio_flac"] = [
            "cold_start_ms": round2(coldAudioStartMs),
            "seek_ms": round2(seekMs),
            "next_ms": round2(nextMs),
            "pause_ms": round2(pauseMs),
            "warm_resume_ms": round2(warmResumeMs),
            "post_20s_park_resume_ms": round2(parkedResumeMs),
            "post_park_restored_position_s": round2(localAudio.position),
            "post_park_volume": localAudio.volume,
            "playing_6s": playingMetrics,
            "short_pause_4s": shortPauseMetrics,
            "parked_after_20s_idle_4s": parkedIdleMetrics,
        ]

        // 4. Cross-source transition: localAudio -> video (at volume 0) -> Home (Esc) -> localAudio
        let sampleVideo = try prepareSilentVideo(in: workDir)
        if FileManager.default.fileExists(atPath: sampleVideo.path) {
            #expect(videoModel.setVolume(0))
            let toVideoBegan = ContinuousClock.now
            #expect(videoModel.open(url: sampleVideo))
            #expect(
                try await waitUntil {
                    videoModel.hasMedia && !videoModel.isLoading && !videoModel.paused
                        && localAudio.paused
                })
            let toVideoMs = milliseconds(from: toVideoBegan)
            #expect(videoModel.playbackVolume == 0)
            try await Task.sleep(for: .milliseconds(600))

            let toHomeBegan = ContinuousClock.now
            #expect(videoModel.showHome())
            #expect(try await waitUntil { videoModel.isShowingHome && videoModel.paused })
            let toHomeMs = milliseconds(from: toHomeBegan)
            let savedVideoPosition = videoModel.playbackPosition

            let backToAudioBegan = ContinuousClock.now
            #expect(localAudio.setPaused(false))
            #expect(try await waitUntil { !localAudio.paused && !localAudio.loading })
            let backToAudioMs = milliseconds(from: backToAudioBegan)
            #expect(videoModel.paused)
            #expect(videoModel.isShowingHome)
            #expect(abs(videoModel.playbackPosition - savedVideoPosition) < 0.25)

            report["cross_source"] = [
                "local_audio_to_video_ms": round2(toVideoMs),
                "video_to_home_esc_ms": round2(toHomeMs),
                "home_to_local_audio_ms": round2(backToAudioMs),
                "preserved_video_position_s": round2(videoModel.playbackPosition),
                "double_audio_observed": (!localAudio.paused && !videoModel.paused),
            ]
        }

        window.close()
        await session.playback.close()
        await videoModel.shutdown()

        let json = try JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: URL(fileURLWithPath: outPath), options: .atomic)
    }

    private func createMixedFixtures(root: URL, cacheArtworkIn artwork: ArtworkCache) async throws
        -> [URL]
    {
        let moviesDir = root.appendingPathComponent("Movies", isDirectory: true)
        let seriesDir = root.appendingPathComponent(
            "Series/The Expanse/Season_01", isDirectory: true)
        let musicDir = root.appendingPathComponent("Music", isDirectory: true)
        for dir in [moviesDir, seriesDir, musicDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for i in 1...80 {
            let url = moviesDir.appendingPathComponent(
                "Sample.Movie.\(i).\(2000 + (i % 25)).1080p.HEVC.mkv")
            try Data("video-\(i)".utf8).write(to: url)
        }
        for ep in 1...40 {
            let code = String(format: "s01e%02d", ep)
            let url = seriesDir.appendingPathComponent("\(code)_Episode.\(ep).mkv")
            try Data("ep-\(ep)".utf8).write(to: url)
        }
        // Generate real playable silent FLAC tracks via ffmpeg if available, else silent ALAC .m4a
        let flac1 = musicDir.appendingPathComponent("Album_01/01 - Silent Horizon.flac")
        let flac2 = musicDir.appendingPathComponent("Album_01/02 - Deep Field.flac")
        try FileManager.default.createDirectory(
            at: flac1.deletingLastPathComponent(), withIntermediateDirectories: true)
        let playableURLs = try makeSilentFLACPair(flac1: flac1, flac2: flac2)

        // Create remaining 118 lightweight synthetic FLAC header files across 20 albums for scan test
        let coverRep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(coverRep.representation(using: .png, properties: [:]))
        _ = try await artwork.store(png)
        for idx in 3...120 {
            let albumIdx = ((idx - 1) / 6) + 1
            let albumDir = musicDir.appendingPathComponent(
                String(format: "Album_%02d", albumIdx), isDirectory: true)
            try FileManager.default.createDirectory(at: albumDir, withIntermediateDirectories: true)
            let trackURL = albumDir.appendingPathComponent(
                String(format: "%02d - Track %03d.flac", (idx % 6) + 1, idx))
            try syntheticTaggedFLAC(
                title: "Track \(idx)", artist: "Artist \((albumIdx % 8) + 1)",
                album: "Album \(albumIdx)", trackNumber: (idx % 6) + 1, coverPNG: png
            ).write(to: trackURL)
        }
        return playableURLs
    }

    private func prepareSilentVideo(in workDir: URL) throws -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let existing = repoRoot.appendingPathComponent("DerivedData/M1Media/short-1.mp4")
        if FileManager.default.fileExists(atPath: existing.path) { return existing }
        let out = workDir.appendingPathComponent("silent-video.mp4")
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else {
            return out
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        proc.arguments = [
            "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", "color=c=black:s=640x360:r=24",
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
            "-t", "8", "-c:v", "mpeg4", "-c:a", "aac", out.path,
        ]
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0)
        return out
    }

    private func makeSilentFLACPair(flac1: URL, flac2: URL) throws -> [URL] {
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") {
            for (url, title) in [(flac1, "Silent Horizon"), (flac2, "Deep Field")] {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
                proc.arguments = [
                    "-y", "-loglevel", "error", "-f", "lavfi",
                    "-i", "anullsrc=r=44100:cl=stereo", "-t", "12",
                    "-metadata", "title=\(title)", "-metadata", "artist=Kinrox Bench",
                    "-metadata", "album=Zero Gain Suite", "-metadata", "genre=Ambient",
                    "-c:a", "flac", url.path,
                ]
                try proc.run()
                proc.waitUntilExit()
                #expect(proc.terminationStatus == 0)
            }
            return [flac1, flac2]
        }
        let m4a1 = flac1.deletingPathExtension().appendingPathExtension("m4a")
        let m4a2 = flac2.deletingPathExtension().appendingPathExtension("m4a")
        for url in [m4a1, m4a2] {
            let fmt = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
            let frames: AVAudioFrameCount = 44_100 * 12
            let buf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames))
            buf.frameLength = frames
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16,
            ]
            let out = try AVAudioFile(forWriting: url, settings: settings)
            try out.write(from: buf)
        }
        return [m4a1, m4a2]
    }

    private func syntheticTaggedFLAC(
        title: String, artist: String, album: String, trackNumber: Int, coverPNG: Data
    ) -> Data {
        func be(_ val: UInt64, _ count: Int) -> [UInt8] {
            Array((0..<count).map { UInt8(truncatingIfNeeded: val >> ($0 * 8)) }.reversed())
        }
        func le32(_ val: Int) -> [UInt8] {
            (0..<4).map { UInt8(truncatingIfNeeded: val >> ($0 * 8)) }
        }
        let rate: UInt64 = 44_100
        var stream = Data(repeating: 0, count: 10)
        stream.append(contentsOf: be((rate << 44) | (15 << 36) | (rate * 180), 8))
        stream.append(Data(repeating: 0, count: 16))
        let fields = [
            "TITLE=\(title)", "ARTIST=\(artist)", "ALBUM=\(album)",
            "GENRE=Ambient", "TRACKNUMBER=\(trackNumber)", "RATING=90",
        ]
        var vorbis = Data(le32(0) + le32(fields.count))
        for f in fields {
            vorbis.append(contentsOf: le32(f.utf8.count))
            vorbis.append(contentsOf: f.utf8)
        }
        let pic =
            Data(be(3, 4) + be(9, 4)) + Data("image/png".utf8) + Data(repeating: 0, count: 20)
            + Data(be(UInt64(coverPNG.count), 4)) + coverPNG
        func blk(_ type: UInt8, _ payload: Data) -> Data {
            Data([type] + be(UInt64(payload.count), 3)) + payload
        }
        return Data("fLaC".utf8) + blk(0, stream) + blk(4, vorbis) + blk(0x86, pic)
    }

    private func sampleWindow(seconds: Double) async throws -> [String: Double] {
        let before = ResourceSnapshot.capture()
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        let after = ResourceSnapshot.capture()
        let wallSec = max(0.001, Double(after.wallNs &- before.wallNs) / 1_000_000_000.0)
        let cpuPct =
            Double(after.cpuNs &- before.cpuNs) / Double(after.wallNs &- before.wallNs) * 100.0
        let wakeupsPerSec = Double(after.wakeups &- before.wakeups) / wallSec
        return [
            "phys_footprint_mib": round2(Double(after.footprint) / 1_048_576.0),
            "rss_mib": round2(Double(after.rss) / 1_048_576.0),
            "cpu_pct_one_core": round2(cpuPct),
            "interrupt_wakeups_per_s": round2(wakeupsPerSec),
        ]
    }

    private func waitUntil(_ predicate: () -> Bool) async throws -> Bool {
        for _ in 0..<240 {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    private func milliseconds(from start: ContinuousClock.Instant) -> Double {
        let c = start.duration(to: .now).components
        return Double(c.seconds) * 1000.0 + Double(c.attoseconds) / 1_000_000_000_000_000.0
    }

    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

private struct ResourceSnapshot {
    let footprint: UInt64
    let rss: UInt64
    let cpuNs: UInt64
    let wakeups: UInt64
    let wallNs: UInt64

    static func capture() -> ResourceSnapshot {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
            }
        }
        precondition(rc == 0)
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let num = UInt64(max(1, tb.numer))
        let den = UInt64(max(1, tb.denom))
        let cpuTicks = info.ri_user_time &+ info.ri_system_time
        let cpuNs = (cpuTicks / den) * num + ((cpuTicks % den) * num) / den
        let wallTicks = mach_continuous_time()
        let wallNs = (wallTicks / den) * num + ((wallTicks % den) * num) / den
        return ResourceSnapshot(
            footprint: info.ri_phys_footprint, rss: info.ri_resident_size,
            cpuNs: cpuNs, wakeups: info.ri_interrupt_wkups, wallNs: wallNs)
    }
}

@MainActor
private final class HitchTracker {
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
                let gap = Double(c.seconds) * 1000.0 + Double(c.attoseconds) / 1e15
                if gap > self.maxGapMs { self.maxGapMs = gap }
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
