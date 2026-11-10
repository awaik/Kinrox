import CryptoKit
import Foundation
import MusicCore

struct SpotifyResourceState: Codable, Equatable, Sendable {
    var etag: String?
    var snapshotID: String?
    var isComplete = true
    var fetchedAt: Date
    var expiresAt: Date
    func isFresh(at date: Date) -> Bool { isComplete && expiresAt > date }
}

struct SpotifyCachedLibrary: Sendable {
    var library: LibrarySnapshot
    var catalog = MusicCatalog()
    var resources: [String: SpotifyResourceState] = [:]
}

/// Account-local metadata and listening history. SQL and encoding stay on this serial actor.
actor SpotifyCacheStore {
    static let retention: TimeInterval = 7 * 24 * 3600
    nonisolated let directory: URL
    nonisolated let clientID: String
    nonisolated let userID: String
    let displayName: String
    let now: @Sendable () -> Date
    private var database: SpotifyCacheDatabase?
    var destroyed = false
    private var committedRevision: UInt64 = 0
    var activeSession: UUID?
    private var storageGeneration: UInt64 = 0
    private var previous: SpotifyCacheSummary?

    init(
        clientID: String, userID: String, displayName: String,
        root: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clientID = clientID
        self.userID = userID
        self.displayName = displayName
        self.now = now
        let namespace = SHA256.hash(data: Data((clientID + ":" + userID).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let root =
            root
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.kinrox.player")
            .appendingPathComponent("Spotify/v1")
        directory = root.appendingPathComponent(namespace, isDirectory: true)
    }

    func restore() async throws -> SpotifyCachedLibrary {
        let db = try open()
        var value = try metadata(db)
        let generation = storageGeneration
        let batches = try db.catalogBatches(
            "SELECT kind, payload_json FROM catalog_entities ORDER BY rowid")
        value.catalog = try await SpotifyCacheDecoder.catalog(batches)
        guard !destroyed, database === db, storageGeneration == generation else {
            throw CancellationError()
        }
        let diskSummary = SpotifyCacheSummary(value)
        removeExpiredResources(from: &value)
        value = Self.pruned(value)
        let nextSummary = SpotifyCacheSummary(value)
        if diskSummary != nextSummary {
            previous = diskSummary
            try write(value, summary: nextSummary, to: db)
            storageGeneration &+= 1
        }
        previous = nextSummary
        return value
    }

    /// First render needs album navigation and the selected album, not every track's decoded metadata.
    /// This read-only projection never changes completeness on disk or replaces a complete snapshot.
    func preview() async throws -> SpotifyCachedLibrary {
        let db = try open()
        let generation = storageGeneration
        var value = try metadata(db)
        let summaries = try db.catalogBatches(
            "SELECT kind, payload_json FROM catalog_entities WHERE kind IN ('album', 'artist') ORDER BY rowid"
        )
        value.catalog = try await SpotifyCacheDecoder.catalog(summaries)
        guard !destroyed, database === db, storageGeneration == generation else {
            throw CancellationError()
        }
        if let album = value.catalog.albums.first(where: {
            value.library.savedAlbumIDs.contains($0.id)
        }) {
            var trackBatches = SpotifyCatalogBatches()
            for offset in stride(from: 0, to: album.trackIDs.count, by: 500) {
                let ids = Array(album.trackIDs[offset..<min(offset + 500, album.trackIDs.count)])
                let parameters = Array(repeating: "?", count: ids.count).joined(separator: ",")
                let batch = try db.catalogBatches(
                    "SELECT kind, payload_json FROM catalog_entities WHERE kind = 'track' AND id IN ("
                        + parameters + ")", ids.map(SpotifyCacheDatabase.Value.text))
                trackBatches.tracks += batch.tracks
            }
            let tracks = try await SpotifyCacheDecoder.catalog(trackBatches)
            guard !destroyed, database === db, storageGeneration == generation else {
                throw CancellationError()
            }
            value.catalog.merge(tracks: tracks.tracks)
        }
        removeExpiredResources(from: &value)
        return Self.pruned(value)
    }

    private func metadata(_ db: SpotifyCacheDatabase) throws -> SpotifyCachedLibrary {
        var value = SpotifyCachedLibrary(library: LibrarySnapshot(userID: userID))
        for row in try db.rows(
            "SELECT key, etag, snapshot_id, is_complete, fetched_at, expires_at FROM resource_state"
        ) {
            guard let key = text(row[0]), let fetched = number(row[4]) else { continue }
            value.resources[key] = SpotifyResourceState(
                etag: text(row[1]), snapshotID: text(row[2]), isComplete: text(row[3]) == "1",
                fetchedAt: Date(timeIntervalSince1970: fetched),
                expiresAt: Date(timeIntervalSince1970: number(row[5]) ?? 0))
        }
        for row in try db.rows("SELECT kind, ids_json FROM library_lists") {
            guard let key = text(row[0]), value.resources[key] != nil, let data = row[1] else {
                continue
            }
            let ids = try JSONDecoder().decode(Set<String>.self, from: data)
            switch key {
            case "liked": value.library.likedTrackIDs = ids
            case "albums": value.library.savedAlbumIDs = ids
            case "artists": value.library.followedArtistIDs = ids
            default: break
            }
        }
        if value.resources["playlists"] != nil {
            for row in try db.rows(
                "SELECT id, owner_id, collaborative, title, uri, snapshot_id, track_ids_json FROM playlists ORDER BY rowid"
            ) {
                guard let id = text(row[0]), let owner = text(row[1]), let title = text(row[3]),
                    let uri = text(row[4])
                else { continue }
                let complete = value.resources["playlist:" + id]?.isComplete == true
                let ids =
                    try complete ? JSONDecoder().decode([String].self, from: row[6] ?? Data()) : []
                value.library.playlists.append(
                    MusicPlaylist(
                        id: id, uri: uri, title: title, ownerID: owner,
                        collaborative: text(row[2]) == "1",
                        snapshotID: text(row[5]) ?? "", trackIDs: ids))
            }
        }
        return value
    }

    private func removeExpiredResources(from value: inout SpotifyCachedLibrary) {
        let cutoff = now().addingTimeInterval(-Self.retention)
        value.resources = value.resources.filter { $0.value.fetchedAt > cutoff }
        if value.resources["liked"] == nil { value.library.likedTrackIDs = [] }
        if value.resources["albums"] == nil { value.library.savedAlbumIDs = [] }
        if value.resources["artists"] == nil { value.library.followedArtistIDs = [] }
        if value.resources["playlists"] == nil { value.library.playlists = [] }
        for offset in value.library.playlists.indices {
            if value.resources["playlist:" + value.library.playlists[offset].id] == nil {
                value.library.playlists[offset].trackIDs = []
            }
        }
    }

    /// Revision ordering also protects disk if callers resume out of order after an await.
    func activate(_ session: UUID) {
        guard !destroyed, activeSession != session else { return }
        activeSession = session
        storageGeneration &+= 1
        committedRevision = 0
    }

    func save(_ snapshot: SpotifyCachedLibrary, revision: UInt64, session: UUID? = nil) throws {
        if let session, activeSession == nil { activate(session) }
        guard !destroyed, session == nil || activeSession == session, revision >= committedRevision
        else { return }
        let db = try open()
        let value = Self.pruned(snapshot)
        let summary = SpotifyCacheSummary(value)
        try write(value, summary: summary, to: db)
        committedRevision = revision
        storageGeneration &+= 1
        previous = summary
    }

    func destroyAccountCache() throws {
        destroyed = true
        storageGeneration &+= 1
        database?.close()
        database = nil
        previous = nil
        try removeDatabaseFiles()
        if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func open() throws -> SpotifyCacheDatabase {
        guard !destroyed else { throw CancellationError() }
        if let database { return database }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        do { return try connect() } catch {
            database?.close()
            database = nil
            try removeDatabaseFiles()
            return try connect()
        }
    }
    private func connect() throws -> SpotifyCacheDatabase {
        let db = try SpotifyCacheDatabase(url: directory.appendingPathComponent("library.sqlite"))
        do {
            guard try db.scalar("PRAGMA integrity_check") == "ok",
                ["0", "1"].contains(try db.scalar("PRAGMA user_version") ?? "")
            else {
                throw SpotifyCacheDatabase.Failure.sqlite(11)
            }
            try db.execute("BEGIN IMMEDIATE")
            try db.execute(
                "CREATE TABLE IF NOT EXISTS account_meta (namespace TEXT PRIMARY KEY, client_id TEXT, user_id TEXT, display_name TEXT, updated_at REAL)"
            )
            try db.execute(
                "CREATE TABLE IF NOT EXISTS resource_state (key TEXT PRIMARY KEY, etag TEXT, snapshot_id TEXT, is_complete INTEGER, fetched_at REAL, expires_at REAL)"
            )
            try db.execute(
                "CREATE TABLE IF NOT EXISTS library_lists (kind TEXT PRIMARY KEY, ids_json BLOB, updated_at REAL)"
            )
            try db.execute(
                "CREATE TABLE IF NOT EXISTS playlists (id TEXT PRIMARY KEY, owner_id TEXT, collaborative INTEGER, title TEXT, uri TEXT, snapshot_id TEXT, track_ids_json BLOB, is_complete INTEGER, updated_at REAL)"
            )
            try db.execute(
                "CREATE TABLE IF NOT EXISTS catalog_entities (kind TEXT, id TEXT, payload_json BLOB, updated_at REAL, PRIMARY KEY (kind, id))"
            )
            try createDiscoveryTables(db)
            let binding = try db.rows("SELECT client_id, user_id FROM account_meta")
            guard
                binding.isEmpty
                    || (binding.count == 1 && text(binding[0][0]) == clientID
                        && text(binding[0][1]) == userID)
            else {
                throw SpotifyCacheDatabase.Failure.sqlite(11)
            }
            try db.execute(
                "INSERT OR REPLACE INTO account_meta VALUES (?, ?, ?, ?, ?)",
                [
                    .text(directory.lastPathComponent), .text(clientID), .text(userID),
                    .text(displayName), .number(now().timeIntervalSince1970),
                ])
            try db.execute("PRAGMA user_version = 1")
            try db.execute("COMMIT")
            database = db
            return db
        } catch {
            try? db.execute("ROLLBACK")
            db.close()
            throw error
        }
    }
    private func removeDatabaseFiles() throws {
        // Only these files are owned by this service; never recursively delete arbitrary contents.
        for name in [
            "library.sqlite", "library.sqlite-wal", "library.sqlite-shm", "library.sqlite-journal",
        ] {
            let file = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
    private func text(_ data: Data?) -> String? {
        data.flatMap { String(data: $0, encoding: .utf8) }
    }
    private func number(_ data: Data?) -> Double? { text(data).flatMap(Double.init) }
}

extension SpotifyCacheStore {
    private static func pruned(_ value: SpotifyCachedLibrary) -> SpotifyCachedLibrary {
        var value = value
        let playlistIDs = Set(value.library.playlists.map(\.id))
        value.resources = value.resources.filter { key, _ in
            !key.hasPrefix("playlist:") || playlistIDs.contains(String(key.dropFirst(9)))
        }
        var trackIDs = value.library.likedTrackIDs
        for playlist in value.library.playlists { trackIDs.formUnion(playlist.trackIDs) }
        var albumIDs = value.library.savedAlbumIDs
        for album in value.catalog.albums {
            if value.resources["album:" + album.id] != nil
                || album.artists.contains(where: { value.resources["artist:" + $0.id] != nil })
            {
                albumIDs.insert(album.id)
            }
        }
        for track in value.catalog.tracks where trackIDs.contains(track.id) {
            albumIDs.insert(track.albumID)
        }
        let albums = value.catalog.albums.filter { albumIDs.contains($0.id) }.map { album in
            guard value.resources["album:" + album.id]?.isComplete != true else { return album }
            return MusicAlbum(
                id: album.id, uri: album.uri, title: album.title, artists: album.artists,
                year: album.year, trackIDs: [], totalTrackCount: album.totalTrackCount,
                releaseDate: album.releaseDate)
        }
        for album in albums { trackIDs.formUnion(album.trackIDs) }
        let tracks = value.catalog.tracks.filter { trackIDs.contains($0.id) }
        let artistIDs = value.library.followedArtistIDs
            .union(tracks.flatMap(\.artists).map(\.id)).union(albums.flatMap(\.artists).map(\.id))
        value.catalog = MusicCatalog(
            tracks: tracks, albums: albums,
            artists: value.catalog.artists.filter { artistIDs.contains($0.id) })
        return value
    }

    private func write(
        _ value: SpotifyCachedLibrary, summary: SpotifyCacheSummary, to db: SpotifyCacheDatabase
    ) throws {
        try db.execute("BEGIN IMMEDIATE")
        do {
            if previous == nil {
                for table in ["resource_state", "library_lists", "playlists", "catalog_entities"] {
                    try db.execute("DELETE FROM " + table)
                }
            }
            for key in previous?.resources.keys ?? [String: SpotifyResourceState]().keys
            where value.resources[key] == nil {
                try db.execute("DELETE FROM resource_state WHERE key = ?", [.text(key)])
            }
            for (key, state) in value.resources where previous?.resources[key] != state {
                try db.execute(
                    "INSERT OR REPLACE INTO resource_state VALUES (?, ?, ?, ?, ?, ?)",
                    [
                        .text(key), state.etag.map(SpotifyCacheDatabase.Value.text) ?? .null,
                        state.snapshotID.map(SpotifyCacheDatabase.Value.text) ?? .null,
                        .number(state.isComplete ? 1 : 0),
                        .number(state.fetchedAt.timeIntervalSince1970),
                        .number(state.expiresAt.timeIntervalSince1970),
                    ])
            }
            for (key, ids) in [
                ("liked", value.library.likedTrackIDs), ("albums", value.library.savedAlbumIDs),
                ("artists", value.library.followedArtistIDs),
            ] {
                try db.execute(
                    "INSERT OR REPLACE INTO library_lists VALUES (?, ?, ?)",
                    [
                        .text(key), .blob(try JSONEncoder().encode(ids.sorted())),
                        .number(value.resources[key]?.fetchedAt.timeIntervalSince1970 ?? 0),
                    ])
            }
            for id in previous?.playlists.keys ?? [String: UInt64]().keys
            where summary.playlists[id] == nil {
                try db.execute("DELETE FROM playlists WHERE id = ?", [.text(id)])
            }
            for playlist in value.library.playlists
            where previous?.playlists[playlist.id] != summary.playlists[playlist.id] {
                let resource = value.resources["playlist:" + playlist.id]
                try db.execute(
                    "INSERT OR REPLACE INTO playlists VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    [
                        .text(playlist.id), .text(playlist.ownerID),
                        .number(playlist.collaborative ? 1 : 0),
                        .text(playlist.title), .text(playlist.uri), .text(playlist.snapshotID),
                        .blob(try JSONEncoder().encode(playlist.trackIDs)),
                        .number(resource?.isComplete == true ? 1 : 0),
                        .number(
                            resource?.fetchedAt.timeIntervalSince1970 ?? now().timeIntervalSince1970
                        ),
                    ])
            }
            try entities(
                value.catalog.tracks, next: summary.tracks, old: previous?.tracks ?? [:],
                kind: "track", db: db)
            try entities(
                value.catalog.albums, next: summary.albums, old: previous?.albums ?? [:],
                kind: "album", db: db)
            try entities(
                value.catalog.artists, next: summary.artists, old: previous?.artists ?? [:],
                kind: "artist", db: db)
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }
    private func entities<T: Identifiable & Encodable>(
        _ values: [T], next: [String: UInt64], old: [String: UInt64],
        kind: String, db: SpotifyCacheDatabase
    ) throws where T.ID == String {
        for id in old.keys where next[id] == nil {
            try db.execute(
                "DELETE FROM catalog_entities WHERE kind = ? AND id = ?",
                [.text(kind), .text(id)])
        }
        for item in values where old[item.id] != next[item.id] {
            try db.execute(
                "INSERT OR REPLACE INTO catalog_entities VALUES (?, ?, ?, ?)",
                [
                    .text(kind), .text(item.id), .blob(try JSONEncoder().encode(item)),
                    .number(now().timeIntervalSince1970),
                ])
        }
    }
}
