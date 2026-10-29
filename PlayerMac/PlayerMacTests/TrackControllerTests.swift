import Foundation
import Testing

@testable import Kinrox

@Suite("Track selection and preferences", .timeLimit(.minutes(1)))
@MainActor
struct TrackControllerTests {
    private let video = URL(fileURLWithPath: "/Series/Show.S01E01.mkv")

    private func make(
        _ engine: FakePlayerEngine,
        scanner: @escaping TrackController.Scanner = { _, _, _ in
            AsyncStream { $0.finish() }
        }
    ) throws -> TrackController {
        let defaults = try #require(UserDefaults(suiteName: "kinrox-track-tests-\(UUID())"))
        return TrackController(
            engine: engine, preferences: TrackPreferences(defaults: defaults), scanner: scanner)
    }

    private var audio: [MediaTrack] {
        [
            MediaTrack(
                number: 1, kind: .audio, title: "Original", language: "eng", isSelected: true),
            MediaTrack(number: 2, kind: .audio, title: "Studio", language: "rus"),
        ]
    }

    private func load(_ controller: TrackController, url: URL? = nil, tracks: [MediaTrack]? = nil) {
        let url = url ?? video
        controller.prepare(for: url)
        controller.loaded(path: url.path, tracks: tracks ?? audio)
    }

    private func settle() async { for _ in 0..<30 { await Task.yield() } }

    @Test("Selection waits for engine state; saved language resolves a new track number")
    func selectsAndRestores() async throws {
        let engine = FakePlayerEngine()
        let controller = try make(engine)
        load(controller)
        controller.select(audio[1])
        #expect(controller.tracks.first?.isSelected == true)
        #expect(engine.commands.last == .selectTrack(.audio, 2, 1))
        controller.completed(id: 1, error: nil)
        var next = audio[1]
        next = MediaTrack(number: 8, kind: .audio, title: next.title, language: next.language)
        load(
            controller,
            url: video.deletingLastPathComponent().appendingPathComponent("Show.S01E02.mkv"),
            tracks: [audio[0], next])
        #expect(engine.commands.last == .selectTrack(.audio, 8, 2))
        controller.close()
    }

    @Test("Off survives the next episode; disabling remember clears stored choices")
    func subtitlesOff() async throws {
        let engine = FakePlayerEngine()
        let controller = try make(engine)
        load(controller)
        controller.disableSubtitles()
        controller.completed(id: 1, error: nil)
        load(
            controller,
            url: video.deletingLastPathComponent().appendingPathComponent("Show.S01E02.mkv"))
        #expect(engine.commands.last == .selectTrack(.subtitle, nil, 2))
        controller.completed(id: 2, error: nil)
        controller.setRemember(false)
        #expect(controller.settings?.subtitle == nil)
        engine.commands.removeAll()
        load(controller)
        await settle()
        #expect(engine.commands.isEmpty)
        controller.close()
    }

    @Test("External attach handles reply-before-list and repeated clicks without duplicates")
    func externalAttach() throws {
        let engine = FakePlayerEngine()
        let controller = try make(engine)
        load(controller)
        let file = TrackFile(
            url: URL(fileURLWithPath: "/Series/Subs/01.ass"), kind: .subtitle,
            relativePath: "Subs/01.ass", matchesVideo: true)
        controller.select(file)
        controller.select(file)
        #expect(engine.commands == [.addTrack(file.url, .subtitle, 1)])
        controller.completed(id: 1, error: nil)
        #expect(engine.commands.count == 1)
        let track = MediaTrack(number: 9, kind: .subtitle, externalURL: file.url)
        controller.update(audio + [track])
        #expect(engine.commands.last == .selectTrack(.subtitle, 9, 2))
        controller.completed(id: 2, error: nil)
        controller.update(audio + [track])
        #expect(engine.commands.count == 2)
        controller.close()
    }

    @Test("Off cancels an in-flight subtitle; stale completion cannot select it")
    func manualChoiceWins() throws {
        let engine = FakePlayerEngine()
        let controller = try make(engine)
        load(controller)
        let file = TrackFile(
            url: URL(fileURLWithPath: "/Series/01.srt"), kind: .subtitle,
            relativePath: "01.srt", matchesVideo: true)
        controller.select(file)
        controller.disableSubtitles()
        controller.update([MediaTrack(number: 4, kind: .subtitle, externalURL: file.url)])
        controller.completed(id: 1, error: nil)
        #expect(
            engine.commands == [
                .addTrack(file.url, .subtitle, 1), .cancelTrack(1), .selectTrack(.subtitle, nil, 2),
            ])
        controller.close()
    }

    @Test("Cancelled scan and loaded events for an earlier video are ignored")
    func staleDiscovery() async throws {
        let old = AsyncStream<TrackScanUpdate>.makeStream()
        let new = AsyncStream<TrackScanUpdate>.makeStream()
        let engine = FakePlayerEngine()
        let controller = try make(engine) { _, url, _ in
            url.lastPathComponent.contains("E01") ? old.stream : new.stream
        }
        load(controller)
        let next = video.deletingLastPathComponent().appendingPathComponent("Show.S01E02.mkv")
        controller.prepare(for: next)
        controller.loaded(path: video.path, tracks: audio)
        #expect(!controller.isReady)
        controller.loaded(path: next.path, tracks: [])
        let stale = TrackFile(url: video, kind: .subtitle, relativePath: "old", matchesVideo: true)
        old.continuation.yield(.init(files: [stale], folders: 99))
        old.continuation.finish()
        new.continuation.yield(.init(folders: 2))
        new.continuation.finish()
        await settle()
        #expect(controller.files.isEmpty)
        #expect(controller.foldersScanned == 2)
        #expect(!controller.isScanning)
        controller.close()
    }

    @Test("Failed selection preserves previous preference and playback state")
    func failedCommand() throws {
        let engine = FakePlayerEngine()
        let controller = try make(engine)
        load(controller)
        controller.select(audio[1])
        controller.completed(id: 1, error: "unavailable")
        #expect(controller.settings?.audio == nil)
        #expect(controller.tracks[0].isSelected)
        #expect(controller.message != nil)
        #expect(controller.presentation == .quick)
        controller.close()
    }

    @Test("Next episode restores the selected stream inside an external multi-track file")
    func externalPreference() async throws {
        let engine = FakePlayerEngine()
        let nextFile = TrackFile(
            url: URL(fileURLWithPath: "/Series/Audio/02.mka"), kind: .audio,
            relativePath: "Audio/02.mka", matchesVideo: true)
        let controller = try make(engine) { _, _, _ in
            AsyncStream {
                $0.yield(.init(files: [nextFile]))
                $0.finish()
            }
        }
        let first = MediaTrack(
            number: 3, kind: .audio, title: "Episode 01 - [Studio]", language: "rus",
            externalURL: URL(fileURLWithPath: "/Series/Audio/01.mka"))
        load(controller, tracks: audio + [first])
        controller.select(first)
        controller.completed(id: 1, error: nil)
        load(
            controller,
            url: video.deletingLastPathComponent().appendingPathComponent("Show.S01E02.mkv"))
        await settle()
        #expect(engine.commands.last == .addTrack(nextFile.url, .audio, 2))
        let tracks = [
            MediaTrack(
                number: 7, kind: .audio, title: "Original", language: "eng",
                externalURL: nextFile.url),
            MediaTrack(
                number: 8, kind: .audio, title: "Episode 02 - [Studio]", language: "rus",
                externalURL: nextFile.url
            ),
        ]
        controller.update(audio + tracks)
        controller.completed(id: 2, error: nil)
        #expect(engine.commands.last == .selectTrack(.audio, 8, 3))
        var selected = tracks[1]
        selected.isSelected = true
        controller.update(audio + [tracks[0], selected])
        #expect(controller.loadedTrack(for: nextFile)?.number == 8)
        controller.close()
    }

    @Test("Cycling includes discovered external subtitles before Off")
    func cycleExternal() async throws {
        let engine = FakePlayerEngine()
        let file = TrackFile(
            url: URL(fileURLWithPath: "/Series/01.srt"), kind: .subtitle,
            relativePath: "01.srt", matchesVideo: true)
        let controller = try make(engine) { _, _, _ in
            AsyncStream {
                $0.yield(.init(files: [file]))
                $0.finish()
            }
        }
        load(controller, tracks: [MediaTrack(number: 1, kind: .subtitle, isSelected: true)])
        await settle()
        controller.cycle(.subtitle)
        #expect(engine.commands.last == .addTrack(file.url, .subtitle, 1))
        let external = MediaTrack(
            number: 2, kind: .subtitle, isSelected: true, externalURL: file.url)
        controller.update([MediaTrack(number: 1, kind: .subtitle), external])
        controller.completed(id: 1, error: nil)
        controller.completed(id: 2, error: nil)
        controller.cycle(.subtitle)
        #expect(engine.commands.last == .selectTrack(.subtitle, nil, 3))
        controller.close()
    }

    @Test("External filenames keep language and release group when the episode changes")
    func filenamePreference() {
        let selected = URL(fileURLWithPath: "/Series/Subs/Show.S01E01.ru.[Studio].srt")
        let preference = TrackPreference(
            track: MediaTrack(
                number: 2, kind: .subtitle,
                title: selected.lastPathComponent, externalURL: selected))
        func file(_ name: String) -> TrackFile {
            TrackFile(
                url: selected.deletingLastPathComponent().appendingPathComponent(name),
                kind: .subtitle, relativePath: name, matchesVideo: true)
        }
        #expect(preference.title.isEmpty)
        #expect(preference.matches(file("Show.S01E02.ru.[Studio].srt")))
        #expect(!preference.matches(file("Show.S01E02.en.[Studio].srt")))
        #expect(!preference.matches(file("Show.S01E02.ru.[Another].srt")))
    }
}
