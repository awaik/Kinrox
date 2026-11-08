import Foundation
import SQLite3

struct SpotifyCatalogBatches: Sendable {
    var tracks: [Data] = []
    var albums: [Data] = []
    var artists: [Data] = []
}

/// Used exclusively by SpotifyCacheStore. The unchecked conformance permits actor teardown.
final class SpotifyCacheDatabase: @unchecked Sendable {
    enum Failure: Error { case sqlite(Int32) }
    enum Value {
        case text(String)
        case blob(Data)
        case number(Double)
        case null
    }
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        let result = sqlite3_open_v2(
            url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil)
        guard result == SQLITE_OK else {
            close()
            throw Failure.sqlite(result)
        }
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA busy_timeout = 2000")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
            try execute("PRAGMA mmap_size = 67108864")
            try execute("PRAGMA cache_size = -2000")
            try execute("PRAGMA temp_store = MEMORY")
            let pageSize = Int(try scalar("PRAGMA page_size") ?? "4096") ?? 4096
            let pageLimit = 100 * 1024 * 1024 / max(1, pageSize)
            try execute("PRAGMA max_page_count = \(pageLimit)")
            guard Int(try scalar("PRAGMA page_count") ?? "0") ?? 0 <= pageLimit else {
                throw Failure.sqlite(SQLITE_FULL)
            }
        } catch {
            close()
            throw error
        }

    }
    deinit { close() }
    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }
    func execute(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw Failure.sqlite(result) }
    }
    func rows(_ sql: String, _ values: [Value] = []) throws -> [[Data?]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [[Data?]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw Failure.sqlite(result) }
            rows.append(
                (0..<sqlite3_column_count(statement)).map { column in
                    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
                    return Data(bytes: bytes, count: count)
                })
        }
    }
    func scalar(_ sql: String) throws -> String? {
        try rows(sql).first?.first.flatMap { $0 }.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Streams catalog JSON payloads directly from SQLite's mmap pages into framed JSON array batches.
    func catalogBatches(_ sql: String, _ values: [Value] = [], batchRowLimit: Int = 512) throws
        -> SpotifyCatalogBatches
    {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        struct Builder {
            var current = Data()
            var count = 0
            var finished: [Data] = []
            mutating func append(_ bytes: UnsafeRawPointer, count byteCount: Int, limit: Int) {
                if count == 0 {
                    current = Data()
                    current.reserveCapacity(max(4096, byteCount * min(limit, 64)))
                    current.append(91)  // '['
                } else {
                    current.append(44)  // ','
                }
                current.append(bytes.assumingMemoryBound(to: UInt8.self), count: byteCount)
                count += 1
                if count >= limit { flush() }
            }
            mutating func flush() {
                guard count > 0 else { return }
                current.append(93)  // ']'
                finished.append(current)
                current = Data()
                count = 0
            }
        }
        var tracks = Builder()
        var albums = Builder()
        var artists = Builder()
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw Failure.sqlite(result) }
            guard let kindPtr = sqlite3_column_text(statement, 0),
                let blobPtr = sqlite3_column_blob(statement, 1)
            else { continue }
            let byteCount = Int(sqlite3_column_bytes(statement, 1))
            guard byteCount > 0 else { continue }
            if kindPtr[0] == 116 {  // "track"
                tracks.append(blobPtr, count: byteCount, limit: batchRowLimit)
            } else if kindPtr[0] == 97 && kindPtr[1] == 108 {  // "album"
                albums.append(blobPtr, count: byteCount, limit: batchRowLimit)
            } else if kindPtr[0] == 97 && kindPtr[1] == 114 {  // "artist"
                artists.append(blobPtr, count: byteCount, limit: batchRowLimit)
            }
        }
        tracks.flush()
        albums.flush()
        artists.flush()
        return SpotifyCatalogBatches(
            tracks: tracks.finished, albums: albums.finished, artists: artists.finished)
    }
    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw Failure.sqlite(result) }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch value {
                case .text(let text):
                    result = sqlite3_bind_text(statement, index, text, -1, transient)
                case .blob(let data):
                    result = data.withUnsafeBytes {
                        sqlite3_bind_blob(
                            statement, index, $0.baseAddress, Int32($0.count), transient)
                    }
                case .number(let number): result = sqlite3_bind_double(statement, index, number)
                case .null: result = sqlite3_bind_null(statement, index)
                }
                guard result == SQLITE_OK else { throw Failure.sqlite(result) }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }
}
