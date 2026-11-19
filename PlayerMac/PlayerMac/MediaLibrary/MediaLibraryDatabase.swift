import Foundation
import SQLite3

actor MediaLibraryDatabase {
    private let location: URL
    private var connection: Connection?

    init(location: URL) { self.location = location }

    func db() throws -> Connection {
        if let connection { return connection }
        try FileManager.default.createDirectory(
            at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try Connection(location.path)
        let pageSize = try db.select("PRAGMA page_size") { $0.integer(0) }.first ?? 4096
        try db.run(
            """
            PRAGMA journal_mode=WAL;
            PRAGMA busy_timeout=2000;
            PRAGMA synchronous=NORMAL;
            PRAGMA mmap_size=0;
            PRAGMA cache_size=-2000;
            PRAGMA foreign_keys=ON;
            PRAGMA max_page_count=\(104_857_600 / max(1, pageSize));
            """)
        let version = try db.select("PRAGMA user_version") { $0.integer(0) }.first ?? 0
        guard version <= 1 else {
            throw Failure(message: "Media library schema is newer than this app.")
        }
        if version == 0 {
            try db.transaction {
                try db.run(
                    """
                    CREATE TABLE watched_folders (
                      id TEXT PRIMARY KEY, path TEXT UNIQUE NOT NULL, display_name TEXT NOT NULL,
                      bookmark BLOB, volume_uuid TEXT, is_removable INTEGER NOT NULL DEFAULT 0,
                      added_at REAL NOT NULL, last_scanned_at REAL, is_offline INTEGER NOT NULL DEFAULT 0
                    );
                    CREATE TABLE media_files (
                      id TEXT PRIMARY KEY, folder_id TEXT NOT NULL REFERENCES watched_folders(id) ON DELETE CASCADE,
                      path TEXT UNIQUE NOT NULL, kind TEXT NOT NULL, file_size INTEGER NOT NULL, mtime REAL NOT NULL,
                      added_at REAL NOT NULL, duration REAL, container_badge TEXT, codec_badge TEXT,
                      resolution_badge TEXT, hdr_badge TEXT, parsed_title TEXT NOT NULL, parsed_year INTEGER,
                      series_key TEXT, season_num INTEGER, episode_num INTEGER, artist TEXT, album TEXT,
                      album_key TEXT, track_num INTEGER, disc_num INTEGER, sample_rate INTEGER, bit_depth INTEGER,
                      is_lossless INTEGER NOT NULL DEFAULT 0, isrc TEXT, embedded_genres TEXT, embedded_rating REAL,
                      artwork_path TEXT, metadata_key TEXT, episode_details BLOB, album_artist TEXT
                    );
                    CREATE INDEX media_by_folder ON media_files(folder_id);
                    CREATE INDEX media_by_series ON media_files(kind,series_key,season_num,episode_num);
                    CREATE INDEX media_by_album ON media_files(kind,album_key,disc_num,track_num);
                    CREATE INDEX media_by_metadata ON media_files(metadata_key);
                    CREATE TABLE enrichment_cache (
                      metadata_key TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT, summary TEXT, rating REAL,
                      rating_source TEXT, year_text TEXT, genres_json TEXT NOT NULL, poster_url TEXT, poster_path TEXT,
                      episodes_json TEXT, fetched_at REAL NOT NULL, status TEXT NOT NULL
                    );
                    CREATE TABLE playback_progress (
                      path TEXT PRIMARY KEY, position REAL NOT NULL, duration REAL NOT NULL,
                      completed INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL
                    );
                    PRAGMA user_version=1;
                    """)
            }
        }
        connection = db
        return db
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    final class Connection {
        private let handle: OpaquePointer
        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        init(_ path: String) throws {
            var opened: OpaquePointer?
            let result = sqlite3_open_v2(
                path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
            guard result == SQLITE_OK, let opened else {
                if let opened { sqlite3_close(opened) }
                throw Failure(message: "Cannot open the media library.")
            }
            handle = opened
        }

        deinit { sqlite3_close(handle) }

        func run(_ sql: String) throws {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
        }

        func transaction<T>(_ work: () throws -> T) throws -> T {
            try run("BEGIN IMMEDIATE")
            do {
                let value = try work()
                try run("COMMIT")
                return value
            } catch {
                try? run("ROLLBACK")
                throw error
            }
        }

        func execute(_ sql: String, _ values: [Value]) throws {
            _ = try select(sql, values) { _ in () }
        }

        func select<T>(_ sql: String, _ values: [Value] = [], map: (Row) throws -> T) throws -> [T]
        {
            var opaque: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &opaque, nil) == SQLITE_OK, let opaque else {
                throw failure()
            }
            defer { sqlite3_finalize(opaque) }
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let result =
                    switch value {
                    case .text(let value):
                        sqlite3_bind_text(opaque, index, value, -1, Self.transient)
                    case .integer(let value): sqlite3_bind_int64(opaque, index, value)
                    case .real(let value): sqlite3_bind_double(opaque, index, value)
                    case .blob(let value):
                        value.withUnsafeBytes {
                            sqlite3_bind_blob(
                                opaque, index, $0.baseAddress, Int32($0.count), Self.transient)
                        }
                    case .null: sqlite3_bind_null(opaque, index)
                    }
                guard result == SQLITE_OK else { throw failure() }
            }
            var rows: [T] = []
            while true {
                switch sqlite3_step(opaque) {
                case SQLITE_DONE: return rows
                case SQLITE_ROW: rows.append(try map(Row(handle: opaque)))
                default: throw failure()
                }
            }
        }

        private func failure() -> Failure {
            Failure(message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    enum Value {
        case text(String)
        case integer(Int64)
        case real(Double)
        case blob(Data)
        case null
        static func string(_ value: String?) -> Self { value.map(Self.text) ?? .null }
        static func int(_ value: Int?) -> Self { value.map { .integer(Int64($0)) } ?? .null }
        static func number(_ value: Double?) -> Self { value.map(Self.real) ?? .null }
    }

    struct Row {
        let handle: OpaquePointer
        func text(_ i: Int32) -> String? {
            sqlite3_column_text(handle, i).map { String(cString: $0) }
        }
        func integer(_ i: Int32) -> Int64 { sqlite3_column_int64(handle, i) }
        func int(_ i: Int32) -> Int? {
            sqlite3_column_type(handle, i) == SQLITE_NULL ? nil : Int(integer(i))
        }
        func real(_ i: Int32) -> Double? {
            sqlite3_column_type(handle, i) == SQLITE_NULL ? nil : sqlite3_column_double(handle, i)
        }
        func blob(_ i: Int32) -> Data? {
            guard let bytes = sqlite3_column_blob(handle, i) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, i)))
        }
        func date(_ i: Int32) -> Date { Date(timeIntervalSince1970: real(i) ?? 0) }
    }
}
