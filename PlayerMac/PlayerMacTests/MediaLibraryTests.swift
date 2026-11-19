import AVFoundation
import Foundation
import MetaBrainzAPI
import Testing

@testable import Kinrox

struct MediaLibraryTests {
    @Test func titleParserRecognizesMoviesSeriesAndPersonalClips() {
        func parse(_ path: String) -> VideoTitle {
            VideoTitleParser.parse(URL(fileURLWithPath: "/Library/" + path))
        }
        let movie = parse("Dune.Part.Two.2024.2160p.HDR.HEVC.mkv")
        #expect(movie.title == "Dune Part Two")
        #expect(movie.year == 2024)
        #expect(movie.resolution == "4K")
        #expect(movie.hdr == "HDR")
        #expect(movie.codec == "HEVC")
        let trailingYear = parse("Dune.1080p.BluRay.x264.2021.mkv")
        #expect(trailingYear.title == "Dune")
        #expect(trailingYear.year == 2021)
        let seriesWithFormatInItsTitle = parse("Local 4K Stories 2021/Season_01/S01E01.mkv")
        #expect(seriesWithFormatInItsTitle.title == "Local 4K Stories")
        #expect(seriesWithFormatInItsTitle.year == 2021)
        let episode = parse("The Expanse/Season_01/s01e07_Episode.Seven.avi")
        #expect(episode.title == "The Expanse")
        #expect(episode.season == 1)
        #expect(episode.episodes == [7])
        #expect(episode.episodeTitle == "Episode Seven")
        let directSeriesRoot = VideoTitleParser.parse(
            URL(fileURLWithPath: "/Library/The Expanse/Season_01/s01e07_Episode.Seven.avi"),
            root: URL(fileURLWithPath: "/Library/The Expanse"))
        #expect(directSeriesRoot.title == "The Expanse")
        #expect(directSeriesRoot.season == 1)
        #expect(directSeriesRoot.episodes == [7])
        #expect(parse("The Expanse/Season 02/Episode 7.mkv").season == 2)
        #expect(parse("Series/Series.1x03.mkv").episodes == [3])
        #expect(parse("Series/S02E01E02.mkv").episodes == [1, 2])
        #expect(parse("IMG_4021.MOV").isPersonal)
        #expect(parse("2001.A.Space.Odyssey.1968.mkv").title == "2001 A Space Odyssey")
    }

    @Test func incrementalScanKeepsUnchangedRowsAndPreservesOfflineMedia() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Media")
        let child = root.appendingPathComponent("Series")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let key = dir.appendingPathComponent("data/library.sqlite")
        let db = MediaLibraryDatabase(location: key)
        let artwork = ArtworkCache(directory: dir.appendingPathComponent("art"))
        let clip = child.appendingPathComponent("S01E07.mkv")
        let sidecar = child.appendingPathComponent("S01E07.sub")
        try Data([1]).write(to: clip)
        try Data([2]).write(to: sidecar)
        try FileManager.default.createSymbolicLink(
            at: child.appendingPathComponent("Symlink.mkv"), withDestinationURL: clip)
        let watchedChild = try #require(MediaFolderScanner.folder(child))
        _ = try await db.add(watchedChild)
        _ = try await MediaFolderScanner.scan(watchedChild, database: db, artwork: artwork) { _ in }
        let before = try #require(try await db.snapshot().files.first)
        #expect(before.path == VideoFiles.key(clip))

        let watchedRoot = try #require(MediaFolderScanner.folder(root))
        #expect(try await db.add(watchedRoot) == watchedRoot.id)
        #expect(try await db.add(watchedChild) == watchedRoot.id)
        _ = try await MediaFolderScanner.scan(watchedRoot, database: db, artwork: artwork) { _ in }
        let unchanged = try #require(try await db.snapshot().files.first)
        #expect(unchanged.added == before.added)
        #expect(try await db.folders().count == 1)

        try await db.save(
            WatchProgress(
                path: before.path, position: 30, duration: 100, completed: false, updated: Date()))
        let renamed = child.appendingPathComponent("S01E08.mkv")
        try FileManager.default.moveItem(at: clip, to: renamed)
        var mismatched = watchedRoot
        mismatched.isOffline = false
        let unavailable = MediaFolderScanner.Dependencies(volume: { _ in
            MediaFolderScanner.Volume(uuid: "different-drive", mountPath: "/", removable: true)
        })
        _ = try await MediaFolderScanner.scan(
            mismatched, database: db, artwork: artwork, dependencies: unavailable
        ) { _ in }
        let offline = try await db.snapshot()
        #expect(offline.folders.first?.isOffline == true)
        #expect(offline.files.map(\.path) == [before.path])
        #expect(offline.progress[before.path]?.position == 30)
        #expect(try await db.add(watchedChild) == watchedRoot.id)
        #expect(try await db.folders().count == 1)

        _ = try await MediaFolderScanner.scan(watchedRoot, database: db, artwork: artwork) { _ in }
        let remounted = try await db.snapshot()
        #expect(remounted.folders.first?.isOffline == false)
        #expect(remounted.files.map(\.path) == [VideoFiles.key(renamed)])
        #expect(remounted.progress[before.path]?.position == 30)
    }

    @Test func incompleteRemountKeepsUnseenRowsAndMakesTheFolderAvailable() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Media")
        let hidden = root.appendingPathComponent("Unreadable")
        let files = FileManager.default
        try files.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data([1]).write(to: hidden.appendingPathComponent("Unseen.mkv"))
        let artwork = ArtworkCache(directory: dir.appendingPathComponent("art"))
        let db = MediaLibraryDatabase(location: dir.appendingPathComponent("library.sqlite"))
        let folder = try #require(MediaFolderScanner.folder(root))
        _ = try await db.add(folder)
        _ = try await MediaFolderScanner.scan(folder, database: db, artwork: artwork) { _ in }
        try await db.markOffline(folder.id)
        try Data([1]).write(to: root.appendingPathComponent("Reachable.mkv"))
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: hidden.path)
        defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hidden.path) }
        let result = try await MediaFolderScanner.scan(
            folder, database: db, artwork: artwork
        ) { _ in }
        let snapshot = try await db.snapshot()
        #expect(result == .incomplete)
        #expect(snapshot.folders.first?.isOffline == false)
        #expect(
            Set(snapshot.files.map(\.url.lastPathComponent)) == ["Reachable.mkv", "Unseen.mkv"])
    }

    @MainActor
    @Test func overviewIgnoresTabFiltersWhilePreservingSearchAndGenre() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = MediaLibraryStore(limiter: MusicBrainzRateLimiter(), storage: (dir, dir))
        let movie = MediaLibraryFile(
            path: "/Library/Evening.mkv", size: 1, modified: Date(), added: Date(),
            video: VideoTitle(title: "Evening"))
        let song = MediaLibraryFile(
            path: "/Library/Evening.mp3", size: 1, modified: Date(), added: Date(),
            audio: LocalAudioTags(title: "Evening", genres: ["Ambient"], rating: 3))
        library.snapshot.files = [movie, song]
        let movieKey = try #require(movie.metadataKey)
        library.snapshot.metadata[movieKey] = MediaEnrichment(rating: 7, genres: ["Ambient"])

        var filter = HomeFilterState(genre: "Ambient", query: "Evening")
        filter.videoMinimumRating = true
        #expect(library.filteredVideo(filter).isEmpty)
        #expect(library.filteredTracks(filter).map(\.id) == [song.id])
        filter.videoMinimumRating = false
        filter.audioMinimumRating = true
        #expect(library.filteredTracks(filter).isEmpty)
        #expect(library.filteredVideo(filter).map(\.id) == [movie.id])

        filter.videoKind = .series
        filter.ultraHD = true
        filter.lossless = true
        #expect(library.filteredVideo(filter.overview).map(\.id) == [movie.id])
        #expect(library.filteredTracks(filter.overview).map(\.id) == [song.id])
        filter.genre = "Drama"
        #expect(library.filteredTracks(filter.overview).isEmpty)
        filter.genre = nil
        filter.query = "Morning"
        #expect(library.filteredVideo(filter.overview).isEmpty)
    }

    @MainActor
    @Test func releaseSmokeTestUsesAnIsolatedCatalogEvenWithStorageOverrides() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = MediaLibraryDatabase(
            location: dir.appendingPathComponent("media-library.sqlite"))
        let folder = try #require(MediaFolderScanner.folder(dir))
        _ = try await live.add(folder)

        let library = MediaLibraryStore(
            limiter: MusicBrainzRateLimiter(),
            environment: [
                "KINROX_RELEASE_SMOKE_TEST": "1",
                "KINROX_DATA_DIR": dir.path,
                "KINROX_CACHE_DIR": dir.path,
            ])
        try await library.reload()
        #expect(library.folders.isEmpty)
        #expect(try await live.folders().map(\.id) == [folder.id])
    }

    @Test func parsesBoundedFLACAndOggWithoutLoadingAudioFrames() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tags.flac")
        let rate: UInt64 = 96_000
        var stream = Data(repeating: 0, count: 10)
        stream.append(contentsOf: bytes((rate << 44) | (23 << 36) | (rate * 12), count: 8))
        stream.append(Data(repeating: 0, count: 16))
        let comment = comments(["TITLE=Signal", "ARTIST=Example", "GENRE=Ambient"])
        let image = Data([255, 216, 255, 217])
        let picture =
            Data(bytes(3, count: 4)) + Data(bytes(9, count: 4)) + Data("image/jpg".utf8)
            + Data(repeating: 0, count: 20) + Data(bytes(UInt64(image.count), count: 4)) + image
        let oversized = Data(repeating: 0, count: (1 << 20) + 1)
        let flac =
            Data("fLaC".utf8) + block(stream, type: 0) + block(oversized, type: 4)
            + block(comment, type: 4) + block(picture, type: 0x86)
        try flac.write(to: file)
        let parsed = FLACOggTagParser.read(file)
        #expect(parsed.tags["TITLE"] == "Signal")
        #expect(parsed.sampleRate == 96_000)
        #expect(parsed.bitDepth == 24)
        #expect(parsed.duration == 12)
        #expect(parsed.artwork == image)

        let ogg = dir.appendingPathComponent("tags.opus")
        let header = Data("OpusHead".utf8) + Data([1, 2, 0x38, 1]) + Data(repeating: 0, count: 7)
        let tags = Data("OpusTags".utf8) + comments(["TITLE=Opus Test"])
        try
            (page(granule: 0, packet: header) + page(granule: 0, packet: tags)
            + page(granule: 48_000 * 4 + 312, packet: Data([0]))).write(to: ogg)
        let opus = FLACOggTagParser.read(ogg)
        #expect(opus.tags["TITLE"] == "Opus Test")
        #expect(opus.duration == 4)
        #expect(opus.codec == "Opus")
    }

    @Test(arguments: [kAudioFormatAppleLossless, kAudioFormatMPEG4AAC])
    func distinguishesM4ACodecs(formatID: AudioFormatID) async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("same-extension.m4a")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        if let channel = buffer.floatChannelData?[0] { channel.update(repeating: 0, count: 4_410) }
        do {
            var settings: [String: Any] = [
                AVFormatIDKey: formatID, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            ]
            if formatID == kAudioFormatAppleLossless { settings[AVEncoderBitDepthHintKey] = 16 }
            let output = try AVAudioFile(forWriting: file, settings: settings)
            try output.write(from: buffer)
        }
        let tags = await LocalAudioTagReader.read(file, artwork: ArtworkCache(directory: dir))
        #expect(tags.isLossless == (formatID == kAudioFormatAppleLossless))
        #expect(tags.codec == (formatID == kAudioFormatAppleLossless ? "ALAC" : "AAC"))
        #expect(tags.sampleRate == 44_100)
    }

    @Test func readsEmbeddedMP3TitleAlbumArtistGenreAndTrack() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("DerivedData/M1Media/tagged.mp3")
        try #require(FileManager.default.fileExists(atPath: file.path))
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tags = await LocalAudioTagReader.read(file, artwork: ArtworkCache(directory: dir))
        #expect(tags.title == "Fixture title")
        #expect(tags.artist == "Fixture artist")
        #expect(tags.album == "Fixture album")
        #expect(tags.track == 3)
        #expect(tags.genres == ["Ambient"])
        #expect(tags.codec == "MP3")
    }

    @Test func normalizesID3PopularimeterWithoutTreatingZeroAsARating() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rating.mp3")
        let prefix =
            Data("ID3".utf8) + Data([3, 0, 0, 0, 0, 0, 13])
            + Data("POPM".utf8) + Data([0, 0, 0, 3, 0, 0, 65, 0])
        try (prefix + Data([204])).write(to: file)
        #expect(ID3RatingReader.rating(file) == 4)
        try (prefix + Data([0])).write(to: file)
        #expect(ID3RatingReader.rating(file) == nil)
    }

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KinroxLibraryTests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bytes(_ value: UInt64, count: Int, little: Bool = false) -> [UInt8] {
        let data = (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        return little ? data : Array(data.reversed())
    }

    private func comments(_ fields: [String]) -> Data {
        fields.reduce(
            into: Data([0, 0, 0, 0] + bytes(UInt64(fields.count), count: 4, little: true))
        ) {
            $0.append(contentsOf: bytes(UInt64($1.utf8.count), count: 4, little: true))
            $0.append(contentsOf: $1.utf8)
        }
    }

    private func block(_ data: Data, type: UInt8) -> Data {
        Data([type] + bytes(UInt64(data.count), count: 3)) + data
    }

    private func page(granule: UInt64, packet: Data) -> Data {
        let stem = Data("OggS".utf8) + Data([0, 0]) + Data(bytes(granule, count: 8, little: true))
        return stem + Data(repeating: 0, count: 12) + Data([1, UInt8(packet.count)]) + packet
    }
}
