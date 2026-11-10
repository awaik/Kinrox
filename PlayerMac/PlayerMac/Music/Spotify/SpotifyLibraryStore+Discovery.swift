import Foundation
import MetaBrainzAPI
import MusicCore
import SpotifyWebAPI

extension SpotifyLibraryStore {
    func searchPlaylists(_ query: String) async throws -> [MusicPlaylist] {
        try requireConnection()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let session = sessionGeneration
        let results = try await client.search(trimmed, types: "playlist", limit: 10)
        try checkDiscoverySession(session)
        return (results.playlists?.items ?? [])
            .filter { !isExcludedQueuePlaylist(id: $0.id, title: $0.name, ownerID: $0.owner.id) }
            .map { $0.model() }
    }

    func setListenBrainzEnabled(_ enabled: Bool) {
        guard enabled != listenBrainzEnabled else { return }
        listenBrainzEnabled = enabled
        consentGeneration = UUID()
        listenBrainzStatus = enabled ? .ready : .off
        if !enabled {
            let retiring = metaBrainzClient
            metaBrainzClient = nil
            Task { await retiring?.close() }
        }
    }

    func recordPlay(_ row: MusicPlayHistoryEntry) {
        guard !isClosed else { return }
        playHistory = MusicPlayHistoryEntry.retained(playHistory + [row], now: now())
        guard let cache else { return }
        let session = sessionGeneration
        Task { try? await cache.recordPlay(row, session: session) }
    }

    func discover(
        seedTitle: String, seedTrack: MusicTrack?, seedArtist: MusicArtist?,
        mode: MusicDiscoveryMode, selectedGenre: String?, hideLiked: Bool,
        notInterestedTrackIDs: Set<String> = [], notInterestedArtistIDs: Set<String> = []
    ) async throws -> MusicDiscoverySnapshot {
        try requireConnection()
        let session = sessionGeneration
        let consent = consentGeneration
        let artist = seedArtist ?? seedTrack?.artists.first
        let seedKey = discoverySeedKey(track: seedTrack, artist: artist)
        var value = try await cachedDiscoveryData(
            "seed-v2|\(seedKey)|\(listenBrainzEnabled ? 1 : 0)", session: session, consent: consent
        ) {
            try await self.fetchDiscovery(
                seedTrack: seedTrack, artist: artist, session: session, consent: consent)
        }
        let selectedGenre = selectedGenre.flatMap { value.genres.contains($0) ? $0 : nil }
        if let genre = selectedGenre ?? value.genres.first {
            let search = try await cachedDiscoveryData(
                "search-v2|\(seedKey)|\(mode.rawValue)|\(genre)", session: session, consent: consent
            ) {
                try await self.fetchDiscoverySearch(mode: mode, genre: genre, session: session)
            }
            value.tracks += search.tracks
            value.albums += search.albums
            value.signals += search.signals
        }
        try checkDiscoverySession(session, consent: consent)
        catalog.merge(tracks: value.tracks, albums: value.albums)
        if let seedTrack { catalog.merge(tracks: [seedTrack]) }
        recentDiscoveryTrackIDs = Set(value.tracks.map(\.id))
        recentDiscoveryAlbumIDs = Set(value.albums.map(\.id))
        pruneDisposableCatalog(
            pinnedTrackIDs: seedTrack.map { [$0.id] } ?? [],
            pinnedArtistIDs: artist.map { [$0.id] } ?? [])
        listenBrainzStatus = listenBrainzEnabled ? value.listenBrainzStatus : .off
        await publish()
        try checkDiscoverySession(session, consent: consent)
        return buildDiscovery(
            value, seedTitle: seedTitle, seedTrack: seedTrack, artist: artist, mode: mode,
            selectedGenre: selectedGenre, hideLiked: hideLiked,
            notInterestedTrackIDs: notInterestedTrackIDs,
            notInterestedArtistIDs: notInterestedArtistIDs)
    }

    private func buildDiscovery(
        _ value: SpotifyDiscoveryData, seedTitle: String, seedTrack: MusicTrack?,
        artist: MusicArtist?, mode: MusicDiscoveryMode, selectedGenre: String?, hideLiked: Bool,
        notInterestedTrackIDs: Set<String>, notInterestedArtistIDs: Set<String>
    ) -> MusicDiscoverySnapshot {
        var restored = catalog
        restored.merge(tracks: value.tracks, albums: value.albums)
        if let seedTrack { restored.merge(tracks: [seedTrack]) }
        return MusicDiscoveryEngine.build(
            seedTitle: seedTitle, seedTrackIDs: seedTrack.map { [$0.id] } ?? [],
            seedArtistIDs: artist.map { [$0.id] } ?? [], seedArtistName: artist?.name ?? "",
            mode: mode, genres: value.genres, genreSource: value.genreSource,
            selectedGenre: selectedGenre, hideLiked: hideLiked, catalog: restored, library: library,
            compilationAlbums: value.compilations.map { ($0.album, $0.tracks) },
            signals: value.signals,
            history: playHistory, notInterestedTrackIDs: notInterestedTrackIDs,
            notInterestedArtistIDs: notInterestedArtistIDs, now: now())
    }

    func cachedDiscovery(
        seedTitle: String, seedTrack: MusicTrack?, seedArtist: MusicArtist?,
        mode: MusicDiscoveryMode, selectedGenre: String?, hideLiked: Bool,
        notInterestedTrackIDs: Set<String>, notInterestedArtistIDs: Set<String>,
        previous: MusicDiscoverySnapshot? = nil
    ) -> MusicDiscoverySnapshot? {
        let artist = seedArtist ?? seedTrack?.artists.first
        let seedKey = discoverySeedKey(track: seedTrack, artist: artist)
        guard var value = memoryDiscovery("seed-v2|\(seedKey)|\(listenBrainzEnabled ? 1 : 0)")
        else { return nil }
        let selectedGenre = selectedGenre.flatMap { value.genres.contains($0) ? $0 : nil }
        var search = (selectedGenre ?? value.genres.first).flatMap {
            memoryDiscovery("search-v2|\(seedKey)|\(mode.rawValue)|\($0)")
        }
        if search == nil, let previous, let genre = previous.selectedGenre ?? previous.genres.first
        {
            search = memoryDiscovery("search-v2|\(seedKey)|\(previous.mode.rawValue)|\(genre)")
        }
        if let search {
            value.tracks += search.tracks
            value.albums += search.albums
            value.signals += search.signals
        }
        return buildDiscovery(
            value, seedTitle: seedTitle, seedTrack: seedTrack, artist: artist, mode: mode,
            selectedGenre: selectedGenre, hideLiked: hideLiked,
            notInterestedTrackIDs: notInterestedTrackIDs,
            notInterestedArtistIDs: notInterestedArtistIDs)
    }

    func discoverySeedKey(track: MusicTrack?, artist: MusicArtist?) -> String {
        "track:\(track?.id ?? "")|artist:\(artist?.id ?? "")"
    }

    private func memoryDiscovery(_ key: String) -> SpotifyDiscoveryData? {
        guard let cached = discoveryCache[key], now().timeIntervalSince(cached.date) < 86400
        else { return nil }
        return cached.value
    }

    private func cachedDiscoveryData(
        _ key: String, session: UUID, consent: UUID,
        fetch: () async throws -> SpotifyDiscoveryData
    ) async throws -> SpotifyDiscoveryData {
        if let cached = memoryDiscovery(key) { return cached }
        var value = try? await cache?.discovery(key)
        try checkDiscoverySession(session, consent: consent)
        if value == nil {
            value = try await SpotifyRequestContext.$priority.withValue(.background) {
                try await fetch()
            }
        }
        try checkDiscoverySession(session, consent: consent)
        let result = value ?? SpotifyDiscoveryData()
        if result.listenBrainzStatus != .unavailable {
            discoveryCache = discoveryCache.filter {
                now().timeIntervalSince($0.value.date) < 86400
            }
            if discoveryCache.count >= 40,
                let oldest = discoveryCache.min(by: { $0.value.date < $1.value.date })
            {
                discoveryCache[oldest.key] = nil
            }
            discoveryCache[key] = (now(), result)
            try? await cache?.saveDiscovery(key, value: result, session: session)
        }
        try checkDiscoverySession(session, consent: consent)
        return result
    }

    func checkDiscoverySession(_ session: UUID, consent: UUID? = nil) throws {
        try Task.checkCancellation()
        guard !isClosed, session == sessionGeneration,
            consent == nil || consent == consentGeneration
        else { throw CancellationError() }
    }

    func optionalDiscoveryRead<T: Sendable>(
        session: UUID, _ operation: @Sendable () async throws -> T
    ) async throws -> T? {
        try checkDiscoverySession(session)
        do {
            let value = try await operation()
            try checkDiscoverySession(session)
            return value
        } catch is CancellationError { throw CancellationError() } catch let error as URLError
            where error.code == .cancelled
        { throw CancellationError() } catch {
            try checkDiscoverySession(session)
            return nil
        }
    }
}
