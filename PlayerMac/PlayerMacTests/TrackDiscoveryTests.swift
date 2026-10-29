import Foundation
import Testing

@testable import Kinrox

@Suite("Recursive track discovery")
struct TrackDiscoveryTests {
    @Test("Nested tracks, VobSub pairs, hidden files and symlink cycles")
    func scansNestedFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinrox-track-scan-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func file(_ path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        for path in [
            "Show.S01E01.mkv", "Show.S01E01.en.srt", "Audio/Studio/deep/01.MKA",
            "Subtitles/ru/group/deeper/01.ass", "Subtitles/ru/02.srt", "Vob/01.idx", "Vob/01.sub",
            ".hidden/01.srt", "Notes.txt", "App.app/01.srt",
        ] { try file(path) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let video = root.appendingPathComponent("Show.S01E01.mkv")
        var all: [TrackFile] = []
        for await update in TrackFileScanner.scan(root: root, video: video, recursive: true) {
            all += update.files
        }
        #expect(all.count == 5)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(
            all.contains {
                $0.relativePath == "Audio/Studio/deep/01.MKA" && $0.matchesVideo
                    && $0.kind == .audio
            })
        #expect(all.contains { $0.relativePath == "Subtitles/ru/02.srt" && !$0.matchesVideo })
        #expect(!all.contains { $0.url.pathExtension == "sub" })
        var shallow: [TrackFile] = []
        for await update in TrackFileScanner.scan(root: root, video: video, recursive: false) {
            shallow += update.files
        }
        #expect(shallow.map(\.relativePath) == ["Show.S01E01.en.srt"])
    }

    @Test(
        "Matching respects episode, title boundaries and season",
        arguments: [
            ("Show.S01E01.mkv", "Audio/01.mka", true),
            ("Show.S01E01.mkv", "Subs/Show.S01E01.ru.ass", true),
            ("Show.S01E01.mkv", "Subs/Show.S01E02.ru.ass", false),
            ("Show.S01E01.mkv", "Subs/Other.S01E01.ru.ass", false),
            ("Show.S01E01.mkv", "Season 02/Subs/01.ass", false),
            ("[Release] Show - 01 [1080p HEVC].mkv", "Subtitles/01.ass", true),
            ("Film.mkv", "Subtitles/Film.en.srt", true),
            ("Film.mkv", "Subtitles/Film2.en.srt", false),
            ("Show.S01E01.mkv", "Subs/1080p.ass", false),
        ])
    func matching(_ example: (String, String, Bool)) {
        let root = URL(fileURLWithPath: "/Series")
        #expect(
            TrackFileMatcher.matches(
                root.appendingPathComponent(example.1),
                video: root.appendingPathComponent(example.0)) == example.2)
    }
}
