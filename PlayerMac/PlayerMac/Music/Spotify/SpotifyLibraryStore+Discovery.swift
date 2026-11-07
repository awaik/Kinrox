import Foundation
import MusicCore
import SpotifyWebAPI

extension SpotifyLibraryStore {
    func searchPlaylists(_ query: String) async throws -> [MusicPlaylist] {
        try requireConnection()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let session = sessionGeneration
        let results = try await client.search(trimmed, types: "playlist", limit: 10)
        guard !isClosed, session == sessionGeneration else { throw CancellationError() }
        let playlists = (results.playlists?.items ?? [])
            .filter { !isExcludedQueuePlaylist(id: $0.id, title: $0.name, ownerID: $0.owner.id) }
            .map { $0.model() }
        return playlists
    }

    func discover(
        seedTitle: String,
        seedTrack: MusicTrack?,
        seedArtist: MusicArtist?,
        mode: MusicDiscoveryMode,
        selectedGenre: String?,
        hideLiked: Bool
    ) async throws -> MusicDiscoverySnapshot {
        try requireConnection()
        let session = sessionGeneration
        let primaryArtist = seedArtist ?? seedTrack?.artists.first ?? catalog.artists.first
        let queryTitle = seedTrack?.title ?? seedTitle
        let searchQuery = [primaryArtist?.name, queryTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        var genres: [String] = []
        var cooccurringPlaylists: [(playlist: MusicPlaylist, tracks: [MusicTrack])] = []
        var compilationAlbums: [(album: MusicAlbum, tracks: [MusicTrack])] = []
        var undergroundTracks: [MusicTrack] = []
        var freshTracks: [MusicTrack] = []
        var operatorTracks: [MusicTrack] = []

        if let artistID = primaryArtist?.id {
            if let details = try await optionalDiscoveryRead(
                session: session, { try await client.artist(artistID) }),
                let remoteGenres = details.genres, !remoteGenres.isEmpty
            {
                genres = Array(remoteGenres.prefix(6))
            }
            if let albums = try await optionalDiscoveryRead(
                session: session,
                { try await client.artistAlbums(artistID, includeGroups: "appears_on,compilation") }
            ) {
                for album in albums.prefix(3) {
                    let items =
                        (try await optionalDiscoveryRead(
                            session: session, { try await client.albumTracks(album.id) })) ?? []
                    let models = items.compactMap { $0.model(album: album) }
                    if !models.isEmpty {
                        let albumModel = album.model(trackIDs: models.map(\.id))
                        catalog.merge(
                            tracks: models,
                            albums: [albumModel],
                            artists: album.artists)
                        compilationAlbums.append((album: albumModel, tracks: models))
                    }
                }
            }
        }

        if !searchQuery.isEmpty,
            let results = try await optionalDiscoveryRead(
                session: session,
                { try await client.search(searchQuery, types: "playlist,track", limit: 5) })
        {
            let directTracks = (results.tracks?.items ?? []).compactMap { $0.model() }
            if !directTracks.isEmpty {
                catalog.merge(
                    tracks: directTracks,
                    albums: (results.tracks?.items ?? []).compactMap { $0.album?.model() })
                operatorTracks.append(contentsOf: directTracks)
            }
            let readablePlaylists = (results.playlists?.items ?? []).filter {
                !isExcludedQueuePlaylist(id: $0.id, title: $0.name, ownerID: $0.owner.id)
                    && !restrictedPlaylistIDs.contains($0.id)
                    && (library.userID.isEmpty || $0.model().isEditable(by: library.userID))
            }
            for remote in readablePlaylists.prefix(3) {
                guard
                    let entries = try await optionalDiscoveryRead(
                        session: session,
                        {
                            do {
                                return try await client.playlistItems(remote.id)
                            } catch SpotifyError.forbidden {
                                restrictedPlaylistIDs.insert(remote.id)
                                throw SpotifyError.forbidden
                            }
                        })
                else { continue }
                let models = entries.prefix(25).compactMap { $0.value?.model() }
                if !models.isEmpty {
                    let playlistModel = remote.model(trackIDs: models.map(\.id))
                    catalog.merge(
                        tracks: models,
                        albums: entries.prefix(25).compactMap { $0.value?.album?.model() })
                    cooccurringPlaylists.append((playlist: playlistModel, tracks: models))
                }
            }
        }

        let activeGenre = selectedGenre ?? genres.first
        switch mode {
        case .underground, .fresh:
            let tag = mode == .underground ? "tag:hipster" : "tag:new"
            let albumQuery = [primaryArtist?.name ?? activeGenre ?? queryTitle, tag]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !albumQuery.isEmpty,
                let extra = try await optionalDiscoveryRead(
                    session: session,
                    { try await client.search(albumQuery, types: "album", limit: 5) })
            {
                for album in (extra.albums?.items ?? []).prefix(3) {
                    let items: [SpotifyTrack]
                    if let embedded = album.tracks?.items, !embedded.isEmpty {
                        items = embedded
                    } else {
                        items =
                            (try await optionalDiscoveryRead(
                                session: session, { try await client.albumTracks(album.id) }))
                            ?? []
                    }
                    let models = items.compactMap { $0.model(album: album) }
                    if !models.isEmpty {
                        let albumModel = album.model(trackIDs: models.map(\.id))
                        catalog.merge(
                            tracks: models,
                            albums: [albumModel],
                            artists: album.artists)
                        if mode == .underground {
                            undergroundTracks.append(contentsOf: models)
                        } else {
                            freshTracks.append(contentsOf: models)
                        }
                    }
                }
            }
        case .sameSpirit:
            let operatorQuery =
                activeGenre.map { "genre:\"\($0)\"" } ?? primaryArtist?.name ?? searchQuery
            if !operatorQuery.isEmpty,
                let extra = try await optionalDiscoveryRead(
                    session: session,
                    { try await client.search(operatorQuery, types: "track", limit: 10) })
            {
                let models = (extra.tracks?.items ?? []).compactMap { $0.model() }
                if !models.isEmpty {
                    catalog.merge(
                        tracks: models,
                        albums: (extra.tracks?.items ?? []).compactMap { $0.album?.model() })
                    operatorTracks.append(contentsOf: models)
                }
            }
        }

        try Task.checkCancellation()
        guard !isClosed, session == sessionGeneration else { throw CancellationError() }
        await publish()

        let seedTrackIDs: Set<String> = seedTrack.map { [$0.id] } ?? library.likedTrackIDs
        let seedArtistIDs: Set<String> =
            primaryArtist.map { [$0.id] } ?? library.followedArtistIDs
        return MusicDiscoveryEngine.build(
            seedTitle: seedTitle,
            seedTrackIDs: seedTrackIDs,
            seedArtistIDs: seedArtistIDs,
            seedArtistName: primaryArtist?.name ?? "",
            mode: mode,
            genres: genres,
            selectedGenre: selectedGenre,
            hideLiked: hideLiked,
            catalog: catalog,
            library: library,
            cooccurringPlaylists: cooccurringPlaylists,
            compilationAlbums: compilationAlbums,
            undergroundTracks: undergroundTracks,
            freshTracks: freshTracks,
            operatorTracks: operatorTracks)
    }

    private func optionalDiscoveryRead<T>(
        session: UUID,
        _ operation: () async throws -> T
    ) async throws -> T? {
        try Task.checkCancellation()
        guard !isClosed, session == sessionGeneration else { throw CancellationError() }
        do {
            let value = try await operation()
            try Task.checkCancellation()
            guard !isClosed, session == sessionGeneration else { throw CancellationError() }
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard !isClosed, session == sessionGeneration else { throw CancellationError() }
            return nil
        }
    }
}
