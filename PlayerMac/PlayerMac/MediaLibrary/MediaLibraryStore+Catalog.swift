import Foundation

extension MediaLibraryStore {
    var videoItems: [LocalVideoItem] {
        snapshot.files.compactMap { file in
            guard file.kind == .video else { return nil }
            return LocalVideoItem(
                file: file, metadata: file.metadataKey.flatMap { snapshot.metadata[$0] },
                progress: snapshot.progress[file.path],
                isOffline: snapshot.offlinePaths.contains(file.path))
        }
    }

    var audioTracks: [LocalAudioTrack] {
        var covers: [String: String] = [:]
        for file in snapshot.files {
            if let key = file.albumKey, let cover = file.audio?.artworkPath, covers[key] == nil {
                covers[key] = cover
            }
        }
        return snapshot.files.compactMap { file in
            guard file.kind == .audio else { return nil }
            return LocalAudioTrack(
                file: file, metadata: file.metadataKey.flatMap { snapshot.metadata[$0] },
                isOffline: snapshot.offlinePaths.contains(file.path),
                albumArtworkPath: file.albumKey.flatMap { covers[$0] })
        }
    }

    var catalogGenres: [String] {
        let values =
            videoItems.flatMap { $0.metadata?.genres ?? [] } + audioTracks.flatMap(\.genres)
        let grouped = Dictionary(grouping: values, by: MediaLibraryFile.normalized)
        return grouped.values.compactMap(\.first).sorted(by: Self.alphabetical)
    }

    func series(in items: [LocalVideoItem]) -> [LocalSeriesGroup] {
        let groups = Dictionary(
            grouping: items.compactMap { video in
                video.file.seriesKey.map { ($0, LocalEpisodeItem(video: video)) }
            }, by: \.0)
        return groups.compactMap { key, values in
            let episodes = values.map(\.1).sorted {
                if ($0.season, $0.number) == ($1.season, $1.number) {
                    return Self.alphabetical($0.video.file.path, $1.video.file.path)
                }
                return ($0.season, $0.number) < ($1.season, $1.number)
            }
            guard let first = episodes.first else { return nil }
            return LocalSeriesGroup(
                id: key, title: first.video.metadata?.title ?? first.video.file.title,
                episodes: episodes)
        }.sorted { Self.alphabetical($0.title, $1.title) }
    }

    func albums(in tracks: [LocalAudioTrack]) -> [LocalAudioAlbum] {
        let groups = Dictionary(
            grouping: tracks.filter { $0.file.albumKey != nil }, by: \.file.albumKey)
        var seen: Set<String> = []
        return tracks.compactMap { track in
            guard let key = track.file.albumKey, seen.insert(key).inserted, let tracks = groups[key]
            else { return nil }
            return LocalAudioAlbum(
                id: key,
                tracks: tracks.sorted {
                    let first = ($0.file.audio?.disc ?? 0, $0.file.audio?.track ?? 0)
                    let second = ($1.file.audio?.disc ?? 0, $1.file.audio?.track ?? 0)
                    return first == second ? Self.alphabetical($0.title, $1.title) : first < second
                })
        }
    }

    func filteredVideo(_ filter: HomeFilterState) -> [LocalVideoItem] {
        videoItems.filter { item in
            switch filter.videoKind {
            case .movies: guard item.file.seriesKey == nil else { return false }
            case .series: guard item.file.seriesKey != nil else { return false }
            case .unwatched: guard item.progress?.completed != true else { return false }
            case .all: break
            }
            if filter.ultraHD, item.file.video?.resolution != "4K" || item.file.video?.hdr == nil {
                return false
            }
            if filter.videoMinimumRating, (item.metadata?.rating ?? 0) < 8 { return false }
            let genres = item.metadata?.genres ?? []
            return Self.matches(
                filter, genres: genres,
                fields: [
                    item.file.title, item.metadata?.title ?? "",
                    item.file.video?.episodeTitle ?? "",
                    item.metadata?.episodes.first(where: {
                        $0.season == item.file.video?.season
                            && $0.number == item.file.video?.episodes.first
                    })?.title ?? "",
                ])
        }.sorted { first, second in
            switch filter.sort {
            case .recent where first.file.added != second.file.added:
                return first.file.added > second.file.added
            case .rating where first.metadata?.rating != second.metadata?.rating:
                return (first.metadata?.rating ?? -1) > (second.metadata?.rating ?? -1)
            default:
                return Self.alphabetical(
                    first.metadata?.title ?? first.file.title,
                    second.metadata?.title ?? second.file.title)
            }
        }
    }

    func filteredTracks(_ filter: HomeFilterState) -> [LocalAudioTrack] {
        audioTracks.filter { track in
            if filter.lossless, track.file.audio?.isLossless != true { return false }
            if filter.audioMinimumRating, (track.rating ?? 0) < 4 { return false }
            return Self.matches(
                filter, genres: track.genres, fields: [track.title, track.artist, track.album])
        }.sorted { first, second in
            switch filter.sort {
            case .recent where first.file.added != second.file.added:
                return first.file.added > second.file.added
            case .rating where first.rating != second.rating:
                return (first.rating ?? -1) > (second.rating ?? -1)
            default:
                if first.album != second.album {
                    return Self.alphabetical(first.album, second.album)
                }
                let firstOrder = (first.file.audio?.disc ?? 0, first.file.audio?.track ?? 0)
                let secondOrder = (second.file.audio?.disc ?? 0, second.file.audio?.track ?? 0)
                return firstOrder == secondOrder
                    ? Self.alphabetical(first.title, second.title) : firstOrder < secondOrder
            }
        }
    }

    func continueWatching() -> [LocalVideoItem] {
        let available = videoItems.filter { !$0.isOffline }
        let movies = available.filter {
            $0.file.seriesKey == nil && $0.progress?.completed == false
        }
        let groups = series(in: available)
        let resumes = groups.compactMap { group -> (Date, LocalVideoItem)? in
            guard let next = group.next,
                let updated = group.episodes.compactMap({ $0.video.progress?.updated }).max()
            else { return nil }
            return (updated, next.video)
        }
        return (movies.map { ($0.progress?.updated ?? .distantPast, $0) } + resumes)
            .sorted { $0.0 > $1.0 }.map(\.1)
    }

    private nonisolated static func matches(
        _ filter: HomeFilterState, genres: [String], fields: [String]
    ) -> Bool {
        if let genre = filter.genre,
            !genres.contains(where: { $0.caseInsensitiveCompare(genre) == .orderedSame })
        {
            return false
        }
        let query = filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || (fields + genres).contains { $0.localizedStandardContains(query) }
    }

    private nonisolated static func alphabetical(_ first: String, _ second: String) -> Bool {
        first.localizedStandardCompare(second) == .orderedAscending
    }
}
