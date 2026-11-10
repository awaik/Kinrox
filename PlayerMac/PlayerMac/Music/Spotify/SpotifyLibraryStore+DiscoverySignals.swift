import Foundation
import MusicCore
import SpotifyWebAPI

private enum DiscoveryRead: Sendable {
    case artist(SpotifyArtistDetails?)
    case albums([SpotifyAlbum])
    case harvest([SpotifyTrack])
    case seed(SpotifyTrack?)
}

extension SpotifyLibraryStore {
    func fetchDiscovery(
        seedTrack: MusicTrack?, artist: MusicArtist?, session: UUID, consent: UUID
    ) async throws -> SpotifyDiscoveryData {
        let client = self.client
        var data = SpotifyDiscoveryData()
        var harvest = MusicCatalog(
            tracks: catalog.tracks, albums: catalog.albums, artists: catalog.artists)
        if let seedTrack { harvest.merge(tracks: [seedTrack]) }
        var releases: [SpotifyAlbum] = []
        var hydrated = seedTrack
        try await withThrowingTaskGroup(of: DiscoveryRead.self) { group in
            if let artist {
                group.addTask {
                    .artist(
                        try await self.optionalDiscoveryRead(session: session) {
                            try await client.artist(artist.id)
                        })
                }
                group.addTask {
                    .albums(
                        try await self.optionalDiscoveryRead(session: session) {
                            try await client.artistAlbums(
                                artist.id, includeGroups: "album,single,appears_on,compilation")
                        } ?? [])
                }
                group.addTask {
                    .harvest(
                        try await self.optionalDiscoveryRead(session: session) {
                            try await client.search(
                                "artist:\"\(artist.name)\"", types: "track", limit: 10
                            ).tracks?.items ?? []
                        } ?? [])
                }
            }
            if let seedTrack, MusicDiscoveryIdentity.isrc(seedTrack) == nil {
                group.addTask {
                    .seed(
                        try await self.optionalDiscoveryRead(session: session) {
                            try await client.track(seedTrack.id)
                        })
                }
            }
            for try await result in group {
                switch result {
                case .artist(let details):
                    data.genres = Array((details?.genres ?? []).prefix(6))
                    data.genreSource = data.genres.isEmpty ? .none : .spotify
                case .albums(let albums): releases = albums
                case .harvest(let tracks):
                    harvest.merge(
                        tracks: tracks.compactMap { $0.model() },
                        albums: tracks.compactMap { $0.album?.model() })
                case .seed(let track):
                    if let model = track?.model() {
                        hydrated = model
                        data.tracks.append(model)
                        if let album = track?.album?.model() { data.albums.append(album) }
                        catalog.merge(tracks: [model])
                    }
                }
            }
        }
        try checkDiscoverySession(session, consent: consent)
        harvest.merge(albums: releases.map { $0.model() })
        let compilations = releases.filter {
            (2...30).contains($0.totalTracks ?? 0)
                && ($0.albumGroup == "appears_on" || $0.albumType == "compilation")
        }
        let fetched = try await discoveryAlbums(Array(compilations.prefix(3)), session: session)
        data.compilations = fetched
        for entry in fetched {
            data.tracks += entry.tracks
            data.albums.append(entry.album)
            harvest.merge(tracks: entry.tracks, albums: [entry.album])
        }
        let artistIDs: Set<String> = Set(seedTrack?.artists.map(\.id) ?? []).union(
            artist.map { [$0.id] } ?? [])
        let collaborators = MusicDiscoveryEngine.collaborators(
            seedIDs: seedTrack.map { [$0.id] } ?? [], artistIDs: artistIDs, catalog: harvest)
        try await withThrowingTaskGroup(of: ([MusicDiscoverySignal], [MusicAlbum]).self) { group in
            for (name, kind) in collaborators.prefix(4) {
                group.addTask {
                    let results = try await self.optionalDiscoveryRead(session: session) {
                        try await client.search("artist:\"\(name)\"", types: "track", limit: 5)
                    }
                    let signals: [MusicDiscoverySignal] = (results?.tracks?.items ?? []).compactMap
                    { $0.model() }.filter {
                        Self.discoveryArtistMatches($0, name: name, remixer: kind == .remixer)
                    }.enumerated().map {
                        .init(
                            track: $0.element, kind: kind, detail: name,
                            strength: max(0.5, 1 - Double($0.offset) * 0.03))
                    }
                    let ids = Set(signals.map(\.track.id))
                    let albums = (results?.tracks?.items ?? []).filter { ids.contains($0.id ?? "") }
                        .compactMap { $0.album?.model() }
                    return (signals, albums)
                }
            }
            for try await (signals, albums) in group {
                data.signals += signals
                data.tracks += signals.map(\.track)
                data.albums += albums
            }
        }
        try checkDiscoverySession(session, consent: consent)
        if listenBrainzEnabled {
            try await addListenBrainzSignals(
                to: &data, seedTrack: hydrated, artist: artist, session: session, consent: consent)
        }
        try checkDiscoverySession(session, consent: consent)
        // Local two-hop signals discovered while harvesting must survive catalog pruning and cache hits.
        let harvestedSignals = MusicDiscoveryEngine.localDiscoverySignals(
            seedIDs: seedTrack.map { [$0.id] } ?? [], artistIDs: artistIDs, catalog: harvest,
            library: library)
        data.signals += harvestedSignals.filter {
            [.collaborator, .remixer].contains($0.reason.kind)
        }
        data.tracks += data.signals.map(\.track)
        let candidateAlbumIDs = Set(data.tracks.map(\.albumID))
        data.albums += harvest.albums.filter { candidateAlbumIDs.contains($0.id) }
        let canonical = MusicCatalog(tracks: data.tracks, albums: data.albums)
        data.tracks = canonical.tracks
        data.albums = canonical.albums
        return data
    }

    func fetchDiscoverySearch(mode: MusicDiscoveryMode, genre: String, session: UUID)
        async throws -> SpotifyDiscoveryData
    {
        let client = self.client
        var data = SpotifyDiscoveryData()
        if !genre.isEmpty {
            let query =
                "genre:\"\(genre)\""
                + (mode == .underground ? " tag:hipster" : mode == .fresh ? " tag:new" : "")
            if let result = try await optionalDiscoveryRead(
                session: session,
                {
                    try await client.search(
                        query, types: mode == .sameSpirit ? "track" : "album",
                        limit: mode == .sameSpirit ? 10 : 5)
                })
            {
                var tracks = (result.tracks?.items ?? []).compactMap { $0.model() }
                data.albums += (result.tracks?.items ?? []).compactMap { $0.album?.model() }
                if mode != .sameSpirit {
                    let albums = try await discoveryAlbums(
                        Array((result.albums?.items ?? []).prefix(3)), session: session)
                    tracks += albums.flatMap(\.tracks)
                    data.albums += albums.map(\.album)
                }
                data.tracks += tracks
                let kind: MusicDiscoveryReasonKind =
                    mode == .sameSpirit
                    ? .sharedGenre : mode == .fresh ? .freshRelease : .underground
                data.signals += tracks.enumerated().map {
                    .init(
                        track: $0.element, kind: kind, detail: genre,
                        strength: max(0.5, 1 - Double($0.offset) * 0.03))
                }
            }
        }
        return data
    }

    func discoveryAlbums(_ albums: [SpotifyAlbum], session: UUID) async throws
        -> [SpotifyDiscoveryAlbum]
    {
        let client = self.client
        return try await withThrowingTaskGroup(of: (Int, SpotifyDiscoveryAlbum?).self) { group in
            for (index, album) in albums.enumerated() {
                group.addTask {
                    let tracks =
                        try await self.optionalDiscoveryRead(session: session) {
                            try await client.albumTracks(album.id)
                        } ?? []
                    let models = tracks.compactMap { $0.model(album: album) }
                    return (
                        index,
                        models.isEmpty
                            ? nil
                            : SpotifyDiscoveryAlbum(
                                album: album.model(trackIDs: models.map(\.id)), tracks: models)
                    )
                }
            }
            var results: [(Int, SpotifyDiscoveryAlbum?)] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
    }

    nonisolated static func discoveryArtistMatches(
        _ track: MusicTrack, name: String, remixer: Bool = false
    ) -> Bool {
        let normalized = MusicDiscoveryIdentity.normalized(name)
        return track.artists.contains { MusicDiscoveryIdentity.normalized($0.name) == normalized }
            || (remixer
                && MusicDiscoveryIdentity.remixers(in: track.title).contains {
                    MusicDiscoveryIdentity.normalized($0) == normalized
                })
    }
}
