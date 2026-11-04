import Foundation

public enum PlaybackSource: String, Codable, Sendable { case video, music }
public enum RemoteMusicRepeat: String, Codable, Sendable { case off, all, one }

/// Metadata only. No account identifiers, credentials, artwork, paths or URLs.
public struct RemoteMusicTrack: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var artists: [String]
    public var album: String
    public var year: String
    public var duration: Double
    public var albumID: String?
    public var explicit: Bool?
    public var isPlayable: Bool?
    public init(
        id: String, title: String, artists: [String], album: String, year: String, duration: Double,
        albumID: String? = nil, explicit: Bool? = nil, isPlayable: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.album = album
        self.year = year
        self.duration = duration
        self.albumID = albumID
        self.explicit = explicit
        self.isPlayable = isPlayable
    }
}

public struct MusicState: Codable, Sendable, Equatable {
    public var track: RemoteMusicTrack?
    public var nextTrack: RemoteMusicTrack?
    public var liked: Bool
    public var shuffle: Bool
    public var repeatMode: RemoteMusicRepeat
    public var queueCount: Int
    public var queueRevision: UUID
    public var libraryRevision: UUID
    public var outputName: String
    public var status: String?
    public var disallowedActions: [String]?
    public var favoriteFeedback: RemoteFavoriteFeedback?
    /// Seconds since the Mac's confirmed position anchor, measured with its monotonic clock.
    public var positionAge: Double?
    /// Nil preserves older Macs' behavior; false requires a disabled, zero-valued wire volume.
    public var volumeKnown: Bool?
    public init(
        track: RemoteMusicTrack?, nextTrack: RemoteMusicTrack?, liked: Bool, shuffle: Bool,
        repeatMode: RemoteMusicRepeat, queueCount: Int, queueRevision: UUID, libraryRevision: UUID,
        outputName: String, status: String? = nil, disallowedActions: [String]? = nil,
        favoriteFeedback: RemoteFavoriteFeedback? = nil, positionAge: Double? = nil,
        volumeKnown: Bool? = nil
    ) {
        self.track = track
        self.nextTrack = nextTrack
        self.liked = liked
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.queueCount = queueCount
        self.queueRevision = queueRevision
        self.libraryRevision = libraryRevision
        self.outputName = outputName
        self.status = status
        self.disallowedActions = disallowedActions
        self.favoriteFeedback = favoriteFeedback
        self.positionAge = positionAge
        self.volumeKnown = volumeKnown
    }
}

public struct QueueRequest: Codable, Sendable, Equatable {
    public var offset: Int
    public var revision: UUID?
    public init(offset: Int = 0, revision: UUID? = nil) {
        self.offset = offset
        self.revision = revision
    }
}
public struct RemoteQueueItem: Codable, Sendable, Equatable, Identifiable {
    public enum Section: String, Codable, Sendable { case current, manual, source }
    public let id: UUID
    public var section: Section
    public var track: RemoteMusicTrack
    public var liked: Bool
    public init(id: UUID, section: Section, track: RemoteMusicTrack, liked: Bool = false) {
        self.id = id
        self.section = section
        self.track = track
        self.liked = liked
    }
}
public struct QueuePage: Codable, Sendable, Equatable {
    public let replyTo: UUID
    public let revision: UUID
    public let offset: Int
    public let total: Int
    public let nextOffset: Int?
    public let items: [RemoteQueueItem]
    public init(
        replyTo: UUID, revision: UUID, offset: Int, total: Int, nextOffset: Int?,
        items: [RemoteQueueItem]
    ) {
        self.replyTo = replyTo
        self.revision = revision
        self.offset = offset
        self.total = total
        self.nextOffset = nextOffset
        self.items = items
    }
}

public struct LikeOptionsRequest: Codable, Sendable, Equatable {
    public let trackId: String
    public let offset: Int
    public let revision: UUID?
    public init(trackId: String, offset: Int = 0, revision: UUID? = nil) {
        self.trackId = trackId
        self.offset = offset
        self.revision = revision
    }
}
public struct RemoteLikeOption: Codable, Sendable, Equatable, Identifiable {
    public var isValid: Bool { Command.validMusicID(id) && title.utf8.count <= 2048 }
    public enum Kind: String, Codable, Sendable { case playlist, artist }
    public let id: String
    public let kind: Kind
    public let title: String
    public let selected: Bool
    public init(id: String, kind: Kind, title: String, selected: Bool) {
        self.id = id
        self.kind = kind
        self.title = title
        self.selected = selected
    }
}
public struct LikeOptionsPage: Codable, Sendable, Equatable {
    public let replyTo: UUID
    public let trackId: String
    public let revision: UUID
    public let offset: Int
    public let total: Int
    public let nextOffset: Int?
    public let items: [RemoteLikeOption]
    public let liked: Bool
    public init(
        replyTo: UUID, trackId: String, revision: UUID, offset: Int, total: Int,
        nextOffset: Int?, items: [RemoteLikeOption], liked: Bool = false
    ) {
        self.replyTo = replyTo
        self.trackId = trackId
        self.revision = revision
        self.offset = offset
        self.total = total
        self.nextOffset = nextOffset
        self.items = items
        self.liked = liked
    }
}
