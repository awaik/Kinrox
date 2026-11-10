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
        let seedIDs =
            seedTrackIDs.isEmpty && seedArtistIDs.isEmpty ? library.likedTrackIDs : seedTrackIDs
        let seeds = seedIDs.sorted().compactMap { catalog.track(id: $0) }
        let artistIDs =
            seedArtistIDs.isEmpty
            ? Set(seeds.flatMap(\.artists).map(\.id)).union(
                seedTrackIDs.isEmpty ? library.followedArtistIDs : [])
            : seedArtistIDs
        let artistNames = Set(
            seeds.flatMap(\.artists).map { MusicDiscoveryIdentity.normalized($0.name) }
        )
        .union(
            artistIDs.compactMap { catalog.artist(id: $0) }.map {
                MusicDiscoveryIdentity.normalized($0.name)
            }
        )
        .union(seedArtistName.isEmpty ? [] : [MusicDiscoveryIdentity.normalized(seedArtistName)])
        let local = localSignals(
            seedIDs: seedIDs, artistIDs: artistIDs, catalog: catalog, library: library)
        var inputs = signals + local.signals
        for (album, tracks) in compilationAlbums {
            inputs += tracks.filter {
                !isSeedArtist($0, ids: artistIDs, names: artistNames) && !isVarious($0)
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
            inputs += operatorTracks.enumerated().map {
                .init(
                    track: $0.element, kind: .sharedGenre, detail: genre,
                    strength: max(0.5, 1 - Double($0.offset) * 0.03))
            }
            inputs += catalog.tracks.filter { track in
                track.artists.contains {
                    artistGenres[$0.id, default: []].contains {
                        MusicDiscoveryIdentity.normalized($0)
                            == MusicDiscoveryIdentity.normalized(genre)
                    }
                }
            }.map { .init(track: $0, kind: .sharedGenre, detail: genre) }
        }
        let retainedHistory = MusicPlayHistoryEntry.retained(history, now: now)
        for row in retainedHistory where row.completed {
            if let previous = row.previousTrackID, seedIDs.contains(previous),
                let track = catalog.track(id: row.trackID)
            {
                inputs.append(.init(track: track, kind: .playHistory))
            } else if seedIDs.contains(row.trackID), let previous = row.previousTrackID,
                retainedHistory.contains(where: {
                    $0.sessionID == row.sessionID && $0.trackID == previous && $0.completed
                }),
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
        let seedRecordings = seeds.map(MusicDiscoveryIdentity.Recording.init)
        var candidates: [String: [MusicDiscoverySignal]] = [:]
        for signal in inputs {
            let track = signal.track
            guard signal.strength > 0, track.isPlayable != false, !seedIDs.contains(track.id),
                !(hideLiked && library.likedTrackIDs.contains(track.id)),
                !notInterestedTrackIDs.contains(track.id),
                notInterestedArtistIDs.isDisjoint(with: track.artists.map(\.id)),
                skipped[track.id, default: []].count < 2,
                !seedRecordings.contains(where: MusicDiscoveryIdentity.Recording(track).isSame)
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
        var scored: [(item: MusicDiscoveryItem, signals: [MusicDiscoverySignal])] = candidates
            .values.map { values in
                let merged = mergeSignals(values)
                let track = merged[0].track
                var score = merged.reduce(0) { $0 + $1.contribution }
                if isSeedArtist(track, ids: artistIDs, names: artistNames) { score *= 0.35 }
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
        scored.sort { precedes($0.item, $1.item) }
        var deduped: [(item: MusicDiscoveryItem, signals: [MusicDiscoverySignal])] = []
        // Parallel to `deduped`; a merge keeps the first match's track, so its keys stay valid.
        var dedupedRecordings: [MusicDiscoveryIdentity.Recording] = []
        for candidate in scored {
            let recording = MusicDiscoveryIdentity.Recording(candidate.item.track)
            let matches = dedupedRecordings.indices.filter {
                dedupedRecordings[$0].isSame(as: recording)
            }
            guard let first = matches.first else {
                deduped.append(candidate)
                dedupedRecordings.append(recording)
                continue
            }
            let best = deduped[first].item
            let merged = mergeSignals(candidate.signals + matches.flatMap { deduped[$0].signals })
            deduped[first] = (
                MusicDiscoveryItem(
                    track: best.track, reasons: merged.map(\.reason), score: best.score), merged
            )
            for index in matches.dropFirst().reversed() {
                deduped.remove(at: index)
                dedupedRecordings.remove(at: index)
            }
        }
        // Every key is normalized once, before the loop, and the selected artists are kept as
        // sets: normalizing inside the loop and rescanning `ordered` for the diversity penalty
        // made each pick O(n²) and the ranking O(n³), minutes to hours on a large playlist.
        var remaining = deduped.map {
            RankedCandidate($0.item, artistIDs: artistIDs, artistNames: artistNames)
        }
        var ordered: [MusicDiscoveryItem] = []
        var primaryCounts: [String: Int] = [:]
        var seedCounts: [String: Int] = [:]
        var selectedArtistIDs: Set<String> = []
        var selectedArtistNames: Set<String> = []
        while !remaining.isEmpty {
            let seedEligible = remaining.indices.filter { index in
                remaining[index].seedNames.allSatisfy { seedCounts[$0, default: 0] < 3 }
            }
            func primaryCount(_ index: Int) -> Int {
                primaryCounts[remaining[index].primaryArtist, default: 0]
            }
            var eligible = seedEligible.filter { ordered.count >= 30 || primaryCount($0) < 2 }
            if eligible.isEmpty, let least = seedEligible.map(primaryCount).min() {
                // Diversity is a first pass; a small artist pool must not lose valid tracks.
                eligible = seedEligible.filter { primaryCount($0) == least }
            }
            func marginal(_ index: Int) -> Double {
                let candidate = remaining[index]
                let sharesArtist =
                    !candidate.artistIDs.isDisjoint(with: selectedArtistIDs)
                    || !candidate.artistNames.isDisjoint(with: selectedArtistNames)
                return candidate.item.score * (sharesArtist ? 0.8 : 1)
            }
            // One pass with each marginal computed once; picks what `max(by:)` would: a later
            // candidate replaces the best only when it ranks strictly higher.
            var best: (index: Int, marginal: Double)?
            for index in eligible {
                let value = marginal(index)
                if let current = best,
                    current.marginal == value
                        ? precedes(remaining[current.index], remaining[index])
                        : current.marginal > value
                {
                    continue
                }
                best = (index, value)
            }
            guard let index = best?.index else { break }
            let picked = remaining.remove(at: index)
            ordered.append(picked.item)
            primaryCounts[picked.primaryArtist, default: 0] += 1
            for name in picked.seedNames { seedCounts[name, default: 0] += 1 }
            selectedArtistIDs.formUnion(picked.artistIDs)
            selectedArtistNames.formUnion(picked.artistNames)
        }
        var mixes = local.playlists.filter { !$0.trackIDs.allSatisfy { !seedIDs.contains($0) } }.map
        {
            MusicDiscoveryMix(
                id: "playlist:" + $0.id, title: $0.title, subtitle: String($0.trackIDs.count),
                trackIDs: $0.trackIDs)
        }
        for (album, tracks) in compilationAlbums {
            let ids = tracks.filter { candidate in
                candidate.isPlayable != false
                    && !seedRecordings.contains(
                        where: MusicDiscoveryIdentity.Recording(candidate).isSame)
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
        Dictionary(grouping: values, by: { $0.reason.kind }).values.compactMap { group in
            let sorted = group.sorted {
                $0.contribution == $1.contribution
                    ? $0.reason.detail < $1.reason.detail : $0.contribution > $1.contribution
            }
            guard let best = sorted.first else { return nil }
            let details: [String] = group.map { $0.reason.detail }
            let detail =
                details.sorted { a, b in a.count == b.count ? a < b : a.count > b.count }.first
                ?? ""
            return MusicDiscoverySignal(
                track: best.track, kind: best.reason.kind, detail: detail,
                matchCount: group.map(\.reason.matchCount).max() ?? 1, strength: best.strength,
                lowerHalf: group.contains(where: \.lowerHalf))
        }.sorted {
            $0.contribution == $1.contribution
                ? $0.reason.kind.rawValue < $1.reason.kind.rawValue
                : $0.contribution > $1.contribution
        }
    }

    static func isSeedArtist(_ track: MusicTrack, ids: Set<String>, names: Set<String>) -> Bool {
        track.artists.contains {
            ids.contains($0.id) || names.contains(MusicDiscoveryIdentity.normalized($0.name))
        }
    }
    static func isVarious(_ track: MusicTrack) -> Bool {
        track.artists.first.map(MusicDiscoveryIdentity.isVariousArtists) ?? false
    }
    static func precedes(_ lhs: MusicDiscoveryItem, _ rhs: MusicDiscoveryItem) -> Bool {
        precedes(
            lhs, MusicDiscoveryIdentity.stableHash(lhs.id), rhs,
            MusicDiscoveryIdentity.stableHash(rhs.id))
    }
    static func precedes(_ lhs: RankedCandidate, _ rhs: RankedCandidate) -> Bool {
        precedes(lhs.item, lhs.idHash, rhs.item, rhs.idHash)
    }
    /// Higher score first; equal scores fall back to a stable shuffle by id hash.
    private static func precedes(
        _ lhs: MusicDiscoveryItem, _ lhsHash: @autoclosure () -> UInt64,
        _ rhs: MusicDiscoveryItem, _ rhsHash: @autoclosure () -> UInt64
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let a = lhsHash()
        let b = rhsHash()
        return a == b ? lhs.id < rhs.id : a < b
    }
    /// A ranking candidate with its artist keys normalized and its id hashed once. A class, so
    /// the selection loop reads candidates without copying their sets.
    final class RankedCandidate {
        let item: MusicDiscoveryItem
        let idHash: UInt64
        let artistIDs: Set<String>
        let artistNames: Set<String>
        let primaryArtist: String
        /// Normalized names of the seed artists credited on the track, one per credit.
        let seedNames: [String]

        init(
            _ item: MusicDiscoveryItem, artistIDs seedIDs: Set<String>,
            artistNames seedNames: Set<String>
        ) {
            let artists = item.track.artists
            let names = artists.map { MusicDiscoveryIdentity.normalized($0.name) }
            self.item = item
            idHash = MusicDiscoveryIdentity.stableHash(item.id)
            artistIDs = Set(artists.map(\.id))
            artistNames = Set(names)
            primaryArtist = names.first ?? MusicDiscoveryIdentity.normalized(item.track.id)
            self.seedNames = zip(artists, names).filter {
                seedIDs.contains($0.0.id) || seedNames.contains($0.1)
            }
            .map(\.1)
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
