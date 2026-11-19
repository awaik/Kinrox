import AppKit
import SwiftUI
import Testing

@testable import Kinrox

@Suite("Home workspace layout", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct WelcomeLayoutTests {
    @Test(
        "Home content stays inside the window when recents and window sizes change",
        arguments: [0, 1, 4, 20])
    func recentFilesDoNotDisplaceWelcome(itemCount: Int) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinrox-welcome-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("recent.json")
        let items = (0..<itemCount).map { index in
            RecentItem(
                id: UUID(),
                title: "A long series name - Season 01 Episode \(index) - 2160p WEB-DL.mkv",
                path: directory.appendingPathComponent("Episode \(index).mkv").path,
                openedAt: Date(), duration: 1800, bookmark: nil)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(items).write(to: fileURL)
        let recents = RecentFilesStore(fileURL: fileURL)
        let session = PlayerSession(recents: recents)
        let model = PlayerViewModel(engine: FakePlayerEngine())
        session.homeSection = itemCount == 0 ? .overview : .recent
        let host = NSHostingView(
            rootView: HomeWorkspaceView(session: session, model: model, actions: PlayerActions())
                .preferredColorScheme(.dark))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 630), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        // Exercise shrinking and growing the same hosted screen, including the minimum width.
        for width: CGFloat in [1120, 640, 1440, 2560, 1120] {
            window.setContentSize(NSSize(width: width, height: 630))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()

            let scroll = try #require(scrollView(in: host))
            let document = try #require(scroll.documentView)
            let viewport = host.convert(scroll.contentView.bounds, from: scroll.contentView)
            #expect(abs(host.bounds.width - width) < 1)
            // This is a vertical scroll view: neither its viewport nor its content may overflow
            // horizontally, otherwise the centered hero and trailing actions become unreachable.
            #expect(document.frame.width <= scroll.contentView.bounds.width + 1)
            #expect(viewport.minX >= host.bounds.minX - 1)
            #expect(viewport.maxX <= host.bounds.maxX + 1)

            if let directory = ProcessInfo.processInfo.environment["KINROX_WELCOME_SNAPSHOTS"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent(
                        "welcome-\(itemCount)-\(Int(width)).png"))
            }
        }
    }

    @Test("Continue Watching and the empty library fit without horizontal overflow")
    func continueWatchingBannerFitsAcrossWindowWidths() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinrox-welcome-active-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("recent.json")
        let movieURL = directory.appendingPathComponent(
            "A long series name - Season 01 Episode 02 - 2160p WEB-DL.mkv")
        let items = (0..<6).map { index in
            RecentItem(
                id: UUID(),
                title: "A long series name - Season 01 Episode 0\(index) - 2160p WEB-DL.mkv",
                path: directory.appendingPathComponent(
                    "A long series name - Season 01 Episode 0\(index) - 2160p WEB-DL.mkv"
                ).path,
                openedAt: Date(), duration: 3600, bookmark: nil)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(items).write(to: fileURL)
        let recents = RecentFilesStore(fileURL: fileURL)
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine, recents: recents)
        model.open(url: movieURL)
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.property(.duration, .number(3600)))
        model.receive(.property(.position, .number(1240)))
        _ = model.showHome()
        model.receive(.property(.paused, .flag(true)))

        let session = PlayerSession(recents: recents)
        let host = NSHostingView(
            rootView: HomeWorkspaceView(session: session, model: model, actions: PlayerActions())
                .preferredColorScheme(.dark))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 630), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        for width: CGFloat in [1120, 640, 1440, 2560, 1120] {
            window.setContentSize(NSSize(width: width, height: 630))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()

            let scroll = try #require(scrollView(in: host))
            let document = try #require(scroll.documentView)
            #expect(abs(host.bounds.width - width) < 1)
            #expect(document.frame.width <= scroll.contentView.bounds.width + 1)
        }
        await model.shutdown()
    }

    @Test("Populated Home and docked local audio fit while the window resizes")
    func populatedWorkspaceAndMiniPlayerFit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinrox-home-populated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recents = RecentFilesStore(fileURL: root.appendingPathComponent("recent.json"))
        let session = PlayerSession(recents: recents)
        let model = PlayerViewModel(engine: FakePlayerEngine())
        session.mediaLibrary.setEnrichMetadata(false)
        session.mediaLibrary.snapshot.folders = [
            WatchedFolder(
                id: UUID(), path: root.path, displayName: "Media", volumeUUID: nil,
                isRemovable: false)
        ]
        let tracks = (1...6).map { index in
            MediaLibraryFile(
                path: root.appendingPathComponent("Local \(index).wav").path, size: 1,
                modified: Date(), added: Date(),
                audio: LocalAudioTags(
                    title: "Local track \(index)",
                    artist: "Fixture artist", album: "Album \(index)", duration: 120, codec: "FLAC",
                    isLossless: true))
        }
        let movies = (1...10).map { index in
            MediaLibraryFile(
                path: root.appendingPathComponent("Movie \(index).mkv").path, size: 1,
                modified: Date(), added: Date(),
                video: VideoTitle(title: "Movie \(index)", year: 2020))
        }
        let episodes = (1...4).map { number in
            MediaLibraryFile(
                path: root.appendingPathComponent("Fixture Show S01E\(number).mkv").path, size: 1,
                modified: Date(), added: Date(),
                video: VideoTitle(
                    title: "Fixture Show", season: 1, episodes: [number],
                    episodeTitle: "Episode \(number)"))
        }
        session.mediaLibrary.snapshot.files = movies + tracks + episodes
        if let seriesKey = episodes.first?.metadataKey {
            session.mediaLibrary.snapshot.metadata[seriesKey] = MediaEnrichment(
                title: "Fixture Show", summary: "A series description for the rendered library.",
                rating: 8.7, source: .tvmaze, year: "2026", genres: ["Drama", "Mystery"])
        }
        session.mediaLibrary.snapshot.progress = Dictionary(
            uniqueKeysWithValues: movies.prefix(3).map {
                (
                    $0.path,
                    WatchProgress(
                        path: $0.path, position: 500, duration: 3600, completed: false,
                        updated: Date())
                )
            })
        let file = tracks[0]
        let sample = file.url
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/M1Media/tagged.mp3")
        let adHoc = sample.deletingPathExtension().appendingPathExtension("mp3")
        try FileManager.default.copyItem(at: source, to: adHoc)
        session.localAudio.setVolume(0)
        #expect(session.localAudio.play([adHoc], using: session.mediaLibrary))
        await session.playback.settle()
        #expect(session.localAudio.currentTrack != nil)
        session.localAudio.setPaused(true)
        let view = HomeWorkspaceView(session: session, model: model, actions: PlayerActions())
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 630), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        for width: CGFloat in [1120, 640, 1440, 2560, 1120] {
            window.setContentSize(NSSize(width: width, height: 630))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(130))
            let scroll = try #require(scrollView(in: host))
            let document = try #require(scroll.documentView)
            #expect(document.frame.width <= scroll.contentView.bounds.width + 1)
            if let directory = ProcessInfo.processInfo.environment["KINROX_WELCOME_SNAPSHOTS"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent(
                        "home-populated-\(Int(width)).png"))
            }
        }
        if let directory = ProcessInfo.processInfo.environment["KINROX_WELCOME_SNAPSHOTS"] {
            let output = URL(fileURLWithPath: directory)
            session.homeSelectedSeries = episodes.first?.seriesKey
            for section: HomeSection in [.video, .audio] {
                session.homeSection = section
                try await Task.sleep(for: .milliseconds(200))
                host.layoutSubtreeIfNeeded()
                try capture(host, into: output.appendingPathComponent("home-\(section).png"))
            }
            let folders = NSHostingView(
                rootView: LibraryFoldersSheet(store: session.mediaLibrary, actions: PlayerActions())
                    .preferredColorScheme(.dark))
            folders.setFrameSize(folders.fittingSize)
            folders.layoutSubtreeIfNeeded()
            try capture(folders, into: output.appendingPathComponent("home-folders.png"))
        }
        await session.playback.close()
        await model.shutdown()
    }

    private func capture(_ host: NSView, into url: URL) throws {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.frame.width > 400 { return scroll }
        return view.subviews.compactMap { scrollView(in: $0) }.first
    }

}
