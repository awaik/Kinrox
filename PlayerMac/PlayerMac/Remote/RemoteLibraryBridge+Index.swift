import Foundation

extension RemoteLibraryBridge {
    struct FolderPrefix {
        let folder: WatchedFolder
        let canonical: String
        let prefix: String
    }

    struct IndexedVideo {
        let id: String
        let file: MediaLibraryFile
        let metadata: MediaEnrichment?
        let isOffline: Bool
        let folder: WatchedFolder?
        let title: String
        let subtitle: String?
        let year: Int?
        let genres: [String]
        let badges: [String]
    }

    struct IndexedEpisode {
        let id: String
        let video: IndexedVideo
        let season: Int
        let number: Int
        let title: String
        let label: String
    }

    struct IndexedSeries {
        let id: String
        let seriesKey: String
        let title: String
        let episodes: [IndexedEpisode]
        let seasons: [Int]
        let isOffline: Bool
        let folder: WatchedFolder?
        let posterPath: String?
        let added: Date
        let rating: Double?
        let year: Int?
        let genres: [String]
        let subtitle: String?
        let badges: [String]
    }

    struct IndexedTrack {
        let id: String
        let albumId: String?
        let track: LocalAudioTrack
        let folder: WatchedFolder?
        let subtitle: String?
        let year: Int?
        let badges: [String]
    }

    struct IndexedAlbum {
        let id: String
        let albumKey: String
        let title: String
        let trackIndices: [Int]
        let duration: Double?
        let isOffline: Bool
        let folder: WatchedFolder?
        let artworkPath: String?
        let added: Date
        let rating: Double?
        let year: Int?
        let genres: [String]
        let subtitle: String?
        let badges: [String]
    }

    enum Target {
        case movie(IndexedVideo)
        case series(IndexedSeries)
        case episode(IndexedEpisode, series: IndexedSeries)
        case album(IndexedAlbum)
        case track(IndexedTrack, album: IndexedAlbum?)
    }

    enum TargetRef {
        case movie(Int)
        case series(Int)
        case episode(series: Int, episode: Int)
        case album(Int)
        case track(track: Int, album: Int?)
    }

    enum PlayTarget {
        case movie(
            file: MediaLibraryFile, isOffline: Bool, folder: WatchedFolder?, isIndexed: Bool,
            fallbackProgressPath: String?)
        case series(IndexedSeries)
        case episode(IndexedEpisode, series: IndexedSeries)
        case album(IndexedAlbum, tracks: [IndexedTrack])
        case track(IndexedTrack, albumTracks: [IndexedTrack]?)
    }

    struct CatalogIndex {
        var folderCount = 0
        var movies: [IndexedVideo] = []
        var seriesGroups: [IndexedSeries] = []
        var albums: [IndexedAlbum] = []
        var tracks: [IndexedTrack] = []
        var byId: [String: TargetRef] = [:]
        var byPath: [String: TargetRef] = [:]

        func target(id: String) -> Target? { byId[id].map(resolve) }
        func target(path: String) -> Target? { byPath[path].map(resolve) }
        func tracks(for album: IndexedAlbum) -> [IndexedTrack] {
            album.trackIndices.map { tracks[$0] }
        }

        private func resolve(_ ref: TargetRef) -> Target {
            switch ref {
            case .movie(let idx): .movie(movies[idx])
            case .series(let idx): .series(seriesGroups[idx])
            case .episode(let s, let e):
                .episode(seriesGroups[s].episodes[e], series: seriesGroups[s])
            case .album(let idx): .album(albums[idx])
            case .track(let t, let a): .track(tracks[t], album: a.map { albums[$0] })
            }
        }
    }

    func buildIndex(from snap: MediaLibraryDatabase.Snapshot) -> CatalogIndex {
        let folderPrefixes: [FolderPrefix] = snap.folders.map { folder in
            let canonical = VideoFiles.key(folder.url)
            let prefix = canonical == "/" ? "/" : canonical + "/"
            return FolderPrefix(folder: folder, canonical: canonical, prefix: prefix)
        }.sorted { $0.canonical.count > $1.canonical.count }

        func matchedFolder(for path: String) -> WatchedFolder? {
            folderPrefixes.first { path == $0.canonical || path.hasPrefix($0.prefix) }?.folder
        }

        var next = CatalogIndex()
        next.folderCount = snap.folders.count
        next.byId.reserveCapacity(snap.files.count)
        next.byPath.reserveCapacity(snap.files.count)

        var albumCovers: [String: String] = [:]
        for file in snap.files {
            if let key = file.albumKey, let cover = file.audio?.artworkPath, albumCovers[key] == nil
            {
                albumCovers[key] = cover
            }
        }

        var seriesBuckets: [String: [IndexedEpisode]] = [:]
        var albumBuckets: [String: [Int]] = [:]
        var albumOrder: [String] = []

        for file in snap.files {
            let metadata = file.metadataKey.flatMap { snap.metadata[$0] }
            let offline = snap.offlinePaths.contains(file.path)
            let folder = matchedFolder(for: file.path)
            if file.kind == .video {
                let isEpisode = file.seriesKey != nil
                let id = ids.id(kind: isEpisode ? .episode : .movie, key: file.path)
                let video = makeIndexedVideo(
                    id: id, file: file, metadata: metadata, offline: offline, folder: folder)
                if let seriesKey = file.seriesKey {
                    let season = max(0, file.video?.season ?? 0)
                    let number = max(0, file.video?.episodes.first ?? 0)
                    let epTitle = episodeDisplayTitle(
                        file: file, metadata: metadata, season: season, number: number)
                    let label = String(format: "S%02dE%02d", season, number)
                    seriesBuckets[seriesKey, default: []].append(
                        IndexedEpisode(
                            id: id, video: video, season: season, number: number, title: epTitle,
                            label: label))
                } else {
                    let movieIndex = next.movies.count
                    next.movies.append(video)
                    let ref = TargetRef.movie(movieIndex)
                    next.byId[id] = ref
                    next.byPath[file.path] = ref
                }
            } else {
                let local = LocalAudioTrack(
                    file: file, metadata: metadata, isOffline: offline,
                    albumArtworkPath: file.albumKey.flatMap { albumCovers[$0] })
                let id = ids.id(kind: .track, key: file.path)
                let albumId = file.albumKey.map { ids.id(kind: .album, key: $0) }
                let parts = [local.artist, local.album].filter { !$0.isEmpty }
                let subtitle =
                    parts.isEmpty
                    ? nil : Self.truncateUTF8(parts.joined(separator: " · "), maxBytes: 2048)
                let year = Self.validYear(file.audio?.year) ?? Self.parseYear(metadata?.year)
                let badge = LocalAudioViewModel.formatBadge(for: local)
                let indexed = IndexedTrack(
                    id: id, albumId: albumId, track: local, folder: folder, subtitle: subtitle,
                    year: year, badges: badge.isEmpty ? [] : [badge])
                let trackIndex = next.tracks.count
                next.tracks.append(indexed)
                if let albumKey = file.albumKey {
                    if albumBuckets[albumKey] == nil { albumOrder.append(albumKey) }
                    albumBuckets[albumKey, default: []].append(trackIndex)
                } else {
                    let ref = TargetRef.track(track: trackIndex, album: nil)
                    next.byId[id] = ref
                    next.byPath[file.path] = ref
                }
            }
        }

        buildSeriesGroups(from: seriesBuckets, into: &next)
        buildAlbums(order: albumOrder, buckets: albumBuckets, into: &next)
        return next
    }

    private func buildSeriesGroups(
        from buckets: [String: [IndexedEpisode]], into next: inout CatalogIndex
    ) {
        for (seriesKey, rawEpisodes) in buckets {
            let episodes = rawEpisodes.sorted {
                if ($0.season, $0.number) == ($1.season, $1.number) {
                    return Self.alphabetical($0.video.file.path, $1.video.file.path)
                }
                return ($0.season, $0.number) < ($1.season, $1.number)
            }
            guard let first = episodes.first else { continue }
            let seriesId = ids.id(kind: .series, key: seriesKey)
            let group = IndexedSeries(
                id: seriesId, seriesKey: seriesKey, title: first.video.title, episodes: episodes,
                seasons: Set(episodes.map(\.season)).sorted(),
                isOffline: episodes.allSatisfy(\.video.isOffline),
                folder: episodes.first(where: { $0.video.isOffline })?.video.folder
                    ?? first.video.folder,
                posterPath: episodes.compactMap { $0.video.metadata?.posterPath }.first,
                added: episodes.map(\.video.file.added).max() ?? .distantPast,
                rating: first.video.metadata?.rating,
                year: first.video.year,
                genres: first.video.genres,
                subtitle: first.video.subtitle,
                badges: first.video.badges)
            next.seriesGroups.append(group)
        }
        next.seriesGroups.sort { Self.alphabetical($0.title, $1.title) }
        for (seriesIdx, group) in next.seriesGroups.enumerated() {
            next.byId[group.id] = .series(seriesIdx)
            for (epIdx, ep) in group.episodes.enumerated() {
                let ref = TargetRef.episode(series: seriesIdx, episode: epIdx)
                next.byId[ep.id] = ref
                next.byPath[ep.video.file.path] = ref
            }
        }
    }

    private func buildAlbums(
        order: [String], buckets: [String: [Int]], into next: inout CatalogIndex
    ) {
        for albumKey in order {
            guard let rawIndices = buckets[albumKey], !rawIndices.isEmpty else { continue }
            let sortedIndices = rawIndices.sorted { lhs, rhs in
                let first = next.tracks[lhs]
                let second = next.tracks[rhs]
                let a = (first.track.file.audio?.disc ?? 0, first.track.file.audio?.track ?? 0)
                let b = (second.track.file.audio?.disc ?? 0, second.track.file.audio?.track ?? 0)
                return a == b ? Self.alphabetical(first.track.title, second.track.title) : a < b
            }
            let tracks = sortedIndices.map { next.tracks[$0] }
            let first = tracks[0]
            let albumId = ids.id(kind: .album, key: albumKey)
            let durations = tracks.compactMap { $0.track.file.audio?.duration }.filter {
                $0.isFinite && $0 > 0
            }
            let artist = first.track.file.audio?.albumArtist ?? first.track.artist
            let genres = Array(first.track.genres.prefix(5)).map {
                Self.truncateUTF8($0, maxBytes: 128)
            }
            let subParts = ([artist] + genres).filter { !$0.isEmpty }
            var badges = first.badges
            if first.track.file.audio?.isLossless == true,
                !badges.contains(where: { $0.caseInsensitiveCompare("Lossless") == .orderedSame }),
                badges.count < 4
            {
                badges.append("Lossless")
            }
            let album = IndexedAlbum(
                id: albumId, albumKey: albumKey,
                title: Self.truncateUTF8(first.track.album, maxBytes: 2048),
                trackIndices: sortedIndices,
                duration: durations.isEmpty ? nil : durations.reduce(0, +),
                isOffline: tracks.allSatisfy(\.track.isOffline),
                folder: tracks.first(where: { $0.track.isOffline })?.folder ?? first.folder,
                artworkPath: tracks.compactMap(\.track.artworkPath).first,
                added: tracks.map(\.track.file.added).max() ?? .distantPast,
                rating: first.track.rating,
                year: first.year,
                genres: genres,
                subtitle: subParts.isEmpty
                    ? nil : Self.truncateUTF8(subParts.joined(separator: " · "), maxBytes: 2048),
                badges: badges)
            let albumIndex = next.albums.count
            next.albums.append(album)
            next.byId[albumId] = .album(albumIndex)
            for trackIndex in sortedIndices {
                let item = next.tracks[trackIndex]
                let ref = TargetRef.track(track: trackIndex, album: albumIndex)
                next.byId[item.id] = ref
                next.byPath[item.track.file.path] = ref
            }
        }
    }

    private func makeIndexedVideo(
        id: String, file: MediaLibraryFile, metadata: MediaEnrichment?, offline: Bool,
        folder: WatchedFolder?
    ) -> IndexedVideo {
        let title = Self.truncateUTF8(metadata?.title ?? file.title, maxBytes: 2048)
        let year = Self.parseYear(metadata?.year) ?? Self.validYear(file.video?.year)
        let genres = Array((metadata?.genres ?? []).prefix(5)).map {
            Self.truncateUTF8($0, maxBytes: 128)
        }
        let yearText = metadata?.year ?? Self.validYear(file.video?.year).map(String.init)
        let subParts = ([yearText].compactMap { $0 } + genres).filter { !$0.isEmpty }
        let subtitle =
            subParts.isEmpty
            ? nil : Self.truncateUTF8(subParts.joined(separator: " · "), maxBytes: 2048)
        return IndexedVideo(
            id: id, file: file, metadata: metadata, isOffline: offline, folder: folder,
            title: title, subtitle: subtitle, year: year, genres: genres,
            badges: Self.videoBadges(for: file))
    }

    private func episodeDisplayTitle(
        file: MediaLibraryFile, metadata: MediaEnrichment?, season: Int, number: Int
    ) -> String {
        if let match = metadata?.episodes.first(where: {
            $0.season == season && $0.number == number
        }) {
            return Self.truncateUTF8(match.title, maxBytes: 2048)
        }
        let raw = file.video?.episodeTitle ?? file.url.deletingPathExtension().lastPathComponent
        return Self.truncateUTF8(raw, maxBytes: 2048)
    }

    static func videoBadges(for file: MediaLibraryFile) -> [String] {
        var result: [String] = []
        if let res = file.video?.resolution, let hdr = file.video?.hdr {
            result.append("\(res) \(hdr)")
        } else if let res = file.video?.resolution {
            result.append(res)
        } else if let hdr = file.video?.hdr {
            result.append(hdr)
        }
        if let codec = file.video?.codec, !codec.isEmpty { result.append(codec) }
        if !file.container.isEmpty { result.append(file.container) }
        var seen: Set<String> = []
        return result.filter { seen.insert($0).inserted }.prefix(4).map {
            truncateUTF8($0, maxBytes: 64)
        }
    }
}
