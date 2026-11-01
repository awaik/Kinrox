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
    public let trackIDs: [String]
    public let totalTrackCount: Int

    public init(
        id: String, uri: String, title: String, artists: [MusicArtist], year: String,
        trackIDs: [String], totalTrackCount: Int? = nil
    ) {
        self.id = id
        self.uri = uri
        self.title = title
        self.artists = artists
        self.year = year
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
    public let explicit: Bool?
    public let isPlayable: Bool?

    public init(
        id: String, uri: String, title: String, artists: [MusicArtist], albumID: String,
        albumTitle: String, duration: Double, explicit: Bool? = nil, isPlayable: Bool? = nil
    ) {
        self.id = id
        self.uri = uri
        self.title = title
        self.artists = artists
        self.albumID = albumID
        self.albumTitle = albumTitle
        self.explicit = explicit
        self.isPlayable = isPlayable
        self.duration = duration.isFinite ? max(0, duration) : 0
    }

    public var artistNames: String { artists.map(\.name).joined(separator: ", ") }
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

    public init(
        id: String, uri: String, title: String, ownerID: String, collaborative: Bool = false,
        snapshotID: String = "", trackIDs: [String] = []
    ) {
        self.id = id
        self.uri = uri
        self.title = title
        self.ownerID = ownerID
        self.collaborative = collaborative
        self.snapshotID = snapshotID
        self.trackIDs = trackIDs
    }

    public func isEditable(by userID: String) -> Bool {
        !userID.isEmpty && (ownerID == userID || collaborative)
    }
}

public struct MusicCatalog: Codable, Equatable, Sendable {
    public var tracks: [MusicTrack]
    public var albums: [MusicAlbum]
    public var artists: [MusicArtist]

    public init(tracks: [MusicTrack] = [], albums: [MusicAlbum] = [], artists: [MusicArtist] = []) {
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
    }

    public func tracks(in album: MusicAlbum) -> [MusicTrack] {
        album.trackIDs.compactMap { id in tracks.first { $0.id == id } }
    }
}
