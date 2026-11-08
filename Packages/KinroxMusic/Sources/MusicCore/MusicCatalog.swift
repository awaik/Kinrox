import Foundation

/// Ordered presentation arrays with constant-time identity lookup. Indices are derived, never encoded.
public struct MusicCatalog: Codable, Equatable, Sendable {
    public private(set) var tracks: [MusicTrack] = []
    public private(set) var albums: [MusicAlbum] = []
    public private(set) var artists: [MusicArtist] = []
    private var trackIndices: [String: Int] = [:]
    private var albumIndices: [String: Int] = [:]
    private var artistIndices: [String: Int] = [:]

    private var artistGroupCache: [String: [MusicArtist]] = [:]

    public init(tracks: [MusicTrack] = [], albums: [MusicAlbum] = [], artists: [MusicArtist] = []) {
        merge(tracks: tracks, albums: albums, artists: artists)
    }

    public static func == (lhs: MusicCatalog, rhs: MusicCatalog) -> Bool {
        lhs.tracks == rhs.tracks && lhs.albums == rhs.albums && lhs.artists == rhs.artists
    }

    public func track(id: String) -> MusicTrack? { trackIndices[id].map { tracks[$0] } }
    public func album(id: String) -> MusicAlbum? { albumIndices[id].map { albums[$0] } }
    public func artist(id: String) -> MusicArtist? { artistIndices[id].map { artists[$0] } }
    public func tracks(in album: MusicAlbum) -> [MusicTrack] {
        album.trackIDs.compactMap { track(id: $0) }
    }

    public mutating func merge(
        tracks: [MusicTrack] = [], albums: [MusicAlbum] = [], artists: [MusicArtist] = []
    ) {
        for artist in artists + tracks.flatMap(\.artists) + albums.flatMap(\.artists) {
            if let index = artistIndices[artist.id] {
                let existing = self.artists[index]
                let canonical =
                    existing == artist
                    ? existing
                    : MusicArtist(
                        id: existing.id,
                        uri: existing.uri == artist.uri ? existing.uri : artist.uri,
                        name: existing.name == artist.name ? existing.name : artist.name)
                self.artists[index] = canonical
                if existing != canonical { artistGroupCache.removeAll(keepingCapacity: true) }
            } else {
                artistIndices[artist.id] = self.artists.count
                self.artists.append(artist)
            }
        }
        for album in albums {
            let existing = albumIndices[album.id].map { self.albums[$0] }
            let canonicalID = existing?.id ?? album.id
            let canonicalURI = existing?.uri == album.uri ? (existing?.uri ?? album.uri) : album.uri
            let canonicalTitle =
                existing?.title == album.title ? (existing?.title ?? album.title) : album.title
            let canonicalArtists = internedArtists(album.artists)
            let internedAlbum = MusicAlbum(
                id: canonicalID, uri: canonicalURI, title: canonicalTitle,
                artists: canonicalArtists, year: album.year, trackIDs: album.trackIDs,
                totalTrackCount: album.totalTrackCount)
            if let index = albumIndices[canonicalID] {
                if !internedAlbum.trackIDs.isEmpty || self.albums[index].trackIDs.isEmpty {
                    self.albums[index] = internedAlbum
                }
            } else {
                albumIndices[canonicalID] = self.albums.count
                self.albums.append(internedAlbum)
            }
        }
        for track in tracks {
            let existing = trackIndices[track.id].map { self.tracks[$0] }
            let canonicalID = existing?.id ?? track.id
            let canonicalAlbum = albumIndices[track.albumID].map { self.albums[$0] }
            let canonicalAlbumID =
                canonicalAlbum?.id
                ?? (existing?.albumID == track.albumID
                    ? (existing?.albumID ?? track.albumID) : track.albumID)
            let canonicalAlbumTitle =
                canonicalAlbum?.title == track.albumTitle
                ? (canonicalAlbum?.title ?? track.albumTitle)
                : (existing?.albumTitle == track.albumTitle
                    ? (existing?.albumTitle ?? track.albumTitle) : track.albumTitle)
            var merged = MusicTrack(
                id: canonicalID,
                uri: existing?.uri == track.uri ? (existing?.uri ?? track.uri) : track.uri,
                title: existing?.title == track.title
                    ? (existing?.title ?? track.title) : track.title,
                artists: internedArtists(track.artists),
                albumID: canonicalAlbumID,
                albumTitle: canonicalAlbumTitle,
                duration: track.duration,
                explicit: track.explicit,
                isPlayable: track.isPlayable,
                addedAt: track.addedAt ?? existing?.addedAt,
                playlistAddedAt: track.playlistAddedAt)
            if let existing, existing.playlistAddedAt != nil || merged.playlistAddedAt != nil {
                var combined = existing.playlistAddedAt ?? [:]
                if let incoming = merged.playlistAddedAt {
                    combined.merge(incoming) { _, new in new }
                }
                merged.playlistAddedAt = combined.isEmpty ? nil : combined
            }
            if let index = trackIndices[canonicalID] {
                self.tracks[index] = merged
            } else {
                trackIndices[canonicalID] = self.tracks.count
                self.tracks.append(merged)
            }
        }
    }

    private mutating func internedArtists(_ items: [MusicArtist]) -> [MusicArtist] {
        guard !items.isEmpty else { return [] }
        let key =
            items.count == 1 ? items[0].id : items.map(\.id).joined(separator: "\u{1F}")
        if let cached = artistGroupCache[key], cached == items {
            return cached
        }
        let resolved = items.map { item -> MusicArtist in
            if let index = artistIndices[item.id], self.artists[index] == item {
                return self.artists[index]
            }
            return item
        }
        artistGroupCache[key] = resolved
        return resolved
    }

    private enum CodingKeys: String, CodingKey { case tracks, albums, artists }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tracks: try values.decode([MusicTrack].self, forKey: .tracks),
            albums: try values.decode([MusicAlbum].self, forKey: .albums),
            artists: try values.decode([MusicArtist].self, forKey: .artists))
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(tracks, forKey: .tracks)
        try values.encode(albums, forKey: .albums)
        try values.encode(artists, forKey: .artists)
    }
}
