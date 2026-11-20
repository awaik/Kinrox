import AppKit
import Foundation
import MetaBrainzAPI
import RemoteProtocol
import Testing

@testable import Kinrox

@Suite(
    "Remote library bridge: catalog, paging, revisions, privacy", .serialized,
    .timeLimit(.minutes(2)))
@MainActor
struct RemoteLibraryBridgeTests {
    @Test(
        "All sections, sorting, filtering, ad-hoc continue watching, details, and longest-prefix folder"
    )
    func sectionsDetailsAndFolders() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()

        let parentDir = root.appendingPathComponent("Media", isDirectory: true)
        let childDir = parentDir.appendingPathComponent("Cinema", isDirectory: true)
        let siblingDir = root.appendingPathComponent("Media2", isDirectory: true)
        let offlineDir = root.appendingPathComponent("ExternalDrive", isDirectory: true)
        for dir in [parentDir, childDir, siblingDir, offlineDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let store = MediaLibraryStore(
            limiter: MusicBrainzRateLimiter(), defaults: defaults, storage: (root, root))
        let recents = RecentFilesStore(fileURL: root.appendingPathComponent("recents.json"))

        let parentFolder = WatchedFolder(
            id: UUID(), path: VideoFiles.key(parentDir), displayName: "Media Root",
            volumeUUID: "VOL-1", isRemovable: false)
        let childFolder = WatchedFolder(
            id: UUID(), path: VideoFiles.key(childDir), displayName: "Cinema Folder",
            volumeUUID: "VOL-1", isRemovable: false)
        let siblingFolder = WatchedFolder(
            id: UUID(), path: VideoFiles.key(siblingDir), displayName: "Other Media",
            volumeUUID: "VOL-1", isRemovable: false)
        let offlineFolder = WatchedFolder(
            id: UUID(), path: VideoFiles.key(offlineDir), displayName: "WD Passport",
            volumeUUID: "VOL-EXT-999", isRemovable: true, isOffline: true)

        let now = Date()
        let movieURL = childDir.appendingPathComponent("Ember.Dusk.2025.2160p.HDR.HEVC.mkv")
        let movie2URL = siblingDir.appendingPathComponent("Alpha.2020.mkv")
        let ep1URL = parentDir.appendingPathComponent("Orbit.S01E01.mkv")
        let ep2URL = parentDir.appendingPathComponent("Orbit.S01E02.mkv")
        let offlineMovieURL = offlineDir.appendingPathComponent("Lost.mkv")
        let track1URL = parentDir.appendingPathComponent("01-Dawn.flac")
        let track2URL = parentDir.appendingPathComponent("02-Dusk.flac")
        let singleTrackURL = parentDir.appendingPathComponent("Solo.mp3")
        let adHocURL = root.appendingPathComponent("AdHocRecent.mkv")
        for url in [
            movieURL, movie2URL, ep1URL, ep2URL, track1URL, track2URL, singleTrackURL, adHocURL,
        ] {
            try Data([0]).write(to: url)
        }

        let posterKey = try #require(try await store.artwork.store(makePNG(color: .orange)))
        let albumKey = try #require(try await store.artwork.store(makePNG(color: .purple)))

        let movieFile = MediaLibraryFile(
            path: VideoFiles.key(movieURL), size: 100, modified: now,
            added: now.addingTimeInterval(-100),
            video: VideoTitle(
                title: "Ember Dusk", year: 2025, resolution: "4K", hdr: "HDR", codec: "HEVC"))
        let movie2File = MediaLibraryFile(
            path: VideoFiles.key(movie2URL), size: 100, modified: now,
            added: now.addingTimeInterval(-10),
            video: VideoTitle(title: "Alpha", year: 2020))
        let ep1File = MediaLibraryFile(
            path: VideoFiles.key(ep1URL), size: 100, modified: now,
            added: now.addingTimeInterval(-200),
            video: VideoTitle(title: "Orbit", season: 1, episodes: [1], episodeTitle: "Launch"))
        let ep2File = MediaLibraryFile(
            path: VideoFiles.key(ep2URL), size: 100, modified: now,
            added: now.addingTimeInterval(-50),
            video: VideoTitle(title: "Orbit", season: 1, episodes: [2], episodeTitle: "Drift"))
        let offlineMovieFile = MediaLibraryFile(
            path: VideoFiles.key(offlineMovieURL), size: 100, modified: now,
            added: now.addingTimeInterval(-300),
            video: VideoTitle(title: "Lost", year: 2021))
        let track1File = MediaLibraryFile(
            path: VideoFiles.key(track1URL), size: 100, modified: now,
            added: now.addingTimeInterval(-20),
            audio: LocalAudioTags(
                title: "Dawn", artist: "Yaima", album: "Pellucidity", albumArtist: "Yaima",
                year: 2024, track: 1, disc: 1, duration: 240, codec: "FLAC", sampleRate: 96_000,
                bitDepth: 24, isLossless: true, genres: ["Ambient"], rating: 4.5,
                artworkPath: albumKey))
        let track2File = MediaLibraryFile(
            path: VideoFiles.key(track2URL), size: 100, modified: now,
            added: now.addingTimeInterval(-15),
            audio: LocalAudioTags(
                title: "Dusk", artist: "Yaima", album: "Pellucidity", albumArtist: "Yaima",
                year: 2024, track: 2, disc: 1, duration: 180, codec: "FLAC", sampleRate: 96_000,
                bitDepth: 24, isLossless: true, genres: ["Ambient"], rating: 4.5))
        let singleTrackFile = MediaLibraryFile(
            path: VideoFiles.key(singleTrackURL), size: 100, modified: now,
            added: now.addingTimeInterval(-5),
            audio: LocalAudioTags(title: "Solo", artist: "Guest", duration: 120, codec: "MP3"))

        store.snapshot = MediaLibraryDatabase.Snapshot(
            folders: [parentFolder, childFolder, siblingFolder, offlineFolder],
            files: [
                movieFile, movie2File, ep1File, ep2File, offlineMovieFile, track1File, track2File,
                singleTrackFile,
            ],
            fileCounts: [:],
            offlinePaths: [offlineMovieFile.path],
            metadata: [
                movieFile.metadataKey!: MediaEnrichment(
                    title: "Ember Dusk", summary: "Deep space drama.", rating: 8.8, source: .imdb,
                    year: "2025", genres: ["Sci-Fi", "Drama"], posterPath: posterKey),
                ep1File.metadataKey!: MediaEnrichment(
                    title: "Orbit", summary: "A station in orbit.", rating: 9.1, source: .tvmaze,
                    year: "2024", genres: ["Sci-Fi"], posterPath: posterKey,
                    episodes: [
                        .init(season: 1, number: 1, title: "Launch", summary: "Ep1 overview"),
                        .init(season: 1, number: 2, title: "Drift", summary: "Ep2 overview"),
                    ]),
            ],
            progress: [
                movieFile.path: WatchProgress(
                    path: movieFile.path, position: 600, duration: 7200, completed: false,
                    updated: now.addingTimeInterval(-30)),
                movie2File.path: WatchProgress(
                    path: movie2File.path, position: 3600, duration: 3600, completed: true,
                    updated: now.addingTimeInterval(-40)),
                ep1File.path: WatchProgress(
                    path: ep1File.path, position: 2700, duration: 2700, completed: true,
                    updated: now.addingTimeInterval(-10)),
                VideoFiles.key(adHocURL): WatchProgress(
                    path: VideoFiles.key(adHocURL), position: 120, duration: 900, completed: false,
                    updated: now.addingTimeInterval(-20)),
            ])
        recents.noteOpened(adHocURL, at: now)

        let bridge = RemoteLibraryBridge(store: store, recents: recents, defaults: defaults)
        bridge.currentVideoPath = { movieFile.path }
        bridge.currentVideoTracks = {
            [
                MediaTrack(number: 1, kind: .audio, title: "Main", language: "eng"),
                MediaTrack(number: 2, kind: .subtitle, title: "Russian", language: "rus"),
            ]
        }

        // Counts: 3 movies + 1 series = 4 top-level videos
        #expect(bridge.state.folders == 4)
        #expect(bridge.state.videos == 4)
        #expect(bridge.state.series == 1)
        #expect(bridge.state.albums == 1)
        #expect(bridge.state.tracks == 3)

        // Continue Watching: ep2 (updated -10s), adHoc (updated -20s), movie1 (updated -30s)
        let cwPage = try requireLibraryPage(
            bridge.libraryPage(.init(section: .continueWatching), replyTo: UUID()))
        #expect(cwPage.items.map(\.title) == ["Drift", "AdHocRecent.mkv", "Ember Dusk"])
        #expect(cwPage.items[0].kind == .episode && cwPage.items[0].episodeLabel == "S01E02")
        #expect(cwPage.items[0].subtitle == "Orbit")

        // Ad-hoc item details resolve cleanly
        let adHocId = cwPage.items[1].id
        let adHocDetails = try requireItemResponse(
            bridge.itemDetails(.init(id: adHocId), replyTo: UUID()))
        #expect(adHocDetails.details.fileName == "AdHocRecent.mkv")
        #expect(adHocDetails.details.audioLanguages.isEmpty)

        // Videos: sort by rating (Orbit 9.1, Ember Dusk 8.8, Alpha nil, Lost nil)
        let byRating = try requireLibraryPage(
            bridge.libraryPage(
                .init(section: .videos, videoKind: .all, sort: .rating), replyTo: UUID()))
        #expect(byRating.items.map(\.title) == ["Orbit", "Ember Dusk", "Alpha", "Lost"])

        // Videos: unwatched excludes completed movie2 (Alpha)
        let unwatched = try requireLibraryPage(
            bridge.libraryPage(.init(section: .videos, videoKind: .unwatched), replyTo: UUID()))
        #expect(!unwatched.items.contains { $0.title == "Alpha" })
        #expect(unwatched.items.contains { $0.title == "Ember Dusk" })
        #expect(unwatched.items.contains { $0.title == "Orbit" })

        // Longest-prefix folder matching: Cinema Folder (not Media Root), Other Media, WD Passport
        let emberItem = try #require(byRating.items.first { $0.title == "Ember Dusk" })
        let alphaItem = try #require(byRating.items.first { $0.title == "Alpha" })
        let lostItem = try #require(byRating.items.first { $0.title == "Lost" })
        #expect(emberItem.folderName == "Cinema Folder")
        #expect(alphaItem.folderName == "Other Media")
        #expect(lostItem.offline && lostItem.folderName == "WD Passport")

        // Movie details: languages populated ONLY for loaded video
        let emberResp = try requireItemResponse(
            bridge.itemDetails(.init(id: emberItem.id), replyTo: UUID()))
        #expect(emberResp.details.ratingSource == "IMDb")
        #expect(emberResp.details.fileName == movieURL.lastPathComponent)
        #expect(emberResp.details.folderName == "Cinema Folder")
        #expect(emberResp.details.audioLanguages == ["eng"])
        #expect(emberResp.details.subtitleLanguages == ["rus"])

        let alphaResp = try requireItemResponse(
            bridge.itemDetails(.init(id: alphaItem.id), replyTo: UUID()))
        #expect(alphaResp.details.audioLanguages.isEmpty)
        #expect(alphaResp.details.subtitleLanguages.isEmpty)

        // Series details & children
        let seriesItem = try #require(byRating.items.first { $0.kind == .series })
        let seriesResp = try requireItemResponse(
            bridge.itemDetails(.init(id: seriesItem.id), replyTo: UUID()))
        #expect(seriesResp.details.seasons == [1])
        #expect(seriesResp.details.watchedCount == 1)
        #expect(seriesResp.details.nextEpisodeId == cwPage.items[0].id)

        let seriesChildren = try requireLibraryPage(
            bridge.libraryPage(
                .init(section: .children, parentId: seriesItem.id), replyTo: UUID()))
        #expect(seriesChildren.items.map(\.episodeLabel) == ["S01E01", "S01E02"])

        // Albums: summed duration = 420s, childCount = 2, format badge, children ordered by track
        let albumsPage = try requireLibraryPage(
            bridge.libraryPage(.init(section: .albums), replyTo: UUID()))
        #expect(albumsPage.items.count == 1)
        #expect(albumsPage.items[0].duration == 420)
        #expect(albumsPage.items[0].childCount == 2)
        #expect(albumsPage.items[0].badges.contains("FLAC · 24/96"))
        let albumChildren = try requireLibraryPage(
            bridge.libraryPage(
                .init(section: .children, parentId: albumsPage.items[0].id), replyTo: UUID()))
        #expect(albumChildren.items.map(\.title) == ["Dawn", "Dusk"])

        // Invalid children parentId returns itemNotFound
        let badChildren = bridge.libraryPage(
            .init(section: .children, parentId: emberItem.id), replyTo: UUID())
        if case .error(_, let err) = badChildren {
            #expect(err.code == .itemNotFound)
        } else {
            Issue.record("Expected itemNotFound for movie as children parent")
        }

        // Strict non-disclosure of paths, volume UUIDs, bookmarks, and cache filenames
        for msg in [
            bridge.libraryPage(.init(section: .videos), replyTo: UUID()),
            bridge.libraryPage(.init(section: .albums), replyTo: UUID()),
            bridge.libraryPage(.init(section: .tracks), replyTo: UUID()),
            bridge.itemDetails(.init(id: emberItem.id), replyTo: UUID()),
            bridge.itemDetails(.init(id: seriesItem.id), replyTo: UUID()),
        ] {
            let wire = String(decoding: try Codec.encode(msg), as: UTF8.self)
            #expect(!wire.contains(root.path))
            #expect(!wire.contains("VOL-1") && !wire.contains("VOL-EXT-999"))
            #expect(!wire.contains(posterKey) && !wire.contains(albumKey))
            #expect(!wire.contains("bookmark"))
        }

        // ID stability across rebuild with same UserDefaults
        let bridge2 = RemoteLibraryBridge(store: store, recents: recents, defaults: defaults)
        let page2 = try requireLibraryPage(
            bridge2.libraryPage(.init(section: .videos, sort: .rating), replyTo: UUID()))
        #expect(page2.items.map(\.id) == byRating.items.map(\.id))
        bridge.disconnect()
        bridge2.disconnect()
    }

    @Test(
        "Progress coalescing, completion/pause flush, revision stability, and 2 Hz throttle with library"
    )
    func revisionsCoalescingAndThrottle() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let store = MediaLibraryStore(
            limiter: MusicBrainzRateLimiter(), defaults: defaults, storage: (root, root))
        let recents = RecentFilesStore(fileURL: root.appendingPathComponent("recents.json"))
        let now = Date()
        let movie = MediaLibraryFile(
            path: root.appendingPathComponent("A.mkv").path, size: 1, modified: now, added: now,
            video: VideoTitle(title: "A"))
        store.snapshot = MediaLibraryDatabase.Snapshot(files: [movie])

        var clock: TimeInterval = 100
        var playing = true
        var changeCount = 0
        let bridge = RemoteLibraryBridge(
            store: store, recents: recents, defaults: defaults,
            now: { clock }, progressCoalesceInterval: 10)
        bridge.isVideoPlaying = { playing }
        bridge.changed = { changeCount += 1 }

        let initialLibRev = bridge.libraryRevision
        let initialProgRev = bridge.progressRevision

        // First progress tick bumps progressRevision immediately, keeps libraryRevision untouched
        store.record(
            WatchProgress(
                path: movie.path, position: 10, duration: 1000, completed: false, updated: now))
        #expect(bridge.libraryRevision == initialLibRev)
        #expect(bridge.progressRevision != initialProgRev)
        let rev1 = bridge.progressRevision

        // Second tick 2 seconds later while playing is coalesced (does not bump immediately)
        clock = 102
        store.record(
            WatchProgress(
                path: movie.path, position: 12, duration: 1000, completed: false, updated: now))
        #expect(bridge.progressRevision == rev1)

        // Pause flushes pending progressRevision immediately without changing libraryRevision
        playing = false
        bridge.flushPendingProgressRevision()
        #expect(bridge.libraryRevision == initialLibRev)
        #expect(bridge.progressRevision != rev1)
        let rev2 = bridge.progressRevision

        // Completion bumps immediately even while playing
        playing = true
        clock = 103
        store.record(
            WatchProgress(
                path: movie.path, position: 980, duration: 1000, completed: true, updated: now))
        #expect(bridge.progressRevision != rev2)
        #expect(bridge.libraryRevision == initialLibRev)

        // Stale library revision restarts pagination at offset 0
        let stalePage = try requireLibraryPage(
            bridge.libraryPage(
                .init(section: .videos, offset: 1, revision: UUID()), replyTo: UUID()))
        #expect(stalePage.offset == 0 && stalePage.revision == initialLibRev)

        // RemoteStatePublisher preserves 2 Hz throttle when library & sources are non-nil
        var pubTime: TimeInterval = 0
        var published: [PlayerState] = []
        let publisher = RemoteStatePublisher(now: { pubTime }, publish: { published.append($0) })
        let baseState = PlayerState(
            title: "A", position: 0, duration: 1000, paused: false, volume: 50, fullscreen: false,
            hasMedia: true, canNext: false, canPrevious: false, screensaver: .off, source: .video,
            library: bridge.state,
            sources: RemoteSources(video: .init(title: "A", paused: false)))
        publisher.update(baseState)
        for step in 1...40 {
            pubTime = Double(step) * 0.01
            var tick = baseState
            tick.position = Double(step)
            publisher.update(tick)
        }
        #expect(published.count == 1)
        publisher.reset()
        bridge.disconnect()
        #expect(changeCount > 0)
    }

    @Test(
        "Scale (2,000 videos + 5,000 tracks) and long multi-byte UTF-8 titles fit SecureChannel budget"
    )
    func scaleAndMultiByteFrameFitting() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let store = MediaLibraryStore(
            limiter: MusicBrainzRateLimiter(), defaults: defaults, storage: (root, root))
        let recents = RecentFilesStore(fileURL: root.appendingPathComponent("recents.json"))
        let now = Date()

        // Include multi-scalar Cyrillic/emoji title > 2048 UTF-8 bytes to exercise truncation & halving
        let longTitle = String(repeating: "Кино🎬", count: 400)  // > 4000 UTF-8 bytes
        var files: [MediaLibraryFile] = []
        files.reserveCapacity(7_000)
        for i in 0..<2_000 {
            let title = i < 40 ? "\(longTitle)-\(i)" : "Movie \(i)"
            files.append(
                MediaLibraryFile(
                    path: "/fake/videos/movie_\(i).mkv", size: 100, modified: now, added: now,
                    video: VideoTitle(title: title, year: 2020 + (i % 6))))
        }
        for i in 0..<5_000 {
            files.append(
                MediaLibraryFile(
                    path: "/fake/music/album_\(i / 10)/track_\(i).flac", size: 100, modified: now,
                    added: now,
                    audio: LocalAudioTags(
                        title: "Track \(i)", artist: "Artist \(i / 50)",
                        album: "Album \(i / 10)", year: 2024, track: (i % 10) + 1, disc: 1,
                        duration: 210, codec: "FLAC", sampleRate: 96_000, bitDepth: 24,
                        isLossless: true)))
        }
        store.snapshot = MediaLibraryDatabase.Snapshot(files: files)
        let bridge = RemoteLibraryBridge(store: store, recents: recents, defaults: defaults)
        #expect(bridge.state.videos == 2_000)
        #expect(bridge.state.albums == 500)
        #expect(bridge.state.tracks == 5_000)

        let videoMsg = bridge.libraryPage(.init(section: .videos, offset: 0), replyTo: UUID())
        let videoBytes = try Codec.encode(videoMsg)
        #expect(videoBytes.count <= SecureChannel.maxPlaintextBytes)
        let videoPage = try requireLibraryPage(try Codec.decode(videoBytes))
        #expect(videoPage.total == 2_000 && !videoPage.items.isEmpty && videoPage.nextOffset != nil)

        // Halved page count when multi-byte titles would otherwise exceed frame budget
        let longSearch = bridge.libraryPage(
            .init(section: .videos, query: "Кино", offset: 0), replyTo: UUID())
        let longBytes = try Codec.encode(longSearch)
        #expect(longBytes.count <= SecureChannel.maxPlaintextBytes)
        let longPage = try requireLibraryPage(try Codec.decode(longBytes))
        #expect(longPage.total == 40 && longPage.items.count < 40 && longPage.nextOffset != nil)

        let trackMsg = bridge.libraryPage(.init(section: .tracks, offset: 0), replyTo: UUID())
        #expect(try Codec.encode(trackMsg).count <= SecureChannel.maxPlaintextBytes)
        bridge.disconnect()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KinroxRemoteLibTests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "app.kinrox.tests.remotelib.\(UUID())"))
    }

    private func makePNG(color: NSColor) -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<64 {
            for y in 0..<64 { bitmap.setColor(color, atX: x, y: y) }
        }
        return bitmap.representation(using: .png, properties: [:])!
    }

    private func requireLibraryPage(_ message: Message) throws -> LibraryPage {
        guard case .library(_, let page) = message else {
            Issue.record("Expected library message, got \(message.type)")
            throw RemoteTestError.timeout
        }
        return page
    }

    private func requireItemResponse(_ message: Message) throws -> LibraryItemResponse {
        guard case .libraryItem(_, let response) = message else {
            Issue.record("Expected libraryItem message, got \(message.type)")
            throw RemoteTestError.timeout
        }
        return response
    }
}
