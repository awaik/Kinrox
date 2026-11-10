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
        let related = collaborators(seedIDs: seedIDs, artistIDs: artistIDs, catalog: catalog)
        for track in catalog.tracks {
            for (name, kind) in related {
                let matches =
                    track.artists.contains {
                        MusicDiscoveryIdentity.normalized($0.name)
                            == MusicDiscoveryIdentity.normalized(name)
                    }
                    || (kind == .remixer
                        && MusicDiscoveryIdentity.remixers(in: track.title).contains {
                            MusicDiscoveryIdentity.normalized($0)
                                == MusicDiscoveryIdentity.normalized(name)
                        })
                if matches { signals.append(.init(track: track, kind: kind, detail: name)) }
            }
        }
        let dates = seedIDs.compactMap { catalog.track(id: $0)?.addedAt }
        for track in catalog.tracks where library.likedTrackIDs.contains(track.id) {
            if let date = track.addedAt,
                dates.contains(where: { abs(date.timeIntervalSince($0)) <= 12 * 3600 })
            {
                signals.append(.init(track: track, kind: .likedSameDay))
            }
        }
        return (signals, playlists)
    }

    /// Co-credit edges from seed releases, followed by the collaborator's own recordings (two hops).
    public static func collaborators(
        seedIDs: Set<String>, artistIDs: Set<String>, catalog: MusicCatalog
    ) -> [(String, MusicDiscoveryReasonKind)] {
        let seeds = seedIDs.compactMap { catalog.track(id: $0) }
        let names = Set(
            artistIDs.compactMap { catalog.artist(id: $0) }.map {
                MusicDiscoveryIdentity.normalized($0.name)
            }
        )
        .union(seeds.flatMap(\.artists).map { MusicDiscoveryIdentity.normalized($0.name) })
        var found: [String: (String, MusicDiscoveryReasonKind)] = [:]
        func harvest(_ artists: [MusicArtist], title: String) {
            for artist in artists
            where !artistIDs.contains(artist.id)
                && !names.contains(MusicDiscoveryIdentity.normalized(artist.name))
                && !MusicDiscoveryIdentity.isVariousArtists(artist)
            {
                found[MusicDiscoveryIdentity.normalized(artist.name)] = (artist.name, .collaborator)
            }
            for remixer in MusicDiscoveryIdentity.remixers(in: title)
            where !names.contains(MusicDiscoveryIdentity.normalized(remixer))
                && MusicDiscoveryIdentity.normalized(remixer) != "various artists"
            {
                found[MusicDiscoveryIdentity.normalized(remixer)] = (remixer, .remixer)
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
