import Foundation

/// Ordered presentation arrays with constant-time identity lookup. Indices are derived, never encoded.
public struct MusicCatalog: Codable, Equatable, Sendable {
    public private(set) var tracks: [MusicTrack] = []
    public private(set) var albums: [MusicAlbum] = []
    public private(set) var artists: [MusicArtist] = []
    private var trackIndices: [String: Int] = [:]
    private var albumIndices: [String: Int] = [:]
    private var artistIndices: [String: Int] = [:]

    public init(tracks: [MusicTrack] = [], albums: [MusicAlbum] = [], artists: [MusicArtist] = []) {
        merge(tracks: tracks, albums: albums, artists: artists)
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
        for track in tracks {
            if let index = trackIndices[track.id] {
                let existing = self.tracks[index]
                var merged = track
                if merged.addedAt == nil { merged.addedAt = existing.addedAt }
                if existing.playlistAddedAt != nil || merged.playlistAddedAt != nil {
                    var combined = existing.playlistAddedAt ?? [:]
                    if let incoming = merged.playlistAddedAt {
                        combined.merge(incoming) { _, new in new }
                    }
                    merged.playlistAddedAt = combined.isEmpty ? nil : combined
                }
                self.tracks[index] = merged
            } else {
                trackIndices[track.id] = self.tracks.count
                self.tracks.append(track)
            }
        }
        for album in albums {
            if let index = albumIndices[album.id] {
                if !album.trackIDs.isEmpty || self.albums[index].trackIDs.isEmpty {
                    self.albums[index] = album
                }
            } else {
                albumIndices[album.id] = self.albums.count
                self.albums.append(album)
            }
        }
        for artist in artists + tracks.flatMap(\.artists) + albums.flatMap(\.artists) {
            if let index = artistIndices[artist.id] {
                self.artists[index] = artist
            } else {
                artistIndices[artist.id] = self.artists.count
                self.artists.append(artist)
            }
        }
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
