import Foundation
import RemoteProtocol

extension RemoteLibraryBridge {
    func libraryPage(_ request: LibraryRequest, replyTo: UUID) -> Message {
        let idx = ensureIndex()
        let query = (request.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sort = request.sort ?? .title
        let all: [RemoteLibraryItem]
        switch request.section {
        case .continueWatching:
            all = continueWatchingItems(in: idx, query: query)
        case .videos:
            all = videoSectionItems(
                in: idx, kind: request.videoKind ?? .all, sort: sort, query: query)
        case .series:
            all = seriesSectionItems(in: idx, sort: sort, query: query)
        case .albums:
            all = albumSectionItems(in: idx, sort: sort, query: query)
        case .tracks:
            all = trackSectionItems(in: idx, sort: sort, query: query)
        case .children:
            guard let parentId = request.parentId,
                let children = childrenItems(in: idx, parentId: parentId, query: query)
            else {
                return .error(
                    .init(),
                    .init(
                        replyTo: replyTo, code: .itemNotFound,
                        message: RemoteServer.message(for: .itemNotFound)))
            }
            all = children
        }
        return pagedResponse(all: all, request: request, replyTo: replyTo)
    }

    func itemDetails(_ request: LibraryItemRequest, replyTo: UUID) -> Message {
        let idx = ensureIndex()
        let progressMap = store.snapshot.progress
        if let target = idx.target(id: request.id) {
            let item: RemoteLibraryItem
            let details: LibraryItemDetails
            switch target {
            case .movie(let video):
                item = movieItem(video, progress: progressMap[video.file.path])
                details = fileDetails(
                    file: video.file, metadata: video.metadata, folder: video.folder,
                    overview: video.metadata?.summary)
            case .series(let series):
                item = seriesItem(series)
                details = seriesDetails(series, progressMap: progressMap)
            case .episode(let episode, let series):
                item = episodeItem(
                    episode, series: series, progress: progressMap[episode.video.file.path])
                let epOverview =
                    episode.video.metadata?.episodes.first(where: {
                        $0.season == episode.season && $0.number == episode.number
                    })?.summary ?? episode.video.metadata?.summary
                details = fileDetails(
                    file: episode.video.file, metadata: episode.video.metadata,
                    folder: episode.video.folder, overview: epOverview)
            case .album(let album):
                item = albumItem(album)
                let meta = album.trackIndices.first.map { idx.tracks[$0].track.metadata } ?? nil
                details = LibraryItemDetails(
                    overview: meta?.summary.map { Self.truncateUTF8($0, maxBytes: 4096) },
                    ratingSource: meta?.source.map {
                        Self.truncateUTF8($0.rawValue, maxBytes: 64)
                    },
                    folderName: album.folder.map {
                        Self.truncateUTF8($0.displayName, maxBytes: 512)
                    })
            case .track(let track, _):
                item = trackItem(track)
                details = fileDetails(
                    file: track.track.file, metadata: track.track.metadata, folder: track.folder,
                    overview: track.track.metadata?.summary)
            }
            return validatedItemResponse(
                .libraryItem(
                    .init(),
                    .init(
                        replyTo: replyTo, revision: libraryRevision, item: item, details: details)),
                replyTo: replyTo)
        }
        if let adHoc = resolveAdHocRecent(id: request.id) {
            let progress = progressMap[adHoc.file.path]
            let item = adHocItem(adHoc.recent, file: adHoc.file, progress: progress)
            let details = fileDetails(file: adHoc.file, metadata: nil, folder: nil, overview: nil)
            return validatedItemResponse(
                .libraryItem(
                    .init(),
                    .init(
                        replyTo: replyTo, revision: libraryRevision, item: item, details: details)),
                replyTo: replyTo)
        }
        return .error(
            .init(),
            .init(
                replyTo: replyTo, code: .itemNotFound,
                message: RemoteServer.message(for: .itemNotFound)))
    }

    private func validatedItemResponse(_ message: Message, replyTo: UUID) -> Message {
        if let bytes = try? Codec.encode(message), bytes.count <= SecureChannel.maxPlaintextBytes {
            return message
        }
        return .error(
            .init(),
            .init(replyTo: replyTo, code: .internal, message: "Library item exceeds frame size."))
    }

    private func pagedResponse(
        all: [RemoteLibraryItem], request: LibraryRequest, replyTo: UUID
    ) -> Message {
        let revision =
            request.section == .continueWatching
                || (request.section == .videos && request.videoKind == .unwatched)
            ? progressPageRevision : libraryRevision
        let total = min(all.count, 100_000)
        let offset =
            request.revision == nil || request.revision == revision
            ? min(request.offset, total) : 0
        var count = min(50, total - offset)
        while true {
            let slice = Array(all.dropFirst(offset).prefix(count))
            let end = offset + slice.count
            let message = Message.library(
                .init(),
                .init(
                    replyTo: replyTo, revision: revision, section: request.section,
                    parentId: request.section == .children ? request.parentId : nil,
                    offset: offset, total: total, nextOffset: end < total ? end : nil,
                    items: slice))
            if let bytes = try? Codec.encode(message),
                bytes.count <= SecureChannel.maxPlaintextBytes
            {
                return message
            }
            guard count > 1 else {
                return .error(
                    .init(),
                    .init(
                        replyTo: replyTo, code: .internal,
                        message: "Library item exceeds frame size."))
            }
            count /= 2
        }
    }

    private func continueWatchingItems(in idx: CatalogIndex, query: String) -> [RemoteLibraryItem] {
        let progressMap = store.snapshot.progress
        var entries: [(Date, String, RemoteLibraryItem)] = []
        for movie in idx.movies where !movie.isOffline {
            guard let progress = progressMap[movie.file.path], !progress.completed else { continue }
            guard matchesQuery(query, fields: [movie.file.title, movie.title] + movie.genres) else {
                continue
            }
            entries.append((progress.updated, movie.title, movieItem(movie, progress: progress)))
        }
        for group in idx.seriesGroups {
            let available = group.episodes.filter { !$0.video.isOffline }
            guard let next = Self.nextEpisode(in: available, progress: progressMap),
                let updated = available.compactMap({ progressMap[$0.video.file.path]?.updated })
                    .max()
            else { continue }
            guard
                matchesQuery(
                    query, fields: [group.title, next.title, next.label] + group.genres)
            else { continue }
            entries.append(
                (
                    updated, group.title,
                    episodeItem(next, series: group, progress: progressMap[next.video.file.path])
                ))
        }
        var seenAdHoc: Set<String> = []
        for recent in recents.items where !recents.unavailable.contains(recent.id) {
            let path = VideoFiles.key(URL(fileURLWithPath: recent.path))
            guard idx.byPath[path] == nil, seenAdHoc.insert(path).inserted,
                let progress = progressMap[path], !progress.completed
            else { continue }
            guard matchesQuery(query, fields: [recent.title]) else { continue }
            let file = MediaLibraryFile(
                path: path, size: 0, modified: recent.openedAt, added: recent.openedAt,
                video: VideoTitle(title: recent.title))
            entries.append(
                (progress.updated, recent.title, adHocItem(recent, file: file, progress: progress)))
        }
        return entries.sorted {
            if $0.0 != $1.0 { return $0.0 > $1.0 }
            return Self.alphabetical($0.1, $1.1)
        }.map(\.2)
    }

    private func videoSectionItems(
        in idx: CatalogIndex, kind: RemoteLibraryVideoKind, sort: RemoteLibrarySort, query: String
    ) -> [RemoteLibraryItem] {
        let progressMap = store.snapshot.progress
        struct Row {
            let title: String
            let rating: Double
            let added: Date
            let item: RemoteLibraryItem
        }
        var rows: [Row] = []
        if kind != .series {
            for movie in idx.movies {
                let progress = progressMap[movie.file.path]
                if kind == .unwatched, progress?.completed == true { continue }
                guard matchesQuery(query, fields: [movie.file.title, movie.title] + movie.genres)
                else { continue }
                rows.append(
                    Row(
                        title: movie.title, rating: movie.metadata?.rating ?? -1,
                        added: movie.file.added, item: movieItem(movie, progress: progress)))
            }
        }
        if kind != .movies {
            for group in idx.seriesGroups {
                if kind == .unwatched,
                    !group.episodes.contains(where: {
                        progressMap[$0.video.file.path]?.completed != true
                    })
                {
                    continue
                }
                let epTitles = group.episodes.map(\.title)
                guard matchesQuery(query, fields: [group.title] + group.genres + epTitles) else {
                    continue
                }
                rows.append(
                    Row(
                        title: group.title, rating: group.rating ?? -1, added: group.added,
                        item: seriesItem(group)))
            }
        }
        return rows.sorted { a, b in
            switch sort {
            case .recent where a.added != b.added: return a.added > b.added
            case .rating where a.rating != b.rating: return a.rating > b.rating
            default: return Self.alphabetical(a.title, b.title)
            }
        }.map(\.item)
    }

    private func seriesSectionItems(
        in idx: CatalogIndex, sort: RemoteLibrarySort, query: String
    ) -> [RemoteLibraryItem] {
        idx.seriesGroups.filter { group in
            matchesQuery(query, fields: [group.title] + group.genres + group.episodes.map(\.title))
        }.sorted { a, b in
            switch sort {
            case .recent where a.added != b.added: return a.added > b.added
            case .rating where a.rating != b.rating: return (a.rating ?? -1) > (b.rating ?? -1)
            default: return Self.alphabetical(a.title, b.title)
            }
        }.map(seriesItem)
    }

    private func albumSectionItems(
        in idx: CatalogIndex, sort: RemoteLibrarySort, query: String
    ) -> [RemoteLibraryItem] {
        idx.albums.filter { album in
            let fields =
                [album.title, album.subtitle ?? ""] + album.genres
                + album.trackIndices.flatMap {
                    let t = idx.tracks[$0].track
                    return [t.title, t.artist]
                }
            return matchesQuery(query, fields: fields)
        }.sorted { a, b in
            switch sort {
            case .recent where a.added != b.added: return a.added > b.added
            case .rating where a.rating != b.rating: return (a.rating ?? -1) > (b.rating ?? -1)
            default: return Self.alphabetical(a.title, b.title)
            }
        }.map(albumItem)
    }

    private func trackSectionItems(
        in idx: CatalogIndex, sort: RemoteLibrarySort, query: String
    ) -> [RemoteLibraryItem] {
        idx.tracks.filter { entry in
            matchesQuery(
                query,
                fields: [entry.track.title, entry.track.artist, entry.track.album]
                    + entry.track.genres)
        }.sorted { a, b in
            switch sort {
            case .recent where a.track.file.added != b.track.file.added:
                return a.track.file.added > b.track.file.added
            case .rating where a.track.rating != b.track.rating:
                return (a.track.rating ?? -1) > (b.track.rating ?? -1)
            default:
                if a.track.album != b.track.album {
                    return Self.alphabetical(a.track.album, b.track.album)
                }
                let firstOrder = (
                    a.track.file.audio?.disc ?? 0, a.track.file.audio?.track ?? 0
                )
                let secondOrder = (
                    b.track.file.audio?.disc ?? 0, b.track.file.audio?.track ?? 0
                )
                return firstOrder == secondOrder
                    ? Self.alphabetical(a.track.title, b.track.title)
                    : firstOrder < secondOrder
            }
        }.map(trackItem)
    }

    private func childrenItems(
        in idx: CatalogIndex, parentId: String, query: String
    ) -> [RemoteLibraryItem]? {
        guard let target = idx.target(id: parentId) else { return nil }
        let progressMap = store.snapshot.progress
        switch target {
        case .series(let series):
            return series.episodes.filter { ep in
                matchesQuery(query, fields: [ep.title, ep.label, series.title])
            }.map { episodeItem($0, series: series, progress: progressMap[$0.video.file.path]) }
        case .album(let album):
            return idx.tracks(for: album).filter { entry in
                matchesQuery(query, fields: [entry.track.title, entry.track.artist, album.title])
            }.map(trackItem)
        default:
            return nil
        }
    }

    private func movieItem(_ video: IndexedVideo, progress: WatchProgress?) -> RemoteLibraryItem {
        let (rating, scale) = clampedRating(video.metadata?.rating, scale: 10)
        return RemoteLibraryItem(
            id: video.id, kind: .movie, title: video.title, subtitle: video.subtitle,
            year: video.year, rating: rating, ratingScale: scale, genres: video.genres,
            badges: video.badges, duration: validDuration(progress?.duration),
            progress: remoteProgress(progress),
            folderName: video.folder.map { Self.truncateUTF8($0.displayName, maxBytes: 512) },
            offline: video.isOffline, artwork: video.metadata?.posterPath != nil)
    }

    private func adHocItem(
        _ recent: RecentItem, file: MediaLibraryFile, progress: WatchProgress?
    ) -> RemoteLibraryItem {
        RemoteLibraryItem(
            id: ids.id(kind: .movie, key: file.path), kind: .movie,
            title: Self.truncateUTF8(recent.title, maxBytes: 2048),
            badges: Self.videoBadges(for: file),
            duration: validDuration(recent.duration ?? progress?.duration),
            progress: remoteProgress(progress), offline: false, artwork: false)
    }

    private func seriesItem(_ series: IndexedSeries) -> RemoteLibraryItem {
        let (rating, scale) = clampedRating(series.rating, scale: 10)
        return RemoteLibraryItem(
            id: series.id, kind: .series, title: series.title, subtitle: series.subtitle,
            year: series.year, rating: rating, ratingScale: scale, genres: series.genres,
            badges: series.badges, childCount: Self.clampCount(series.episodes.count),
            folderName: series.folder.map { Self.truncateUTF8($0.displayName, maxBytes: 512) },
            offline: series.isOffline, artwork: series.posterPath != nil)
    }

    private func episodeItem(
        _ episode: IndexedEpisode, series: IndexedSeries, progress: WatchProgress?
    ) -> RemoteLibraryItem {
        let (rating, scale) = clampedRating(episode.video.metadata?.rating, scale: 10)
        return RemoteLibraryItem(
            id: episode.id, kind: .episode, title: episode.title, subtitle: series.title,
            episodeLabel: Self.truncateUTF8(episode.label, maxBytes: 64),
            season: episode.season, episode: episode.number, year: episode.video.year,
            rating: rating, ratingScale: scale, genres: episode.video.genres,
            badges: episode.video.badges, duration: validDuration(progress?.duration),
            progress: remoteProgress(progress),
            folderName: episode.video.folder.map {
                Self.truncateUTF8($0.displayName, maxBytes: 512)
            },
            offline: episode.video.isOffline,
            artwork: (episode.video.metadata?.posterPath ?? series.posterPath) != nil)
    }

    private func albumItem(_ album: IndexedAlbum) -> RemoteLibraryItem {
        let (rating, scale) = clampedRating(album.rating, scale: 5)
        return RemoteLibraryItem(
            id: album.id, kind: .album, title: album.title, subtitle: album.subtitle,
            year: album.year, rating: rating, ratingScale: scale, genres: album.genres,
            badges: album.badges, duration: validDuration(album.duration),
            childCount: Self.clampCount(album.trackIndices.count),
            folderName: album.folder.map { Self.truncateUTF8($0.displayName, maxBytes: 512) },
            offline: album.isOffline, artwork: album.artworkPath != nil)
    }

    private func trackItem(_ entry: IndexedTrack) -> RemoteLibraryItem {
        let (rating, scale) = clampedRating(entry.track.rating, scale: 5)
        let genres = Array(entry.track.genres.prefix(5)).map {
            Self.truncateUTF8($0, maxBytes: 128)
        }
        let trackNumber = entry.track.file.audio?.track.flatMap { $0 >= 0 ? $0 : nil }
        return RemoteLibraryItem(
            id: entry.id, kind: .track,
            title: Self.truncateUTF8(entry.track.title, maxBytes: 2048),
            subtitle: entry.subtitle, trackNumber: trackNumber,
            year: entry.year, rating: rating, ratingScale: scale, genres: genres,
            badges: entry.badges, duration: validDuration(entry.track.file.audio?.duration),
            folderName: entry.folder.map { Self.truncateUTF8($0.displayName, maxBytes: 512) },
            offline: entry.track.isOffline, artwork: entry.track.artworkPath != nil)
    }

    private func fileDetails(
        file: MediaLibraryFile, metadata: MediaEnrichment?, folder: WatchedFolder?,
        overview: String?
    ) -> LibraryItemDetails {
        let rawName = file.url.lastPathComponent
        let fileName =
            (!rawName.isEmpty && !rawName.contains("/"))
            ? Self.truncateUTF8(rawName, maxBytes: 1024) : nil
        let (audio, subtitles) = loadedTrackLanguages(for: file.path)
        return LibraryItemDetails(
            overview: overview.map { Self.truncateUTF8($0, maxBytes: 4096) },
            ratingSource: metadata?.source.map { Self.truncateUTF8($0.rawValue, maxBytes: 64) },
            fileName: fileName,
            folderName: folder.map { Self.truncateUTF8($0.displayName, maxBytes: 512) },
            audioLanguages: audio,
            subtitleLanguages: subtitles)
    }

    private func seriesDetails(
        _ series: IndexedSeries, progressMap: [String: WatchProgress]
    ) -> LibraryItemDetails {
        let meta = series.episodes.first?.video.metadata
        let watched = series.episodes.filter { progressMap[$0.video.file.path]?.completed == true }
            .count
        let available = series.episodes.filter { !$0.video.isOffline }
        let pool = available.isEmpty ? series.episodes : available
        let next = Self.nextEpisode(in: pool, progress: progressMap) ?? pool.first
        return LibraryItemDetails(
            overview: meta?.summary.map { Self.truncateUTF8($0, maxBytes: 4096) },
            ratingSource: meta?.source.map { Self.truncateUTF8($0.rawValue, maxBytes: 64) },
            folderName: series.folder.map { Self.truncateUTF8($0.displayName, maxBytes: 512) },
            seasons: Array(series.seasons.filter { $0 >= 0 }.prefix(200)),
            watchedCount: Self.clampCount(watched),
            nextEpisodeId: next?.id)
    }

    private func loadedTrackLanguages(for path: String) -> ([String], [String]) {
        guard currentVideoPath() == path else { return ([], []) }
        let tracks = currentVideoTracks()
        func collect(_ kind: MediaTrackKind, limit: Int) -> [String] {
            var seen: Set<String> = []
            var result: [String] = []
            for track in tracks where track.kind == kind {
                let raw =
                    (!track.language.isEmpty && track.language != "und")
                    ? track.language : track.title
                let clean = Self.truncateUTF8(
                    raw.trimmingCharacters(in: .whitespacesAndNewlines), maxBytes: 64)
                guard !clean.isEmpty, seen.insert(clean).inserted else { continue }
                result.append(clean)
                if result.count == limit { break }
            }
            return result
        }
        return (collect(.audio, limit: 32), collect(.subtitle, limit: 64))
    }

    private func clampedRating(_ value: Double?, scale: Int) -> (Double?, Int?) {
        guard let value, value.isFinite, value >= 0 else { return (nil, nil) }
        return (min(Double(scale), value), scale)
    }

    private func validDuration(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func remoteProgress(_ progress: WatchProgress?) -> RemoteWatchProgress? {
        guard let progress, progress.position.isFinite, progress.duration.isFinite else {
            return nil
        }
        return RemoteWatchProgress(
            position: max(0, progress.position), duration: max(0, progress.duration),
            completed: progress.completed)
    }

    private func matchesQuery(_ query: String, fields: [String]) -> Bool {
        query.isEmpty || fields.contains { $0.localizedStandardContains(query) }
    }
}
