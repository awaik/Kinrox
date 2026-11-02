import Foundation
import MusicCore

/// JSON parsing is CPU work, independent of the serial SQLite connection.
enum SpotifyCacheDecoder {
    static func catalog(_ rows: [[Data?]]) async throws -> MusicCatalog {
        var tracks: [Data] = []
        var albums: [Data] = []
        var artists: [Data] = []
        for row in rows {
            guard let kind = row[0].flatMap({ String(data: $0, encoding: .utf8) }),
                let data = row[1]
            else { continue }
            switch kind {
            case "track": tracks.append(data)
            case "album": albums.append(data)
            case "artist": artists.append(data)
            default: break
            }
        }
        async let decodedTracks = decode(tracks, as: MusicTrack.self)
        async let decodedAlbums = decode(albums, as: MusicAlbum.self)
        async let decodedArtists = decode(artists, as: MusicArtist.self)
        return try await MusicCatalog(
            tracks: decodedTracks, albums: decodedAlbums, artists: decodedArtists)
    }

    private static func decode<T: Decodable & Sendable>(_ rows: [Data], as type: T.Type)
        async throws -> [T]
    {
        guard !rows.isEmpty else { return [] }
        let chunkSize = max(256, (rows.count + 3) / 4)
        return try await withThrowingTaskGroup(of: (Int, [T]).self) { group in
            for offset in stride(from: 0, to: rows.count, by: chunkSize) {
                let chunk = Array(rows[offset..<min(offset + chunkSize, rows.count)])
                group.addTask {
                    try Task.checkCancellation()
                    var data = Data("[".utf8)
                    data.reserveCapacity(chunk.reduce(2) { $0 + $1.count + 1 })
                    for (index, value) in chunk.enumerated() {
                        if index > 0 { data.append(44) }
                        data.append(value)
                    }
                    data.append(93)
                    return (offset, try JSONDecoder().decode([T].self, from: data))
                }
            }
            var chunks: [(Int, [T])] = []
            for try await chunk in group { chunks.append(chunk) }
            return chunks.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }
}
