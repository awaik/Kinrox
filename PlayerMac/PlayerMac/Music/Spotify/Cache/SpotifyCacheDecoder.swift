import Foundation
import MusicCore

/// JSON parsing is CPU work, independent of the serial SQLite connection.
enum SpotifyCacheDecoder {
    static func catalog(_ batches: SpotifyCatalogBatches) async throws -> MusicCatalog {
        async let decodedTracks = decodeBatches(batches.tracks, as: MusicTrack.self)
        async let decodedAlbums = decodeBatches(batches.albums, as: MusicAlbum.self)
        async let decodedArtists = decodeBatches(batches.artists, as: MusicArtist.self)
        return try await MusicCatalog(
            tracks: decodedTracks, albums: decodedAlbums, artists: decodedArtists)
    }

    private static func decodeBatches<T: Decodable & Sendable>(_ batches: [Data], as type: T.Type)
        async throws -> [T]
    {
        guard !batches.isEmpty else { return [] }
        if batches.count == 1 {
            try Task.checkCancellation()
            return try JSONDecoder().decode([T].self, from: batches[0])
        }
        return try await withThrowingTaskGroup(of: (Int, [T]).self) { group in
            for (index, batch) in batches.enumerated() {
                group.addTask {
                    try Task.checkCancellation()
                    return (index, try JSONDecoder().decode([T].self, from: batch))
                }
            }
            var chunks: [(Int, [T])] = []
            chunks.reserveCapacity(batches.count)
            for try await chunk in group { chunks.append(chunk) }
            return chunks.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }
}

/// Compact per-entity digest snapshot so `SpotifyCacheStore` diffs incremental SQLite writes
/// without retaining a second copy of `MusicCatalog` and `LibrarySnapshot` in actor memory.
struct SpotifyCacheSummary: Equatable, Sendable {
    var resources: [String: SpotifyResourceState]
    var likedDigest: UInt64
    var albumsDigest: UInt64
    var artistsDigest: UInt64
    var playlists: [String: UInt64]
    var tracks: [String: UInt64]
    var albums: [String: UInt64]
    var artists: [String: UInt64]

    init(_ value: SpotifyCachedLibrary) {
        resources = value.resources
        likedDigest = Self.digest(value.library.likedTrackIDs)
        albumsDigest = Self.digest(value.library.savedAlbumIDs)
        artistsDigest = Self.digest(value.library.followedArtistIDs)
        playlists = Dictionary(
            uniqueKeysWithValues: value.library.playlists.map { ($0.id, Self.digest($0)) })
        tracks = Dictionary(
            uniqueKeysWithValues: value.catalog.tracks.map { ($0.id, Self.digest($0)) })
        albums = Dictionary(
            uniqueKeysWithValues: value.catalog.albums.map { ($0.id, Self.digest($0)) })
        artists = Dictionary(
            uniqueKeysWithValues: value.catalog.artists.map { ($0.id, Self.digest($0)) })
    }

    private struct FNV1a {
        private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325
        mutating func mix(_ byte: UInt8) {
            value ^= UInt64(byte)
            value &*= 0x0000_0100_0000_01b3
        }
        mutating func mix(_ word: UInt64) {
            withUnsafeBytes(of: word.littleEndian) { for byte in $0 { mix(byte) } }
        }
        mutating func mix(_ text: String) {
            for byte in text.utf8 { mix(byte) }
            mix(0xff)
        }
        mutating func mix(_ int: Int) { mix(UInt64(bitPattern: Int64(int))) }
        mutating func mix(_ double: Double) { mix(double.bitPattern) }
        mutating func mix(_ bool: Bool?) {
            switch bool {
            case nil: mix(UInt8(0))
            case true?: mix(UInt8(1))
            case false?: mix(UInt8(2))
            }
        }
        mutating func mix(_ date: Date?) {
            guard let date else {
                mix(UInt8(0))
                return
            }
            mix(UInt8(1))
            mix(date.timeIntervalSince1970)
        }
        mutating func mix(_ artist: MusicArtist) {
            mix(artist.id)
            mix(artist.uri)
            mix(artist.name)
        }
    }

    private static func digest(_ set: Set<String>) -> UInt64 {
        var sum: UInt64 = 0
        var xor: UInt64 = 0
        for item in set {
            var hasher = FNV1a()
            hasher.mix(item)
            sum &+= hasher.value
            xor ^= hasher.value
        }
        var out = FNV1a()
        out.mix(set.count)
        out.mix(sum)
        out.mix(xor)
        return out.value
    }

    private static func digest(_ artist: MusicArtist) -> UInt64 {
        var hasher = FNV1a()
        hasher.mix(artist)
        return hasher.value
    }

    private static func digest(_ album: MusicAlbum) -> UInt64 {
        var hasher = FNV1a()
        hasher.mix(album.id)
        hasher.mix(album.uri)
        hasher.mix(album.title)
        hasher.mix(album.year)
        hasher.mix(album.releaseDate ?? "")
        hasher.mix(album.totalTrackCount)
        hasher.mix(album.artists.count)
        for artist in album.artists { hasher.mix(artist) }
        hasher.mix(album.trackIDs.count)
        for id in album.trackIDs { hasher.mix(id) }
        return hasher.value
    }

    private static func digest(_ track: MusicTrack) -> UInt64 {
        var hasher = FNV1a()
        hasher.mix(track.id)
        hasher.mix(track.uri)
        hasher.mix(track.title)
        hasher.mix(track.albumID)
        hasher.mix(track.albumTitle)
        hasher.mix(track.duration)
        hasher.mix(track.isrc ?? "")
        hasher.mix(track.releaseDate ?? "")
        hasher.mix(track.explicit)
        hasher.mix(track.isPlayable)
        hasher.mix(track.addedAt)
        hasher.mix(track.artists.count)
        for artist in track.artists { hasher.mix(artist) }
        if let playlistAddedAt = track.playlistAddedAt {
            var sum: UInt64 = 0
            var xor: UInt64 = 0
            for (playlistID, date) in playlistAddedAt {
                var entry = FNV1a()
                entry.mix(playlistID)
                entry.mix(date)
                sum &+= entry.value
                xor ^= entry.value
            }
            hasher.mix(playlistAddedAt.count)
            hasher.mix(sum)
            hasher.mix(xor)
        } else {
            hasher.mix(0)
        }
        return hasher.value
    }

    private static func digest(_ playlist: MusicPlaylist) -> UInt64 {
        var hasher = FNV1a()
        hasher.mix(playlist.id)
        hasher.mix(playlist.uri)
        hasher.mix(playlist.title)
        hasher.mix(playlist.ownerID)
        hasher.mix(playlist.collaborative)
        hasher.mix(playlist.snapshotID)
        hasher.mix(playlist.itemsAvailable)
        hasher.mix(playlist.trackIDs.count)
        for id in playlist.trackIDs { hasher.mix(id) }
        return hasher.value
    }
}
