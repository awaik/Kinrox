import Foundation

public struct MusicArtist: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let uri: String
    public let name: String

    public init(id: String, uri: String, name: String) {
        self.id = id
        self.uri = uri
        self.name = name
    }
}

public struct MusicAlbum: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let uri: String
    public let title: String
    public let artists: [MusicArtist]
    public let year: String
    public let releaseDate: String?
    public let trackIDs: [String]
    public let totalTrackCount: Int

    public init(
        id: String, uri: String, title: String, artists: [MusicArtist], year: String,
        trackIDs: [String], totalTrackCount: Int? = nil, releaseDate: String? = nil
    ) {
        self.id = id
        self.uri = uri
        self.title = title
        self.artists = artists
        self.year = year
        self.releaseDate = releaseDate
        self.trackIDs = trackIDs
        self.totalTrackCount = max(trackIDs.count, totalTrackCount ?? 0)
    }

    public var artistNames: String { artists.map(\.name).joined(separator: ", ") }
}

public struct MusicTrack: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let uri: String
    public let title: String
    public let artists: [MusicArtist]
    public let albumID: String
    public let albumTitle: String
    public let duration: Double
    public let isrc: String?
    public let releaseDate: String?
    public let explicit: Bool?
    public let isPlayable: Bool?
    public var addedAt: Date?
    public var playlistAddedAt: [String: Date]?

    public init(
        id: String, uri: String, title: String, artists: [MusicArtist], albumID: String,
        albumTitle: String, duration: Double, explicit: Bool? = nil, isPlayable: Bool? = nil,
        addedAt: Date? = nil, playlistAddedAt: [String: Date]? = nil,
        isrc: String? = nil, releaseDate: String? = nil
    ) {
        self.id = id
        self.uri = uri
        self.title = title
        self.artists = artists
        self.albumID = albumID
        self.albumTitle = albumTitle
        self.isrc = isrc
        self.releaseDate = releaseDate
        self.explicit = explicit
        self.isPlayable = isPlayable
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.addedAt = addedAt
        self.playlistAddedAt = playlistAddedAt?.isEmpty == true ? nil : playlistAddedAt
    }

    public var artistNames: String { artists.map(\.name).joined(separator: ", ") }

    public func addedDate(for playlistID: String? = nil) -> Date? {
        if let playlistID {
            return playlistAddedAt?[playlistID]
        }
        return addedAt
    }
}

public struct MusicPlaylist: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let uri: String
    public var title: String
    public let ownerID: String
    public let collaborative: Bool
    public var snapshotID: String
    /// Ordered occurrences, including duplicates; indices are Spotify positions.
    public var trackIDs: [String]
    /// Separate from metadata presence: false when Spotify restricts `/items` for a non-editable playlist.
    public var itemsAvailable: Bool

    public init(
        id: String, uri: String, title: String, ownerID: String, collaborative: Bool = false,
        snapshotID: String = "", trackIDs: [String] = [], itemsAvailable: Bool = true
    ) {
        self.id = id
        self.uri = uri
        self.title = title
        self.ownerID = ownerID
        self.collaborative = collaborative
        self.snapshotID = snapshotID
        self.trackIDs = trackIDs
        self.itemsAvailable = itemsAvailable
    }

    public func isEditable(by userID: String) -> Bool {
        !userID.isEmpty && (ownerID == userID || collaborative)
    }
}
