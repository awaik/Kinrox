// Frozen pre-optimization behavior for exact ranking equivalence.
import Foundation

@testable import MusicCore

enum ReferenceDiscoveryEngine {
    static func build(
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
            seeds.flatMap(\.artists).map { ReferenceDiscoveryIdentity.normalized($0.name) }
        )
        .union(
            artistIDs.compactMap { catalog.artist(id: $0) }.map {
                ReferenceDiscoveryIdentity.normalized($0.name)
            }
        )
        .union(
            seedArtistName.isEmpty ? [] : [ReferenceDiscoveryIdentity.normalized(seedArtistName)])
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
                        ReferenceDiscoveryIdentity.normalized($0)
                            == ReferenceDiscoveryIdentity.normalized(genre)
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
        var candidates: [String: [MusicDiscoverySignal]] = [:]
        for signal in inputs {
            let track = signal.track
            guard signal.strength > 0, track.isPlayable != false, !seedIDs.contains(track.id),
                !(hideLiked && library.likedTrackIDs.contains(track.id)),
                !notInterestedTrackIDs.contains(track.id),
                notInterestedArtistIDs.isDisjoint(with: track.artists.map(\.id)),
                skipped[track.id, default: []].count < 2,
                !seeds.contains(where: { ReferenceDiscoveryIdentity.sameRecording(track, $0) })
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
        for candidate in scored {
            let matches = deduped.indices.filter {
                ReferenceDiscoveryIdentity.sameRecording(
                    deduped[$0].item.track, candidate.item.track)
            }
            guard let first = matches.first else {
                deduped.append(candidate)
                continue
            }
            let best = deduped[first].item
            let merged = mergeSignals(candidate.signals + matches.flatMap { deduped[$0].signals })
            deduped[first] = (
                MusicDiscoveryItem(
                    track: best.track, reasons: merged.map(\.reason), score: best.score), merged
            )
            for index in matches.dropFirst().reversed() { deduped.remove(at: index) }
        }
        var remaining = deduped.map(\.item)
        var ordered: [MusicDiscoveryItem] = []
        var primaryCounts: [String: Int] = [:]
        var seedCounts: [String: Int] = [:]
        while !remaining.isEmpty {
            let seedEligible = remaining.indices.filter { index in
                let track = remaining[index].track
                let seedNames = track.artists.filter {
                    artistIDs.contains($0.id)
                        || artistNames.contains(ReferenceDiscoveryIdentity.normalized($0.name))
                }.map { ReferenceDiscoveryIdentity.normalized($0.name) }
                return seedNames.allSatisfy { seedCounts[$0, default: 0] < 3 }
            }
            func primaryCount(_ index: Int) -> Int {
                let track = remaining[index].track
                return primaryCounts[
                    ReferenceDiscoveryIdentity.normalized(track.artists.first?.name ?? track.id),
                    default: 0]
            }
            var eligible = seedEligible.filter { ordered.count >= 30 || primaryCount($0) < 2 }
            if eligible.isEmpty, let least = seedEligible.map(primaryCount).min() {
                // Diversity is a first pass; a small artist pool must not lose valid tracks.
                eligible = seedEligible.filter { primaryCount($0) == least }
            }
            guard
                let index = eligible.max(by: { lhs, rhs in
                    let a = marginal(remaining[lhs], selected: ordered)
                    let b = marginal(remaining[rhs], selected: ordered)
                    return a == b ? !precedes(remaining[lhs], remaining[rhs]) : a < b
                })
            else { break }
            let item = remaining.remove(at: index)
            ordered.append(item)
            primaryCounts[
                ReferenceDiscoveryIdentity.normalized(
                    item.track.artists.first?.name ?? item.track.id),
                default: 0] += 1
            for artist in item.track.artists
            where artistIDs.contains(artist.id)
                || artistNames.contains(ReferenceDiscoveryIdentity.normalized(artist.name))
            {
                seedCounts[ReferenceDiscoveryIdentity.normalized(artist.name), default: 0] += 1
            }
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
                    && !seeds.contains { ReferenceDiscoveryIdentity.sameRecording(candidate, $0) }
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
            ids.contains($0.id) || names.contains(ReferenceDiscoveryIdentity.normalized($0.name))
        }
    }
    static func isVarious(_ track: MusicTrack) -> Bool {
        track.artists.first.map(ReferenceDiscoveryIdentity.isVariousArtists) ?? false
    }
    static func precedes(_ lhs: MusicDiscoveryItem, _ rhs: MusicDiscoveryItem) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let a = ReferenceDiscoveryIdentity.stableHash(lhs.id)
        let b = ReferenceDiscoveryIdentity.stableHash(rhs.id)
        return a == b ? lhs.id < rhs.id : a < b
    }
    static func marginal(_ item: MusicDiscoveryItem, selected: [MusicDiscoveryItem]) -> Double {
        let sharesArtist = selected.contains {
            ReferenceDiscoveryIdentity.sharesArtist(item.track, $0.track)
        }
        return item.score * (sharesArtist ? 0.8 : 1)
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
