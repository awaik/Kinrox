import Foundation

extension MusicDiscoveryEngine {
    public static func localDiscoverySignals(
        seedIDs: Set<String>, artistIDs: Set<String>, catalog: MusicCatalog,
        library: LibrarySnapshot
    ) -> [MusicDiscoverySignal] {
        localSignals(seedIDs: seedIDs, artistIDs: artistIDs, catalog: catalog, library: library)
            .signals
    }

    static func localSignals(
        seedIDs: Set<String>, artistIDs: Set<String>, catalog: MusicCatalog,
        library: LibrarySnapshot
    ) -> (signals: [MusicDiscoverySignal], playlists: [MusicPlaylist]) {
        let available = library.playlists.filter { $0.itemsAvailable && !$0.trackIDs.isEmpty }
            .sorted { $0.id < $1.id }
        let direct = available.filter { !seedIDs.isDisjoint(with: $0.trackIDs) }
        let playlists =
            direct.isEmpty
            ? available.filter { playlist in
                playlist.trackIDs.compactMap { catalog.track(id: $0) }.contains {
                    !artistIDs.isDisjoint(with: $0.artists.map(\.id))
                }
            } : direct
        var idf: [String: Double] = [:]
        var names: [String: [String]] = [:]
        for playlist in playlists {
            let weight = 1 / log2(2 + Double(max(1, playlist.trackIDs.count)))
            for id in Set(playlist.trackIDs) where !seedIDs.contains(id) {
                idf[id, default: 0] += weight
                names[id, default: []].append(playlist.title)
            }
        }
        let maximum = idf.values.max() ?? 1
        var signals: [MusicDiscoverySignal] = idf.keys.sorted().compactMap { id in
            guard let track = catalog.track(id: id), let raw = idf[id] else { return nil }
            return .init(
                track: track, kind: .ownPlaylist,
                detail: names[id, default: []].joined(separator: ", "),
                matchCount: names[id, default: []].count,
                strength: idf.count == 1 ? min(1, raw * 2) : min(1, raw / maximum))
        }
        let identities = LocalDiscoveryIdentity()
        let related = Dictionary(
            uniqueKeysWithValues:
                collaborators(
                    seedIDs: seedIDs, artistIDs: artistIDs, catalog: catalog, identities: identities
                ).map {
                    (MusicDiscoveryIdentity.normalized($0.0), ($0.0, $0.1))
                })
        if !related.isEmpty {
            var normalizedNames: [String: String] = [:]
            for track in catalog.tracks {
                var matches = Set<String>()
                for artist in track.artists {
                    let name =
                        normalizedNames[artist.name]
                        ?? MusicDiscoveryIdentity.normalized(artist.name)
                    normalizedNames[artist.name] = name
                    if related[name] != nil { matches.insert(name) }
                }
                for remixer in identities.remixers(track.title) {
                    let name = MusicDiscoveryIdentity.normalized(remixer)
                    if related[name]?.1 == .remixer { matches.insert(name) }
                }
                for name in matches.sorted() {
                    if let (display, kind) = related[name] {
                        signals.append(.init(track: track, kind: kind, detail: display))
                    }
                }
            }
        }
        let dates = seedIDs.compactMap { catalog.track(id: $0)?.addedAt?.timeIntervalSince1970 }
            .sorted()
        for track in catalog.tracks where library.likedTrackIDs.contains(track.id) {
            if let date = track.addedAt?.timeIntervalSince1970 {
                var low = 0
                var high = dates.count
                let lowerBound = date - 12 * 3600
                while low < high {
                    let middle = (low + high) / 2
                    if dates[middle] < lowerBound { low = middle + 1 } else { high = middle }
                }
                if low < dates.count, dates[low] <= date + 12 * 3600 {
                    signals.append(.init(track: track, kind: .likedSameDay))
                }
            }
        }
        return (signals, playlists)
    }

    /// Co-credit edges from seed releases, followed by the collaborator's own recordings (two hops).
    public static func collaborators(
        seedIDs: Set<String>, artistIDs: Set<String>, catalog: MusicCatalog
    ) -> [(String, MusicDiscoveryReasonKind)] {
        collaborators(
            seedIDs: seedIDs, artistIDs: artistIDs, catalog: catalog,
            identities: LocalDiscoveryIdentity())
    }

    private static func collaborators(
        seedIDs: Set<String>, artistIDs: Set<String>, catalog: MusicCatalog,
        identities: LocalDiscoveryIdentity
    ) -> [(String, MusicDiscoveryReasonKind)] {
        var normalizedNames: [String: String] = [:]
        func normalized(_ name: String) -> String {
            if let cached = normalizedNames[name] { return cached }
            let value = MusicDiscoveryIdentity.normalized(name)
            normalizedNames[name] = value
            return value
        }
        let seeds = seedIDs.compactMap { catalog.track(id: $0) }
        let names = Set(
            artistIDs.compactMap { catalog.artist(id: $0) }.map {
                normalized($0.name)
            }
        )
        .union(seeds.flatMap(\.artists).map { normalized($0.name) })
        var found: [String: (String, MusicDiscoveryReasonKind)] = [:]
        func harvest(_ artists: [MusicArtist], title: String) {
            for artist in artists
            where !artistIDs.contains(artist.id)
                && !names.contains(normalized(artist.name))
                && artist.id != "0LyfQWJT6nXafLPZqxe9Of"
                && normalized(artist.name) != "various artists"
            {
                found[normalized(artist.name)] = (artist.name, .collaborator)
            }
            for remixer in identities.remixers(title)
            where !names.contains(normalized(remixer))
                && normalized(remixer) != "various artists"
            {
                found[normalized(remixer)] = (remixer, .remixer)
            }
        }
        for track in catalog.tracks
        where seedIDs.contains(track.id) || !artistIDs.isDisjoint(with: track.artists.map(\.id)) {
            harvest(track.artists, title: track.title)
        }
        for album in catalog.albums where !artistIDs.isDisjoint(with: album.artists.map(\.id)) {
            harvest(album.artists, title: album.title)
        }
        return found.sorted { $0.key < $1.key }.map(\.value)
    }
}

/// Short-lived parsed credits shared by collaborator discovery and candidate matching.
private final class LocalDiscoveryIdentity {
    var credits: [String: [String]] = [:]

    func remixers(_ title: String) -> [String] {
        guard let start = MusicDiscoveryIdentity.qualifierStart(in: title) else { return [] }
        let suffix = String(title[start...])
        if let value = credits[suffix] { return value }
        let value = MusicDiscoveryIdentity.remixers(in: suffix)
        credits[suffix] = value
        return value
    }
}
