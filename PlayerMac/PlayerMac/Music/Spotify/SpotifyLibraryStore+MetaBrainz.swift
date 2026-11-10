import Foundation
import MetaBrainzAPI
import MusicCore
import SpotifyWebAPI

extension SpotifyLibraryStore {
    func addListenBrainzSignals(
        to data: inout SpotifyDiscoveryData, seedTrack: MusicTrack?, artist: MusicArtist?,
        session: UUID, consent: UUID
    ) async throws {
        let client = self.client
        try checkDiscoverySession(session, consent: consent)
        guard listenBrainzEnabled else { return }
        if metaBrainzClient == nil {
            let adapter = cache.map { SpotifyMetaBrainzCache(cache: $0, session: session) }
            metaBrainzClient =
                metaBrainzFactory?()
                ?? MetaBrainzClient(
                    version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                        ?? "development", cache: adapter)
        }
        guard let meta = metaBrainzClient else { return }
        data.listenBrainzStatus = .unavailable
        do {
            let resolution = try await meta.resolve(
                trackID: seedTrack?.id, isrc: seedTrack?.isrc,
                title: seedTrack?.title ?? "", artistID: artist?.id, artistName: artist?.name ?? "",
                needsGenres: data.genres.isEmpty)
            try checkDiscoverySession(session, consent: consent)
            if data.genres.isEmpty, !resolution.genres.isEmpty {
                data.genres = resolution.genres
                data.genreSource = .musicBrainz
            }
            async let recordings = metaRecordings(
                meta, id: resolution.recordingMBID, session: session)
            async let artists = metaArtists(
                meta, id: resolution.artists.first?.id, session: session)
            let (recordingResult, artistResult) = try await (recordings, artists)
            try checkDiscoverySession(session, consent: consent)
            if !resolution.genres.isEmpty || recordingResult != nil || artistResult != nil {
                data.listenBrainzStatus = .ready
            }
            let similarRecordings = recordingResult?.0 ?? []
            let mappings = recordingResult?.1 ?? []
            let similarArtists = artistResult ?? []
            let strengths = MusicDiscoverySignal.normalizedScores(
                similarRecordings.map { $0.score ?? 0 })
            var missing: [(String, Double, String)] = []
            var matchedNames = Set<String>()
            for (index, recording) in similarRecordings.enumerated() {
                guard
                    let mapping = mappings.first(where: {
                        $0.recordingMBID == recording.recordingMBID
                    })
                else { continue }
                if let track = mapping.spotifyTrackIDs.compactMap({ catalog.track(id: $0) }).first {
                    data.signals.append(
                        .init(
                            track: track, kind: .listenBrainzRecording,
                            detail: recording.artistCreditName, strength: strengths[index]))
                    data.tracks.append(track)
                    matchedNames.formUnion(
                        track.artists.map { MusicDiscoveryIdentity.normalized($0.name) })
                } else if missing.count < 8, let id = mapping.spotifyTrackIDs.first,
                    !missing.contains(where: { $0.0 == id })
                {
                    missing.append((id, strengths[index], recording.artistCreditName))
                }
            }
            try await withThrowingTaskGroup(of: (SpotifyTrack?, Double, String).self) { group in
                for (id, strength, detail) in missing {
                    group.addTask {
                        (
                            try await self.optionalDiscoveryRead(session: session) {
                                try await client.track(id)
                            }, strength, detail
                        )
                    }
                }
                for try await (remote, strength, detail) in group {
                    guard let track = remote?.model() else { continue }
                    data.signals.append(
                        .init(
                            track: track, kind: .listenBrainzRecording, detail: detail,
                            strength: strength))
                    data.tracks.append(track)
                    if let album = remote?.album?.model() { data.albums.append(album) }
                    matchedNames.formUnion(
                        track.artists.map { MusicDiscoveryIdentity.normalized($0.name) })
                }
            }
            try checkDiscoverySession(session, consent: consent)
            let seedNames = Set(
                (seedTrack?.artists ?? []).map { MusicDiscoveryIdentity.normalized($0.name) }
            )
            .union(artist.map { [MusicDiscoveryIdentity.normalized($0.name)] } ?? [])
            let scores = MusicDiscoverySignal.normalizedScores(similarArtists.map(\.score))
            let eligible = similarArtists.enumerated().filter {
                !seedNames.contains(MusicDiscoveryIdentity.normalized($0.element.name))
                    && !matchedNames.contains(MusicDiscoveryIdentity.normalized($0.element.name))
            }
            let lower = eligible.filter { $0.offset >= similarArtists.count / 2 }
            var searches = Array(eligible.prefix(3))
            searches += lower.filter { candidate in
                !searches.contains { $0.offset == candidate.offset }
            }.prefix(2)
            searches += eligible.filter { candidate in
                !searches.contains { $0.offset == candidate.offset }
            }.prefix(5 - searches.count)
            try await withThrowingTaskGroup(of: ([MusicDiscoverySignal], [MusicAlbum]).self) {
                group in
                for (index, artist) in searches {
                    group.addTask {
                        let result = try await self.optionalDiscoveryRead(session: session) {
                            try await client.search(
                                "artist:\"\(artist.name)\"", types: "track", limit: 5)
                        }
                        let signals: [MusicDiscoverySignal] = (result?.tracks?.items ?? [])
                            .compactMap { $0.model() }.filter {
                                Self.discoveryArtistMatches($0, name: artist.name)
                            }.map {
                                .init(
                                    track: $0, kind: .listenBrainzArtist, detail: artist.name,
                                    strength: scores[index],
                                    lowerHalf: index >= similarArtists.count / 2)
                            }
                        let ids = Set(signals.map(\.track.id))
                        let albums = (result?.tracks?.items ?? []).filter {
                            ids.contains($0.id ?? "")
                        }.compactMap { $0.album?.model() }
                        return (signals, albums)
                    }
                }
                for try await (signals, albums) in group {
                    data.signals += signals
                    data.tracks += signals.map(\.track)
                    data.albums += albums
                }
            }
        } catch is CancellationError { throw CancellationError() } catch let error as URLError
            where error.code == .cancelled
        { throw CancellationError() } catch {
            try checkDiscoverySession(session, consent: consent)
            data.listenBrainzStatus = .unavailable
        }
    }

    private func metaRecordings(_ client: MetaBrainzClient, id: String?, session: UUID) async throws
        -> ([MetaBrainzRecording], [MetaBrainzSpotifyMapping])?
    {
        guard let id else { return nil }
        return try await optionalDiscoveryRead(session: session) {
            let recordings = try await client.similarRecordings(id)
            let mappings = try await client.spotifyIDs(recordings.map(\.recordingMBID))
            return (recordings, mappings)
        }
    }
    private func metaArtists(_ client: MetaBrainzClient, id: String?, session: UUID) async throws
        -> [MetaBrainzSimilarArtist]?
    {
        guard let id else { return nil }
        return try await optionalDiscoveryRead(session: session) {
            try await client.similarArtists(id)
        }
    }
}
