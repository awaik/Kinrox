import Foundation
import MetaBrainzAPI
import MusicCore

struct SpotifyDiscoveryAlbum: Codable, Sendable {
    var album: MusicAlbum
    var tracks: [MusicTrack]
}

struct SpotifyDiscoveryData: Codable, Sendable {
    var tracks: [MusicTrack] = []
    var albums: [MusicAlbum] = []
    var signals: [MusicDiscoverySignal] = []
    var genres: [String] = []
    var genreSource = MusicGenreSource.none
    var compilations: [SpotifyDiscoveryAlbum] = []
    var listenBrainzStatus = MusicListenBrainzStatus.off
}

extension SpotifyCacheStore {
    func createDiscoveryTables(_ db: SpotifyCacheDatabase) throws {
        for table in ["discovery_cache", "metabrainz_cache"] {
            try db.execute(
                "CREATE TABLE IF NOT EXISTS " + table
                    + " (key TEXT PRIMARY KEY, payload_json BLOB NOT NULL, expires_at REAL NOT NULL)"
            )
        }
        try db.execute(
            "CREATE TABLE IF NOT EXISTS play_history (id TEXT PRIMARY KEY, payload_json BLOB NOT NULL, played_at REAL NOT NULL)"
        )
    }

    func discovery(_ key: String) throws -> SpotifyDiscoveryData? {
        guard let data = try readDiscoveryBlob(key, table: "discovery_cache") else { return nil }
        return try? JSONDecoder().decode(SpotifyDiscoveryData.self, from: data)
    }
    func saveDiscovery(_ key: String, value: SpotifyDiscoveryData, session: UUID) throws {
        guard acceptsDiscoveryWrite(session) else { return }
        try writeDiscoveryBlob(
            key, data: JSONEncoder().encode(value), ttl: 86400, table: "discovery_cache")
    }
    func metaBrainz(_ key: String) throws -> Data? {
        try readDiscoveryBlob(key, table: "metabrainz_cache")
    }
    func saveMetaBrainz(_ key: String, data: Data, ttl: TimeInterval, session: UUID) throws {
        guard acceptsDiscoveryWrite(session) else { return }
        try writeDiscoveryBlob(key, data: data, ttl: ttl, table: "metabrainz_cache")
    }
    private func readDiscoveryBlob(_ key: String, table: String) throws -> Data? {
        let db = try open()
        try db.execute(
            "DELETE FROM " + table + " WHERE expires_at <= ?",
            [.number(now().timeIntervalSince1970)])
        return try db.rows("SELECT payload_json FROM " + table + " WHERE key = ?", [.text(key)])
            .first?.first ?? nil
    }
    private func writeDiscoveryBlob(_ key: String, data: Data, ttl: TimeInterval, table: String)
        throws
    {
        let db = try open()
        try db.execute(
            "INSERT OR REPLACE INTO " + table + " VALUES (?, ?, ?)",
            [.text(key), .blob(data), .number(now().addingTimeInterval(ttl).timeIntervalSince1970)])
        try db.execute(
            "DELETE FROM " + table + " WHERE expires_at <= ?",
            [.number(now().timeIntervalSince1970)])
        // Bound disk growth even when a user browses many seeds inside the TTL.
        try db.execute(
            "DELETE FROM " + table + " WHERE key IN (SELECT key FROM " + table
                + " ORDER BY expires_at DESC LIMIT -1 OFFSET 256)")
    }
    func playHistory() throws -> [MusicPlayHistoryEntry] {
        let db = try open()
        try pruneHistory(db)
        return try db.rows("SELECT payload_json FROM play_history ORDER BY played_at").compactMap {
            row in
            row.first.flatMap { $0 }.flatMap {
                try? JSONDecoder().decode(MusicPlayHistoryEntry.self, from: $0)
            }
        }
    }
    func recordPlay(_ row: MusicPlayHistoryEntry, session: UUID) throws {
        guard acceptsDiscoveryWrite(session) else { return }
        let db = try open()
        try db.execute(
            "INSERT OR REPLACE INTO play_history VALUES (?, ?, ?)",
            [
                .text(row.id.uuidString), .blob(JSONEncoder().encode(row)),
                .number(row.playedAt.timeIntervalSince1970),
            ])
        try pruneHistory(db)
    }
    private func pruneHistory(_ db: SpotifyCacheDatabase) throws {
        try db.execute(
            "DELETE FROM play_history WHERE played_at <= ?",
            [.number(now().addingTimeInterval(-180 * 86400).timeIntervalSince1970)])
        try db.execute(
            "DELETE FROM play_history WHERE id IN (SELECT id FROM play_history ORDER BY played_at DESC LIMIT -1 OFFSET 20000)"
        )
    }
    private func acceptsDiscoveryWrite(_ session: UUID) -> Bool {
        if activeSession == nil { activate(session) }
        return !destroyed && activeSession == session
    }
}

struct SpotifyMetaBrainzCache: MetaBrainzCache {
    let cache: SpotifyCacheStore
    let session: UUID
    func readMetaBrainz(_ key: String) async throws -> Data? { try await cache.metaBrainz(key) }
    func writeMetaBrainz(_ key: String, data: Data, ttl: TimeInterval) async throws {
        try await cache.saveMetaBrainz(key, data: data, ttl: ttl, session: session)
    }
}
