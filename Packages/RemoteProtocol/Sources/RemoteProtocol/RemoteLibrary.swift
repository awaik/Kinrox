import Foundation

public struct StateRequest: Codable, Sendable, Equatable {
    public var features: [String]?

    public init(features: [String]? = nil) {
        self.features = features
    }
}

public struct RemoteLibraryState: Codable, Sendable, Equatable {
    public var revision: UUID
    public var progressRevision: UUID
    public var folders: Int
    public var videos: Int
    public var series: Int
    public var albums: Int
    public var tracks: Int
    public var scanning: Bool

    public init(
        revision: UUID, progressRevision: UUID, folders: Int, videos: Int, series: Int,
        albums: Int, tracks: Int, scanning: Bool
    ) {
        self.revision = revision
        self.progressRevision = progressRevision
        self.folders = folders
        self.videos = videos
        self.series = series
        self.albums = albums
        self.tracks = tracks
        self.scanning = scanning
    }
}

public struct RemoteSourceSummary: Codable, Sendable, Equatable {
    public var title: String
    public var subtitle: String?
    public var paused: Bool
    public var artwork: String?

    public init(title: String, subtitle: String? = nil, paused: Bool, artwork: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.paused = paused
        self.artwork = artwork
    }
}

public struct RemoteSources: Codable, Sendable, Equatable {
    public var video: RemoteSourceSummary?
    public var localMusic: RemoteSourceSummary?
    public var spotify: RemoteSourceSummary?

    public init(
        video: RemoteSourceSummary? = nil, localMusic: RemoteSourceSummary? = nil,
        spotify: RemoteSourceSummary? = nil
    ) {
        self.video = video
        self.localMusic = localMusic
        self.spotify = spotify
    }
}

public enum RemoteMusicOrigin: String, Codable, Sendable { case spotify, local }
public enum RemotePlaybackStart: String, Codable, Sendable { case resume, start }
public enum RemoteControllableSource: String, Codable, Sendable { case video, localMusic, spotify }

public enum RemoteLibrarySection: String, Codable, Sendable, CaseIterable {
    case continueWatching, videos, series, albums, tracks, children
}

public enum RemoteLibraryVideoKind: String, Codable, Sendable, CaseIterable {
    case all, movies, series, unwatched
}

public enum RemoteLibrarySort: String, Codable, Sendable, CaseIterable {
    case title, rating, recent
}

public struct LibraryRequest: Codable, Sendable, Equatable {
    public var section: RemoteLibrarySection
    public var parentId: String?
    public var videoKind: RemoteLibraryVideoKind?
    public var sort: RemoteLibrarySort?
    public var query: String?
    public var offset: Int
    public var revision: UUID?

    public init(
        section: RemoteLibrarySection, parentId: String? = nil,
        videoKind: RemoteLibraryVideoKind? = nil, sort: RemoteLibrarySort? = nil,
        query: String? = nil, offset: Int = 0, revision: UUID? = nil
    ) {
        self.section = section
        self.parentId = parentId
        self.videoKind = videoKind
        self.sort = sort
        self.query = query
        self.offset = offset
        self.revision = revision
    }
}

public struct RemoteWatchProgress: Codable, Sendable, Equatable {
    public var position: Double
    public var duration: Double
    public var completed: Bool

    public init(position: Double, duration: Double, completed: Bool) {
        self.position = position
        self.duration = duration
        self.completed = completed
    }
}

public struct RemoteLibraryItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case movie, series, episode, album, track
    }

    public let id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var episodeLabel: String?
    public var season: Int?
    public var episode: Int?
    public var trackNumber: Int?
    public var year: Int?
    public var rating: Double?
    public var ratingScale: Int?
    public var genres: [String]
    public var badges: [String]
    public var duration: Double?
    public var progress: RemoteWatchProgress?
    public var childCount: Int?
    public var folderName: String?
    public var offline: Bool
    public var artwork: Bool

    public init(
        id: String, kind: Kind, title: String, subtitle: String? = nil,
        episodeLabel: String? = nil, season: Int? = nil, episode: Int? = nil,
        trackNumber: Int? = nil, year: Int? = nil, rating: Double? = nil,
        ratingScale: Int? = nil, genres: [String] = [], badges: [String] = [],
        duration: Double? = nil, progress: RemoteWatchProgress? = nil, childCount: Int? = nil,
        folderName: String? = nil, offline: Bool = false, artwork: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.episodeLabel = episodeLabel
        self.season = season
        self.episode = episode
        self.trackNumber = trackNumber
        self.year = year
        self.rating = rating
        self.ratingScale = ratingScale
        self.genres = genres
        self.badges = badges
        self.duration = duration
        self.progress = progress
        self.childCount = childCount
        self.folderName = folderName
        self.offline = offline
        self.artwork = artwork
    }
}

public struct LibraryPage: Codable, Sendable, Equatable {
    public let replyTo: UUID
    public let revision: UUID
    public let section: RemoteLibrarySection
    public let parentId: String?
    public let offset: Int
    public let total: Int
    public let nextOffset: Int?
    public let items: [RemoteLibraryItem]

    public init(
        replyTo: UUID, revision: UUID, section: RemoteLibrarySection, parentId: String? = nil,
        offset: Int, total: Int, nextOffset: Int?, items: [RemoteLibraryItem]
    ) {
        self.replyTo = replyTo
        self.revision = revision
        self.section = section
        self.parentId = parentId
        self.offset = offset
        self.total = total
        self.nextOffset = nextOffset
        self.items = items
    }
}

public struct LibraryItemRequest: Codable, Sendable, Equatable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct LibraryItemDetails: Codable, Sendable, Equatable {
    public var overview: String?
    public var ratingSource: String?
    public var fileName: String?
    public var folderName: String?
    public var audioLanguages: [String]
    public var subtitleLanguages: [String]
    public var seasons: [Int]
    public var watchedCount: Int?
    public var nextEpisodeId: String?

    public init(
        overview: String? = nil, ratingSource: String? = nil, fileName: String? = nil,
        folderName: String? = nil, audioLanguages: [String] = [], subtitleLanguages: [String] = [],
        seasons: [Int] = [], watchedCount: Int? = nil, nextEpisodeId: String? = nil
    ) {
        self.overview = overview
        self.ratingSource = ratingSource
        self.fileName = fileName
        self.folderName = folderName
        self.audioLanguages = audioLanguages
        self.subtitleLanguages = subtitleLanguages
        self.seasons = seasons
        self.watchedCount = watchedCount
        self.nextEpisodeId = nextEpisodeId
    }
}

public struct LibraryItemResponse: Codable, Sendable, Equatable {
    public let replyTo: UUID
    public let revision: UUID
    public let item: RemoteLibraryItem
    public let details: LibraryItemDetails

    public init(
        replyTo: UUID, revision: UUID, item: RemoteLibraryItem, details: LibraryItemDetails
    ) {
        self.replyTo = replyTo
        self.revision = revision
        self.item = item
        self.details = details
    }
}

public struct ArtworkRequest: Codable, Sendable, Equatable {
    public let id: String
    public let maxPixel: Int

    public init(id: String, maxPixel: Int) {
        self.id = id
        self.maxPixel = maxPixel
    }
}

public struct ArtworkResponse: Codable, Sendable, Equatable {
    public let replyTo: UUID
    public let id: String
    public let jpeg: Data?

    public init(replyTo: UUID, id: String, jpeg: Data?) {
        self.replyTo = replyTo
        self.id = id
        self.jpeg = jpeg
    }
}
