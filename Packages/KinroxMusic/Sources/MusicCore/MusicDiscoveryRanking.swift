import Foundation

public enum MusicDiscoveryEngine {
    public static func build(
        seedTitle: String = "", seedTrackIDs: Set<String> = [], seedArtistIDs: Set<String> = [],
        seedArtistName: String = "", mode: MusicDiscoveryMode = .sameSpirit,
        genres: [String] = [], genreSource: MusicGenreSource = .spotify,
        selectedGenre: String? = nil, hideLiked: Bool = true,
        catalog: MusicCatalog, library: LibrarySnapshot,
        compilationAlbums: [(album: MusicAlbum, tracks: [MusicTrack])] = [],
        undergroundTracks: [MusicTrack] = [], freshTracks: [MusicTrack] = [],
        operatorTracks: [MusicTrack] = [], signals: [MusicDiscoverySignal] = [],
        artistGenres: [String: [String]] = [:],
        history: [MusicPlayHistoryEntry] = [], notInterestedTrackIDs: Set<String> = [],
        notInterestedArtistIDs: Set<String> = [], now: Date = Date()
    ) -> MusicDiscoverySnapshot {
        var identities = DiscoveryIdentityIndex()
        let seedIDs =
            seedTrackIDs.isEmpty && seedArtistIDs.isEmpty ? library.likedTrackIDs : seedTrackIDs
        let seeds = seedIDs.sorted().compactMap { catalog.track(id: $0) }
        let seedTokens = Set(seeds.flatMap { identities.identity($0).recordingTokens })
        let artistIDs =
            seedArtistIDs.isEmpty
            ? Set(seeds.flatMap(\.artists).map(\.id)).union(
                seedTrackIDs.isEmpty ? library.followedArtistIDs : [])
            : seedArtistIDs
        let artistNames = Set(
            seeds.flatMap(\.artists).map { identities.normalized($0.name) }
        )
        .union(
            artistIDs.compactMap { catalog.artist(id: $0) }.map {
                identities.normalized($0.name)
            }
        )
        .union(seedArtistName.isEmpty ? [] : [MusicDiscoveryIdentity.normalized(seedArtistName)])
        let local = localSignals(
            seedIDs: seedIDs, artistIDs: artistIDs, catalog: catalog, library: library)
        var inputs = signals + local.signals
        for (album, tracks) in compilationAlbums {
            inputs += tracks.filter {
                !identities.identity($0).sharesArtist(ids: artistIDs, names: artistNames)
                    && !identities.identity($0).isVarious
            }
            .map { .init(track: $0, kind: .compilation, detail: album.title) }
        }
        for (kind, tracks) in [
            (MusicDiscoveryReasonKind.underground, undergroundTracks), (.freshRelease, freshTracks),
        ] {
            inputs += tracks.enumerated().map {
                .init(
                    track: $0.element, kind: kind, detail: $0.element.albumTitle,
                    strength: max(0.5, 1 - Double($0.offset) * 0.03))
            }
        }
        if let genre = selectedGenre ?? genres.first {
            let normalizedGenre = MusicDiscoveryIdentity.normalized(genre)
            let genreArtists = Set(
                artistGenres.compactMap { id, genres in
                    genres.contains { MusicDiscoveryIdentity.normalized($0) == normalizedGenre }
                        ? id : nil
                })
            inputs += operatorTracks.enumerated().map {
                .init(
                    track: $0.element, kind: .sharedGenre, detail: genre,
                    strength: max(0.5, 1 - Double($0.offset) * 0.03))
            }
            inputs += catalog.tracks.filter { track in
                track.artists.contains { genreArtists.contains($0.id) }
            }.map { .init(track: $0, kind: .sharedGenre, detail: genre) }
        }
        let retainedHistory = MusicPlayHistoryEntry.retained(history, now: now)
        struct CompletedTrack: Hashable {
            let session: UUID
            let track: String
        }
        let completed = Set(
            retainedHistory.filter(\.completed).map {
                CompletedTrack(session: $0.sessionID, track: $0.trackID)
            })
        for row in retainedHistory where row.completed {
            if let previous = row.previousTrackID, seedIDs.contains(previous),
                let track = catalog.track(id: row.trackID)
            {
                inputs.append(.init(track: track, kind: .playHistory))
            } else if seedIDs.contains(row.trackID), let previous = row.previousTrackID,
                completed.contains(CompletedTrack(session: row.sessionID, track: previous)),
                let track = catalog.track(id: previous)
            {
                inputs.append(.init(track: track, kind: .playHistory))
            }
        }
        let skipped = Dictionary(
            grouping: retainedHistory.filter { $0.skipped && $0.playedSeconds < 30 }, by: \.trackID)
        let recent = Set(
            retainedHistory.filter {
                $0.completed && now.timeIntervalSince($0.playedAt) < 14 * 86400
            }.map(\.trackID))
        var candidates: [String: [MusicDiscoverySignal]] = [:]
        for signal in inputs {
            let track = signal.track
            guard signal.strength > 0, track.isPlayable != false, !seedIDs.contains(track.id),
                !(hideLiked && library.likedTrackIDs.contains(track.id)),
                !notInterestedTrackIDs.contains(track.id),
                !track.artists.contains(where: { notInterestedArtistIDs.contains($0.id) }),
                skipped[track.id, default: []].count < 2,
                seedTokens.isDisjoint(with: identities.identity(track).recordingTokens)
            else { continue }
            candidates[track.id, default: []].append(signal)
        }
        let knownArtists = library.followedArtistIDs
            .union(
                catalog.tracks.filter { library.likedTrackIDs.contains($0.id) }.flatMap(\.artists)
                    .map(\.id)
            )
            .union(
                catalog.albums.filter { library.savedAlbumIDs.contains($0.id) }.flatMap(\.artists)
                    .map(\.id))
        let scored: [(item: MusicDiscoveryItem, signals: [MusicDiscoverySignal])] = candidates
            .values.map { values in
                let merged = mergeSignals(values)
                let track = merged[0].track
                var score = merged.reduce(0) { $0 + $1.contribution }
                if identities.identity(track).sharesArtist(ids: artistIDs, names: artistNames) {
                    score *= 0.35
                }
                if recent.contains(track.id) { score *= 0.5 }
                if mode == .underground, knownArtists.isDisjoint(with: track.artists.map(\.id)),
                    values.contains(where: { $0.lowerHalf || $0.reason.kind == .underground })
                {
                    score *= 1.35
                }
                if mode == .fresh,
                    values.contains(where: { $0.reason.kind == .freshRelease })
                        || isFresh(track, catalog: catalog, now: now)
                {
                    score *= 1.35
                }
                return (
                    MusicDiscoveryItem(track: track, reasons: merged.map(\.reason), score: score),
                    merged
                )
            }
        // Sort compact indices instead of repeatedly copying full tracks and signal arrays.
        let scores = scored.map { $0.item.score }
        let ids = scored.map { $0.item.id }
        let hashes = scored.map { identities.identity($0.item.track).stableHash }
        let sorted = scored.indices.sorted { lhs, rhs in
            if scores[lhs] != scores[rhs] { return scores[lhs] > scores[rhs] }
            let a = hashes[lhs]
            let b = hashes[rhs]
            return a == b ? ids[lhs] < ids[rhs] : a < b
        }
        let deduped = deduplicate(sorted.map { scored[$0] }, identities: &identities)
        let ordered = diversify(
            deduped, identities: &identities, seedIDs: artistIDs, seedNames: artistNames)
        var mixes = local.playlists.filter { !$0.trackIDs.allSatisfy { !seedIDs.contains($0) } }.map
        {
            MusicDiscoveryMix(
                id: "playlist:" + $0.id, title: $0.title, subtitle: String($0.trackIDs.count),
                trackIDs: $0.trackIDs)
        }
        for (album, tracks) in compilationAlbums {
            let ids = tracks.filter { candidate in
                candidate.isPlayable != false
                    && seedTokens.isDisjoint(with: identities.identity(candidate).recordingTokens)
            }.map(\.id)
            if ids.count >= 2 {
                mixes.append(
                    .init(
                        id: "album:" + album.id, title: album.title, subtitle: String(ids.count),
                        trackIDs: ids))
            }
        }
        return MusicDiscoverySnapshot(
            seed: .init(
                title: seedTitle, artistNames: seeds.first?.artistNames ?? seedArtistName,
                trackID: seedTrackIDs.sorted().first, artistID: artistIDs.sorted().first),
            mode: mode, genres: genres, genreSource: genreSource, selectedGenre: selectedGenre,
            hideLiked: hideLiked, items: ordered, mixes: mixes)
    }

    static func mergeSignals(_ values: [MusicDiscoverySignal]) -> [MusicDiscoverySignal] {
        if values.count < 2 { return values }
        struct Aggregate {
            var best: MusicDiscoverySignal
            var detail: String
            var detailLength: Int
            var matchCount: Int
            var lowerHalf: Bool
        }
        // There are only eleven reason kinds. Aggregate each once without allocating
        // and sorting an array of complete track values for every reason group.
        var groups: [Aggregate] = []
        for signal in values {
            if let index = groups.firstIndex(where: { $0.best.reason.kind == signal.reason.kind }) {
                let best = groups[index].best
                if signal.contribution > best.contribution
                    || (signal.contribution == best.contribution
                        && signal.reason.detail < best.reason.detail)
                {
                    groups[index].best = signal
                }
                let length = signal.reason.detail.count
                if length > groups[index].detailLength
                    || (length == groups[index].detailLength
                        && signal.reason.detail < groups[index].detail)
                {
                    groups[index].detail = signal.reason.detail
                    groups[index].detailLength = length
                }
                groups[index].matchCount = max(groups[index].matchCount, signal.reason.matchCount)
                groups[index].lowerHalf = groups[index].lowerHalf || signal.lowerHalf
            } else {
                groups.append(
                    Aggregate(
                        best: signal, detail: signal.reason.detail,
                        detailLength: signal.reason.detail.count,
                        matchCount: signal.reason.matchCount,
                        lowerHalf: signal.lowerHalf))
            }
        }
        return groups.map {
            MusicDiscoverySignal(
                track: $0.best.track, kind: $0.best.reason.kind, detail: $0.detail,
                matchCount: $0.matchCount, strength: $0.best.strength, lowerHalf: $0.lowerHalf)
        }.sorted {
            $0.contribution == $1.contribution
                ? $0.reason.kind.rawValue < $1.reason.kind.rawValue
                : $0.contribution > $1.contribution
        }
    }

    static func isFresh(_ track: MusicTrack, catalog: MusicCatalog, now: Date) -> Bool {
        guard
            let raw = track.releaseDate ?? catalog.album(id: track.albumID)?.releaseDate
                ?? catalog.album(id: track.albumID)?.year
        else { return false }
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard let year = parts.first else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard
            let date = calendar.date(
                from: DateComponents(
                    year: year, month: parts.count > 1 ? parts[1] : 1,
                    day: parts.count > 2 ? parts[2] : 1)),
            let cutoff = calendar.date(byAdding: .month, value: -12, to: now)
        else { return false }
        return date >= cutoff && date <= now
    }
}
