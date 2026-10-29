import AppKit
import Foundation
import Testing

@testable import Kinrox

@Suite("libmpv: audio and subtitle tracks", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MPVTrackTests {
    @Test("Embedded selection, nested sidecars, Off, failure recovery and file changes")
    func realTracks() async throws {
        let fixture = try TrackMediaFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let player = try MPVPlayer()
        let model = PlayerViewModel(engine: player)
        let controller = model.trackController
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 640, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = VideoHostView(videoLayer: player.videoLayer)
        window.orderFrontRegardless()
        do {
            try player.setVolume(0)
            #expect(model.open(url: fixture.video))
            try await wait { controller.isReady && !controller.isScanning && model.position > 0.1 }
            try player.setPaused(true)
            try await wait { model.paused }
            #expect(model.volume == 0)
            #expect(controller.available(.audio).count == 2)
            #expect(controller.available(.subtitle).count == 2)
            #expect(controller.available(.audio).map(\.language) == ["eng", "rus"])
            #expect(controller.matchingFiles(.audio).contains { $0.url == fixture.audio })
            #expect(controller.matchingFiles(.subtitle).contains { $0.url == fixture.subtitle })
            #expect(
                controller.files.contains {
                    $0.url.lastPathComponent == "02.srt" && !$0.matchesVideo
                })

            let russian = try #require(controller.available(.audio).first { $0.language == "rus" })
            controller.select(russian)
            try await wait {
                controller.available(.audio).contains {
                    $0.number == russian.number && $0.isSelected
                }
            }
            let subtitle = try #require(controller.available(.subtitle).last)
            controller.select(subtitle)
            try await wait {
                controller.available(.subtitle).contains {
                    $0.number == subtitle.number && $0.isSelected
                }
            }
            controller.disableSubtitles()
            try await wait { !controller.available(.subtitle).contains(where: \.isSelected) }

            let external = try #require(controller.files.first { $0.url == fixture.subtitle })
            controller.select(external)
            try await wait { controller.loadedTrack(for: external)?.isSelected == true }
            let externalAudio = try #require(controller.files.first { $0.url == fixture.audio })
            controller.select(externalAudio)
            try await wait { controller.loadedTrack(for: externalAudio)?.isSelected == true }
            #expect(model.paused)
            #expect(model.volume == 0)
            #expect(model.errorMessage == nil)

            controller.addFile(fixture.broken, kind: .subtitle)
            try await wait { controller.message != nil }
            #expect(model.errorMessage == nil && model.hasMedia)
            #expect(controller.loadedTrack(for: external)?.isSelected == true)
            controller.setRemember(false)
            controller.addFile(fixture.subtitle, kind: .subtitle)
            #expect(model.open(url: fixture.next))
            try await wait {
                controller.isReady && controller.video == fixture.next && !controller.isScanning
            }
            #expect(controller.tracks.allSatisfy { $0.externalURL == nil })
            window.close()
            await model.shutdown()
        } catch {
            window.close()
            await model.shutdown()
            throw error
        }
    }

    private func wait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation)
        async throws
    {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "Track state did not arrive", sourceLocation: sourceLocation)
    }
}

/// Synthetic, locally generated fixtures. Every path belongs to this unique test directory.
struct TrackMediaFixture {
    let root: URL
    var video: URL { root.appendingPathComponent("Show.S01E01.mkv") }
    var next: URL { root.appendingPathComponent("Show.S01E02.mkv") }
    var audio: URL { root.appendingPathComponent("Audio/Studio/deep/01.mka") }
    var subtitle: URL { root.appendingPathComponent("Subtitles/Russian/Group/deep/01.srt") }
    var broken: URL { root.appendingPathComponent("broken.srt") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinrox-track-media-\(UUID())")
        let manager = FileManager.default
        for url in [audio, subtitle] {
            try manager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let source = root.appendingPathComponent("embedded.srt")
        let text = "1\n00:00:00,000 --> 00:00:10,000\nKinrox track test\n"
        try text.write(to: source, atomically: true, encoding: .utf8)
        try text.write(to: subtitle, atomically: true, encoding: .utf8)
        try text.write(
            to: subtitle.deletingLastPathComponent().appendingPathComponent("02.srt"),
            atomically: true, encoding: .utf8)
        try "This is not a subtitle file".write(to: broken, atomically: true, encoding: .utf8)
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("DerivedData/M1Media/h264.mkv")
        try Self.ffmpeg([
            "-i", base.path, "-i", source.path, "-map", "0:v", "-map", "0:a", "-map", "0:a",
            "-map", "1:s", "-map", "1:s", "-c", "copy", "-metadata:s:a:0", "language=eng",
            "-metadata:s:a:0", "title=Original", "-metadata:s:a:1", "language=rus",
            "-metadata:s:a:1", "title=Studio",
            "-metadata:s:s:0", "language=eng", "-metadata:s:s:1", "language=rus", video.path,
        ])
        try Self.ffmpeg(["-i", base.path, "-map", "0:a", "-c", "copy", audio.path])
        try manager.copyItem(at: video, to: next)
    }

    private static func ffmpeg(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = ["-hide_banner", "-loglevel", "error", "-n"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(
            process.terminationStatus == 0,
            "ffmpeg fixture generation failed; run Scripts/make-test-media.sh first")
    }
}
