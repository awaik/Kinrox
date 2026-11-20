import Foundation

enum FolderScanState: Equatable {
    case ready
    case scanning(Int)
    case offline, failed
}

struct WatchedFolder: Identifiable, Equatable, Sendable {
    let id: UUID
    let path: String
    let displayName: String
    let volumeUUID: String?
    let isRemovable: Bool
    var isOffline: Bool = false

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

struct VideoTitle: Codable, Equatable, Sendable {
    var title: String
    var year: Int?
    var season: Int?
    var episodes: [Int] = []
    var episodeTitle: String?
    var resolution: String?
    var hdr: String?
    var codec: String?
    var isPersonal = false
}

struct LocalAudioTags: Codable, Equatable, Sendable {
    var title: String
    var artist: String?
    var album: String?
    var albumArtist: String?
    var year: Int?
    var track: Int?
    var disc: Int?
    var duration: Double?
    var codec: String?
    var sampleRate: Int?
    var bitDepth: Int?
    var isLossless = false
    var isrc: String?
    var genres: [String] = []
    var rating: Double?
    var artworkPath: String?
}

struct MediaLibraryFile: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case video, audio }
    var id: String { path }
    let path: String
    let size: Int64
    let modified: Date
    let added: Date
    var video: VideoTitle?
    var audio: LocalAudioTags?

    var url: URL { URL(fileURLWithPath: path) }
    var kind: Kind { audio == nil ? .video : .audio }
    var title: String {
        video?.title ?? audio?.title ?? url.deletingPathExtension().lastPathComponent
    }
    var container: String { url.pathExtension.uppercased() }
    var seriesKey: String? {
        guard let video, video.season != nil, !video.episodes.isEmpty else { return nil }
        return Self.normalized(video.title)
    }

    var albumKey: String? {
        guard let audio, let album = audio.album else { return nil }
        let artist = audio.albumArtist ?? audio.artist ?? ""
        return Self.normalized(artist) + "\u{1f}" + Self.normalized(album)
    }

    var metadataKey: String? {
        if let video, !video.isPersonal {
            if let seriesKey { return "series|" + seriesKey }
            return "movie|" + Self.normalized(video.title) + "|"
                + (video.year.map(String.init) ?? "")
        }
        let artist = audio?.albumArtist ?? audio?.artist
        if let albumKey, let artist, !artist.isEmpty { return "album|" + albumKey }
        return nil
    }

    static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}

struct LocalVideoItem: Identifiable {
    var id: String { file.id }
    let file: MediaLibraryFile
    let metadata: MediaEnrichment?
    let progress: WatchProgress?
    let isOffline: Bool
}

struct LocalEpisodeItem: Identifiable {
    var id: String { video.id }
    let video: LocalVideoItem
    var season: Int { video.file.video?.season ?? 0 }
    var number: Int { video.file.video?.episodes.first ?? 0 }
    var title: String {
        if let match = video.metadata?.episodes.first(where: {
            $0.season == season && $0.number == number
        }) {
            return match.title
        }
        return video.file.video?.episodeTitle
            ?? video.file.url.deletingPathExtension().lastPathComponent
    }
}

struct LocalSeriesGroup: Identifiable {
    let id: String
    let title: String
    let episodes: [LocalEpisodeItem]
    var next: LocalEpisodeItem? {
        let last = episodes.filter { $0.video.progress != nil }.max {
            ($0.video.progress?.updated ?? .distantPast)
                < ($1.video.progress?.updated ?? .distantPast)
        }
        if let last, last.video.progress?.completed != true { return last }
        if let last, let index = episodes.firstIndex(where: { $0.id == last.id }) {
            return episodes.dropFirst(index + 1).first { $0.video.progress?.completed != true }
        }
        return episodes.first { $0.video.progress?.completed != true }
    }
}

struct LocalAudioTrack: Identifiable, Sendable {
    var id: String { file.id }
    let file: MediaLibraryFile
    let metadata: MediaEnrichment?
    let isOffline: Bool
    var albumArtworkPath: String? = nil
    var title: String { file.title }
    var artist: String { file.audio?.artist ?? "" }
    var album: String { file.audio?.album ?? "" }
    var artworkPath: String? { file.audio?.artworkPath ?? albumArtworkPath ?? metadata?.posterPath }
    var genres: [String] {
        file.audio?.genres.isEmpty == false ? file.audio?.genres ?? [] : metadata?.genres ?? []
    }
    var rating: Double? { file.audio?.rating ?? metadata?.rating }
    var format: String { file.audio?.codec ?? file.container }
}

struct LocalAudioAlbum: Identifiable {
    let id: String
    let tracks: [LocalAudioTrack]
}

struct WatchProgress: Codable, Sendable {
    let path: String
    let position: Double
    let duration: Double
    let completed: Bool
    let updated: Date
}

enum HomeSection: CaseIterable, Hashable { case overview, video, audio, recent }

struct HomeFilterState {
    enum VideoKind: CaseIterable { case all, movies, series, unwatched }
    enum Sort: CaseIterable { case title, rating, recent }
    var videoKind = VideoKind.all
    var sort = Sort.title
    var genre: String?
    var videoMinimumRating = false
    var audioMinimumRating = false
    var lossless = false
    var ultraHD = false
    var query = ""

    var overview: Self { Self(genre: genre, query: query) }
}

enum MediaRatingScale {
    static func convert(_ value: Double?, from fullScale: Double, to target: Double) -> Double? {
        guard let value, (0...fullScale).contains(value) else { return nil }
        return value / fullScale * target
    }
}

struct MediaEnrichment: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case imdb = "IMDb"
        case tvmaze = "TVMaze"
        case musicBrainz = "MusicBrainz"
    }
    struct Episode: Codable, Equatable, Sendable {
        let season: Int
        let number: Int
        let title: String
        var summary: String?
    }
    var title: String?
    var summary: String?
    var rating: Double?
    var source: Source?
    var year: String?
    var genres: [String] = []
    var posterURL: URL?
    var posterPath: String?
    var episodes: [Episode] = []
    var fetched = Date()
    var notFound = false
}
