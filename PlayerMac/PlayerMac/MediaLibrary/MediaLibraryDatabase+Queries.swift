import Foundation

extension MediaLibraryDatabase {
    struct Snapshot: Sendable {
        var folders: [WatchedFolder] = []
        var files: [MediaLibraryFile] = []
        var fileCounts: [UUID: Int] = [:]
        var offlinePaths: Set<String> = []
        var metadata: [String: MediaEnrichment] = [:]
        var progress: [String: WatchProgress] = [:]
    }

    struct Stamp: Equatable, Sendable {
        let size: Int64
        let modified: Date
    }

    func folders() throws -> [WatchedFolder] {
        try db().select(
            """
            SELECT id,path,display_name,volume_uuid,is_removable,is_offline
            FROM watched_folders ORDER BY added_at
            """
        ) { row in
            guard let id = row.text(0).flatMap(UUID.init(uuidString:)), let path = row.text(1)
            else {
                throw Failure(message: "Invalid watched folder record.")
            }
            return WatchedFolder(
                id: id, path: path, displayName: row.text(2) ?? path, volumeUUID: row.text(3),
                isRemovable: row.integer(4) != 0, isOffline: row.integer(5) != 0)
        }
    }

    func add(_ folder: WatchedFolder) throws -> UUID {
        let db = try db()
        return try db.transaction {
            let existing = try folders()
            // A remounted drive can still be marked offline until its next scan.
            if let parent = existing.first(where: {
                $0.path == folder.path
                    || (Self.contains($0.path, folder.path) && $0.volumeUUID == folder.volumeUUID
                        && (!$0.isOffline || folder.volumeUUID != nil || !$0.isRemovable))
            }) {
                return parent.id
            }
            try db.execute(
                """
                INSERT INTO watched_folders (id,path,display_name,volume_uuid,is_removable,added_at)
                VALUES (?,?,?,?,?,?)
                """,
                [
                    .text(folder.id.uuidString), .text(folder.path), .text(folder.displayName),
                    .string(folder.volumeUUID), .integer(folder.isRemovable ? 1 : 0),
                    .real(Date().timeIntervalSince1970),
                ])
            for child in existing
            where Self.contains(folder.path, child.path)
                && folder.volumeUUID == child.volumeUUID
            {
                try db.execute(
                    "UPDATE media_files SET folder_id=? WHERE folder_id=?",
                    [
                        .text(folder.id.uuidString), .text(child.id.uuidString),
                    ])
                try db.execute(
                    "DELETE FROM watched_folders WHERE id=?", [.text(child.id.uuidString)])
            }
            return folder.id
        }
    }

    private static func contains(_ parent: String, _ child: String) -> Bool {
        child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    func remove(_ folder: UUID) throws {
        try db().execute("DELETE FROM watched_folders WHERE id=?", [.text(folder.uuidString)])
    }

    func stamps(_ folder: UUID) throws -> [String: Stamp] {
        let existing = try db().select(
            "SELECT path,file_size,mtime FROM media_files WHERE folder_id=?",
            [.text(folder.uuidString)]
        ) { ($0.text(0) ?? "", Stamp(size: $0.integer(1), modified: $0.date(2))) }
        return Dictionary(uniqueKeysWithValues: existing)
    }

    func markOffline(_ folder: UUID) throws {
        try db().execute(
            "UPDATE watched_folders SET is_offline=1 WHERE id=?", [.text(folder.uuidString)])
    }

    func apply(
        _ changes: [MediaLibraryFile], folder: UUID, validate: @Sendable () -> Bool
    ) throws -> Bool {
        guard validate() else {
            try markOffline(folder)
            return false
        }
        let db = try db()
        do {
            try db.transaction {
                for file in changes {
                    let video = file.video
                    let audio = file.audio
                    let episode =
                        try video.map { Value.blob(try JSONEncoder().encode($0)) } ?? .null
                    try db.execute(
                        """
                        INSERT INTO media_files (
                          id,folder_id,path,kind,file_size,mtime,added_at,duration,container_badge,codec_badge,
                          resolution_badge,hdr_badge,parsed_title,parsed_year,series_key,season_num,episode_num,
                          artist,album,album_key,track_num,disc_num,sample_rate,bit_depth,is_lossless,isrc,
                          embedded_genres,embedded_rating,artwork_path,metadata_key,episode_details,album_artist)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        ON CONFLICT(path) DO UPDATE SET
                          kind=excluded.kind,file_size=excluded.file_size,mtime=excluded.mtime,duration=excluded.duration,
                          container_badge=excluded.container_badge,codec_badge=excluded.codec_badge,
                          resolution_badge=excluded.resolution_badge,hdr_badge=excluded.hdr_badge,
                          parsed_title=excluded.parsed_title,parsed_year=excluded.parsed_year,series_key=excluded.series_key,
                          season_num=excluded.season_num,episode_num=excluded.episode_num,artist=excluded.artist,
                          album=excluded.album,album_key=excluded.album_key,track_num=excluded.track_num,
                          disc_num=excluded.disc_num,sample_rate=excluded.sample_rate,bit_depth=excluded.bit_depth,
                          is_lossless=excluded.is_lossless,isrc=excluded.isrc,embedded_genres=excluded.embedded_genres,
                          embedded_rating=excluded.embedded_rating,artwork_path=excluded.artwork_path,
                          metadata_key=excluded.metadata_key,episode_details=excluded.episode_details,
                          album_artist=excluded.album_artist WHERE media_files.folder_id=excluded.folder_id
                        """,
                        [
                            .text(file.id), .text(folder.uuidString), .text(file.path),
                            .text(file.kind.rawValue),
                            .integer(file.size), .real(file.modified.timeIntervalSince1970),
                            .real(file.added.timeIntervalSince1970), .number(audio?.duration),
                            .text(file.container),
                            .string(video?.codec ?? audio?.codec), .string(video?.resolution),
                            .string(video?.hdr),
                            .text(file.title), .int(video?.year ?? audio?.year),
                            .string(file.seriesKey),
                            .int(video?.season), .int(video?.episodes.first),
                            .string(audio?.artist),
                            .string(audio?.album), .string(file.albumKey), .int(audio?.track),
                            .int(audio?.disc),
                            .int(audio?.sampleRate), .int(audio?.bitDepth),
                            .integer(audio?.isLossless == true ? 1 : 0),
                            .string(audio?.isrc),
                            .string(try audio.map { try Self.json($0.genres) }),
                            .number(audio?.rating), .string(audio?.artworkPath),
                            .string(file.metadataKey),
                            episode, .string(audio?.albumArtist),
                        ])
                }
                guard validate() else { throw ScanInterrupted.volumeUnavailable }
            }
            return true
        } catch ScanInterrupted.volumeUnavailable {
            try markOffline(folder)
            return false
        }
    }

    func finishScan(_ folder: UUID, missing: Set<String>, validate: @Sendable () -> Bool) throws
        -> Bool
    {
        guard validate() else {
            try markOffline(folder)
            return false
        }
        let db = try db()
        do {
            try db.transaction {
                for path in missing {
                    try db.execute(
                        "DELETE FROM media_files WHERE path=? AND folder_id=?",
                        [
                            .text(path), .text(folder.uuidString),
                        ])
                }
                guard validate() else { throw ScanInterrupted.volumeUnavailable }
                try db.execute(
                    "UPDATE watched_folders SET is_offline=0,last_scanned_at=? WHERE id=?",
                    [
                        .real(Date().timeIntervalSince1970), .text(folder.uuidString),
                    ])
            }
            return true
        } catch ScanInterrupted.volumeUnavailable {
            try markOffline(folder)
            return false
        }
    }

    private enum ScanInterrupted: Error { case volumeUnavailable }

    func snapshot() throws -> Snapshot {
        var result = Snapshot(folders: try folders())
        let rows = try db().select(
            """
            SELECT f.path,f.kind,f.file_size,f.mtime,f.added_at,f.duration,f.codec_badge,f.parsed_title,
              f.parsed_year,f.artist,f.album,f.track_num,f.disc_num,f.sample_rate,f.bit_depth,f.is_lossless,
              f.isrc,f.embedded_genres,f.embedded_rating,f.artwork_path,f.episode_details,f.album_artist,w.is_offline,w.id
            FROM media_files f JOIN watched_folders w ON w.id=f.folder_id
            """
        ) { row in
            var file = MediaLibraryFile(
                path: row.text(0) ?? "", size: row.integer(2), modified: row.date(3),
                added: row.date(4))
            if row.text(1) == "audio" {
                file.audio = LocalAudioTags(
                    title: row.text(7) ?? "", artist: row.text(9), album: row.text(10),
                    albumArtist: row.text(21), year: row.int(8), track: row.int(11),
                    disc: row.int(12),
                    duration: row.real(5), codec: row.text(6), sampleRate: row.int(13),
                    bitDepth: row.int(14),
                    isLossless: row.integer(15) != 0, isrc: row.text(16),
                    genres: Self.decode(row.text(17)) ?? [], rating: row.real(18),
                    artworkPath: row.text(19))
            } else if let data = row.blob(20) {
                file.video = try JSONDecoder().decode(VideoTitle.self, from: data)
            }
            return (file, row.integer(22) != 0, row.text(23).flatMap(UUID.init(uuidString:)))
        }
        result.files = rows.map(\.0)
        result.offlinePaths = Set(rows.filter(\.1).map { $0.0.path })
        for (_, _, id) in rows {
            if let id { result.fileCounts[id, default: 0] += 1 }
        }
        result.progress = Dictionary(
            uniqueKeysWithValues: try db().select(
                """
                SELECT path,position,duration,completed,updated_at FROM playback_progress
                """
            ) { row in
                let path = row.text(0) ?? ""
                return (
                    path,
                    WatchProgress(
                        path: path, position: row.real(1) ?? 0, duration: row.real(2) ?? 0,
                        completed: row.integer(3) != 0, updated: row.date(4))
                )
            })
        result.metadata = Dictionary(
            uniqueKeysWithValues: try db().select(
                """
                SELECT metadata_key,title,summary,rating,rating_source,year_text,genres_json,poster_url,
                    poster_path,episodes_json,fetched_at,status FROM enrichment_cache
                WHERE metadata_key IN (SELECT metadata_key FROM media_files)
                """
            ) { row in
                (
                    row.text(0) ?? "",
                    MediaEnrichment(
                        title: row.text(1), summary: row.text(2), rating: row.real(3),
                        source: row.text(4).flatMap(MediaEnrichment.Source.init(rawValue:)),
                        year: row.text(5), genres: Self.decode(row.text(6)) ?? [],
                        posterURL: row.text(7).flatMap(URL.init(string:)), posterPath: row.text(8),
                        episodes: Self.decode(row.text(9)) ?? [], fetched: row.date(10),
                        notFound: row.text(11) == "not_found")
                )
            })
        return result
    }

    func save(_ progress: WatchProgress) throws {
        try db().execute(
            """
            INSERT INTO playback_progress(path,position,duration,completed,updated_at) VALUES (?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET position=excluded.position,duration=excluded.duration,
              completed=excluded.completed,updated_at=excluded.updated_at
            WHERE excluded.updated_at >= playback_progress.updated_at
            """,
            [
                .text(progress.path), .real(progress.position), .real(progress.duration),
                .integer(progress.completed ? 1 : 0), .real(progress.updated.timeIntervalSince1970),
            ])
    }

    func save(_ metadata: MediaEnrichment, key: String, kind: MediaLibraryFile.Kind) throws {
        try db().execute(
            """
            INSERT OR REPLACE INTO enrichment_cache(
              metadata_key,kind,title,summary,rating,rating_source,year_text,genres_json,
              poster_url,poster_path,episodes_json,fetched_at,status) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [
                .text(key), .text(kind.rawValue), .string(metadata.title),
                .string(metadata.summary),
                .number(metadata.rating), .string(metadata.source?.rawValue),
                .string(metadata.year),
                .text(try Self.json(metadata.genres)), .string(metadata.posterURL?.absoluteString),
                .string(metadata.posterPath), .text(try Self.json(metadata.episodes)),
                .real(metadata.fetched.timeIntervalSince1970),
                .text(metadata.notFound ? "not_found" : "ready"),
            ])
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ value: String?) -> T? {
        value.flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }
}
