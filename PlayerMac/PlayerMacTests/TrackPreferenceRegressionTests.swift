import Foundation
import Testing

@testable import Kinrox

@Suite("Track preference regressions", .timeLimit(.minutes(1)))
@MainActor
struct TrackPreferenceRegressionTests {
    private let video = URL(fileURLWithPath: "/Series/Video/Show.S01E01.mkv")

    private func make(
        _ engine: FakePlayerEngine,
        scanner: @escaping TrackController.Scanner = { _, _, _ in AsyncStream { $0.finish() } }
    ) throws -> TrackController {
        let defaults = try #require(UserDefaults(suiteName: "kinrox-track-review-\(UUID())"))
        return TrackController(
            engine: engine, preferences: TrackPreferences(defaults: defaults), scanner: scanner)
    }

    private func waitForScan(_ controller: TrackController) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.isScanning, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!controller.isScanning)
    }

    @Test(
        "Metadata preserves bracket labels while explicit episode numbers may change",
        arguments: [
            ("Russian [Studio A]", "Russian [Studio A]", "Russian [Studio B]"),
            ("[Studio A]", "[Studio A]", "[Studio B]"),
            ("English [Full]", "English [Full]", "English [Signs & Songs]"),
            ("Episode 01 - [Studio]", "Episode 02 - [Studio]", "Episode 02 - [Other]"),
            ("Show S01E01 [SDH]", "Show S01E02 [SDH]", "Show S01E02 [Full]"),
            ("Studio 1", "Studio 1", "Studio 2"),
            ("Surround 5.1", "Surround 5.1", "Surround 7.1"),
        ])
    func metadataIdentity(_ titles: (String, String, String)) {
        let preference = TrackPreference(
            track: MediaTrack(number: 1, kind: .audio, title: titles.0))
        #expect(preference.matches(MediaTrack(number: 8, kind: .audio, title: titles.1)))
        #expect(!preference.matches(MediaTrack(number: 9, kind: .audio, title: titles.2)))
    }

    @Test("Missing external preference retries after refresh or scope changes", arguments: 0...2)
    func retriesDiscovery(_ change: Int) async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("kinrox-track-retry-\(UUID())")
        let videoFolder = root.appendingPathComponent("Video")
        let subtitleFolder = (change == 1 ? root : videoFolder).appendingPathComponent("Subs")
        try manager.createDirectory(at: subtitleFolder, withIntermediateDirectories: true)
        try manager.createDirectory(at: videoFolder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let video = videoFolder.appendingPathComponent("Show.S01E01.mkv")
        let url = subtitleFolder.appendingPathComponent("01.srt").resolvingSymlinksInPath()
        let track = MediaTrack(number: 2, kind: .subtitle, externalURL: url)
        let defaults = try #require(UserDefaults(suiteName: "kinrox-retry-\(UUID())"))
        let store = TrackPreferences(defaults: defaults)
        store.save(
            TrackFolderSettings(
                root: videoFolder.resolvingSymlinksInPath(), recursive: change != 2,
                subtitle: TrackPreference(track: track)), for: video)
        let engine = FakePlayerEngine()
        let controller = TrackController(engine: engine, preferences: store)
        controller.prepare(for: video)
        controller.loaded(path: video.path, tracks: [])
        try await waitForScan(controller)
        #expect(controller.message != nil)
        #expect(engine.commands.isEmpty)
        try Data().write(to: url)
        if change == 0 {
            controller.refresh()
        } else {
            controller.applySettings(
                root: change == 1 ? root : videoFolder, recursive: true, remember: true)
        }
        try await waitForScan(controller)
        #expect(controller.message == nil)
        #expect(engine.commands.last == .addTrack(url, .subtitle, 1))
        controller.update([track])
        controller.completed(id: 1, error: nil)
        controller.completed(id: 2, error: nil)
        let commandCount = engine.commands.count
        controller.refresh()
        try await waitForScan(controller)
        #expect(engine.commands.count == commandCount)
        controller.disableSubtitles()
        controller.completed(id: 3, error: nil)
        controller.refresh()
        try await waitForScan(controller)
        #expect(engine.commands.last == .selectTrack(.subtitle, nil, 3))
        controller.close()
    }

    @Test("Enabling remember saves confirmed manual audio and Off, but no untouched defaults")
    func enablesRememberAfterSelection() throws {
        let engine = FakePlayerEngine()
        let controller = try make(engine)
        let original = MediaTrack(number: 1, kind: .audio, title: "Original", isSelected: true)
        let selected = MediaTrack(number: 2, kind: .audio, title: "Studio")
        controller.prepare(for: video)
        controller.loaded(path: video.path, tracks: [original, selected])
        controller.setRemember(false)
        controller.select(selected)
        controller.completed(id: 1, error: nil)
        controller.disableSubtitles()
        controller.completed(id: 2, error: nil)
        controller.setRemember(true)
        #expect(controller.settings?.audio == TrackPreference(track: selected))
        #expect(controller.settings?.subtitle?.disabled == true)
        controller.prepare(for: video)
        controller.loaded(path: video.path, tracks: [original, selected])
        #expect(engine.commands.contains(.selectTrack(.audio, 2, 3)))
        #expect(engine.commands.contains(.selectTrack(.subtitle, nil, 4)))
        controller.close()

        let untouched = try make(FakePlayerEngine())
        untouched.prepare(for: video)
        untouched.loaded(path: video.path, tracks: [original])
        untouched.setRemember(false)
        untouched.setRemember(true)
        #expect(untouched.settings?.audio == nil)
        #expect(untouched.settings?.subtitle == nil)
        untouched.close()
    }

    @Test("Failed manual choices are not persisted when enabling remember")
    func failedChoiceIsNotRemembered() throws {
        let engine = FakePlayerEngine()
        let controller = try make(engine)
        let track = MediaTrack(number: 2, kind: .audio, title: "Studio")
        controller.prepare(for: video)
        controller.loaded(path: video.path, tracks: [track])
        controller.setRemember(false)
        controller.select(track)
        controller.completed(id: 1, error: "unavailable")
        controller.setRemember(true)
        #expect(controller.settings?.audio == nil)
        controller.close()
    }

    @Test("Stop allows reloading the same file to restore a cancelled preference")
    func stopResetsRestoration() throws {
        let engine = FakePlayerEngine()
        let controller = try make(engine)
        let track = MediaTrack(number: 2, kind: .audio, title: "Studio")
        controller.prepare(for: video)
        controller.loaded(path: video.path, tracks: [track])
        controller.select(track)
        controller.completed(id: 1, error: nil)
        controller.stop()
        controller.loaded(path: video.path, tracks: [track])
        #expect(engine.commands.last == .selectTrack(.audio, 2, 2))
        controller.stop()
        controller.loaded(path: video.path, tracks: [track])
        #expect(engine.commands.last == .selectTrack(.audio, 2, 3))
        controller.close()
    }

    @Test("Symlink aliases share settings, relative paths and loaded-file identity")
    func symlinkIdentity() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("kinrox-track-links-\(UUID())")
        let real = root.appendingPathComponent("Series")
        let alias = root.appendingPathComponent("Link")
        try manager.createDirectory(
            at: real.appendingPathComponent("Subs"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createSymbolicLink(at: alias, withDestinationURL: real)
        let actualVideo = real.appendingPathComponent("01.mkv")
        let linkedVideo = alias.appendingPathComponent("01.mkv")
        let actualSub = real.appendingPathComponent("Subs/01.srt")
        try Data().write(to: actualVideo)
        try Data().write(to: actualSub)
        let defaults = try #require(UserDefaults(suiteName: "kinrox-track-links-\(UUID())"))
        let preferences = TrackPreferences(defaults: defaults)
        #expect(preferences.settings(for: linkedVideo).root == real.resolvingSymlinksInPath())
        var settings = preferences.settings(for: linkedVideo)
        settings.recursive = false
        preferences.save(settings, for: linkedVideo)
        #expect(!TrackPreferences(defaults: defaults).settings(for: actualVideo).recursive)
        #expect(TrackFile.relativePath(actualSub, root: alias) == "Subs/01.srt")
        #expect(
            TrackFile.relativePath(alias.appendingPathComponent("Subs/01.srt"), root: real)
                == "Subs/01.srt")
        let controller = TrackController(engine: FakePlayerEngine(), preferences: preferences)
        controller.prepare(for: linkedVideo)
        let track = MediaTrack(number: 1, kind: .subtitle, externalURL: actualSub)
        controller.loaded(path: actualVideo.path, tracks: [track])
        #expect(controller.isReady)
        try await waitForScan(controller)
        controller.applySettings(root: alias, recursive: false, remember: true)
        #expect(!controller.isScanning)
        controller.close()
    }
}
