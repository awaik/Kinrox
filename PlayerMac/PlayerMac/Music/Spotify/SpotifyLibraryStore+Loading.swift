import Foundation
import MusicCore
import SpotifyWebAPI

extension SpotifyLibraryStore {
    func loadCollection(_ key: String, force: Bool = false) async throws {
        if !force, fresh(key) { return }
        try await shared(key) { [self] in
            let version = stamp(key)
            let etag = resources[key]?.isComplete == true ? resources[key]?.etag : nil
            switch key {
            case "albums":
                let result = try await client.resourcePages(
                    SpotifySavedAlbum.self, path: "me/albums?limit=50", etag: etag)
                guard accepts(key, stamp: version) else { return }
                if let values = result.value {
                    library.savedAlbumIDs = Set(values.map(\.album.id))
                    for saved in values { mergeAlbum(saved.album) }
                }
                mark(key, etag: result.etag)
            case "liked":
                let result = try await client.resourcePages(
                    SpotifySavedTrack.self, path: "me/tracks?limit=50", etag: etag)
                guard accepts(key, stamp: version) else { return }
                if let values = result.value {
                    let tracks = values.compactMap(\.track)
                    library.likedTrackIDs = Set(tracks.compactMap(\.id))
                    catalog.merge(
                        tracks: values.compactMap { $0.track?.model(addedAt: $0.addedDate) },
                        albums: tracks.compactMap { $0.album?.model() })
                }
                mark(key, etag: result.etag)
            case "artists":
                let values = try await client.followedArtists()
                guard accepts(key, stamp: version) else { return }
                library.followedArtistIDs = Set(values.map(\.id))
                catalog.merge(artists: values)
                mark(key)
            case "playlists":
                let result = try await client.resourcePages(
                    SpotifyPlaylist.self, path: "me/playlists?limit=50", etag: etag)
                guard accepts(key, stamp: version) else { return }
                if let values = result.value {
                    library.playlists = values.filter {
                        !isExcludedQueuePlaylist(id: $0.id, title: $0.name, ownerID: $0.owner.id)
                    }.map { remote in
                        let ids =
                            index.trackIDs(
                                playlistID: remote.id, snapshotID: remote.snapshotID ?? "") ?? []
                        if resources["playlist:" + remote.id]?.snapshotID != remote.snapshotID {
                            resources["playlist:" + remote.id] = nil
                        }
                        var model = remote.model(trackIDs: ids)
                        if restrictedPlaylistIDs.contains(remote.id) {
                            model.itemsAvailable = false
                        }
                        return model
                    }
                    rebuildIndex()
                }
                mark(key, etag: result.etag)
            default: throw SpotifyError.invalidResponse
            }
            await publish()
        }
    }

    func mergeAlbum(_ album: SpotifyAlbum) {
        let tracks = album.tracks?.items.compactMap { $0.model(album: album) } ?? []
        let key = "album:" + album.id
        var trackIDs = tracks.map(\.id)
        if album.tracks?.next != nil {
            if resources[key]?.isComplete == true, let existing = catalog.album(id: album.id),
                existing.trackIDs.count > tracks.count
            {
                // An embedded first page cannot replace an already complete album.
                trackIDs = existing.trackIDs
            } else {
                // A first-page-only cache must remain eligible for pagination.
                resources[key] = nil
            }
        }
        catalog.merge(
            tracks: tracks, albums: [album.model(trackIDs: trackIDs)],
            artists: album.artists)
        if let page = album.tracks {
            if page.next == nil {
                mark("album:" + album.id, ttl: 24 * 3600)
                embeddedAlbums[album.id] = nil
            } else {
                embeddedAlbums[album.id] = album
            }
        }
    }

    func loadAlbum(_ id: String) async throws {
        await awaitRestore()
        let key = "album:" + id
        if fresh(key) { return }
        try await shared(key) { [self] in
            let version = stamp(key)
            let album: SpotifyAlbum
            var etag: String?
            if let embedded = embeddedAlbums[id] {
                album = embedded
            } else {
                let result = try await client.resource(
                    SpotifyAlbum.self, path: "albums/" + id,
                    etag: resources[key]?.etag)
                etag = result.etag
                guard let value = result.value else {
                    guard accepts(key, stamp: version) else { return }
                    mark(key, ttl: 24 * 3600, etag: etag)
                    await publish()
                    return
                }
                album = value
            }
            var tracks = album.tracks?.items ?? []
            if let next = album.tracks?.next {
                tracks += try await client.remainingAlbumTracks(next)
            } else if album.tracks == nil {
                tracks = try await client.albumTracks(id)
            }
            guard accepts(key, stamp: version) else { return }
            let models = tracks.compactMap { $0.model(album: album) }
            catalog.merge(
                tracks: models, albums: [album.model(trackIDs: models.map(\.id))],
                artists: album.artists)
            mark(key, ttl: 24 * 3600, etag: etag)
            embeddedAlbums[id] = nil
            await publish()
        }
    }

    func loadArtist(_ id: String) async throws {
        await awaitRestore()
        let key = "artist:" + id
        if fresh(key) { return }
        try await shared(key) { [self] in
            let version = stamp(key)
            let result = try await client.resourcePages(
                SpotifyAlbum.self,
                path: "artists/" + id
                    + "/albums?limit=50&include_groups=album,single,appears_on,compilation",
                etag: resources[key]?.etag)
            guard accepts(key, stamp: version) else { return }
            if let albums = result.value { catalog.merge(albums: albums.map { $0.model() }) }
            mark(key, ttl: 3600, etag: result.etag)
            await publish()
        }
    }

    func ensurePlaylistLoaded(_ id: String, requireEditable: Bool = false) async throws {
        let key = "playlist:" + id
        try await shared(key) { [self] in
            let version = stamp(key)
            for _ in 0..<3 {
                let remote = try await client.playlist(id, live: true)
                guard !isExcludedQueuePlaylist(id: id, title: remote.name, ownerID: remote.owner.id)
                else {
                    throw SpotifyError.forbidden
                }
                let editable = remote.model().isEditable(by: library.userID)
                guard !requireEditable || editable else {
                    throw SpotifyError.forbidden
                }
                guard let snapshot = remote.snapshotID, !snapshot.isEmpty else {
                    throw SpotifyError.invalidResponse
                }
                if let ids = index.trackIDs(playlistID: id, snapshotID: snapshot),
                    resources[key]?.isComplete == true
                {
                    guard accepts(key, stamp: version) else { return }
                    restrictedPlaylistIDs.remove(id)
                    installPlaylist(remote.model(trackIDs: ids))
                    mark(key, snapshot: snapshot)
                    await publish()
                    return
                }
                let entries: [SpotifyPlaylistItem]
                do {
                    entries = try await client.playlistItems(id)
                } catch SpotifyError.forbidden where !requireEditable {
                    guard accepts(key, stamp: version) else { return }
                    restrictedPlaylistIDs.insert(id)
                    resources[key] = nil
                    let existingIDs =
                        library.playlists.first(where: { $0.id == id })?.trackIDs ?? []
                    var restrictedModel = remote.model(trackIDs: existingIDs)
                    restrictedModel.itemsAvailable = false
                    installPlaylist(restrictedModel)
                    await publish()
                    throw SpotifyPlaylistError.itemsUnavailable
                }
                let after = try await client.playlist(id, live: true)
                guard !requireEditable || after.model().isEditable(by: library.userID) else {
                    throw SpotifyError.forbidden
                }
                guard after.snapshotID == snapshot else { continue }
                guard accepts(key, stamp: version) else { return }
                let ids = entries.enumerated().map { offset, entry in
                    entry.value?.model()?.id ?? "unavailable:\(offset)"
                }
                catalog.merge(
                    tracks: entries.compactMap { entry in
                        entry.value?.model(playlistAddedAt: entry.addedDate.map { [id: $0] })
                    },
                    albums: entries.compactMap { $0.value?.album?.model() })
                restrictedPlaylistIDs.remove(id)
                installPlaylist(after.model(trackIDs: ids))
                mark(key, snapshot: snapshot)
                index.update(playlistID: id, snapshotID: snapshot, trackIDs: ids)
                await publish()
                return
            }
            throw SpotifyError.invalidResponse
        }
    }
    func installPlaylist(_ playlist: MusicPlaylist) {
        if let offset = library.playlists.firstIndex(where: { $0.id == playlist.id }) {
            library.playlists[offset] = playlist
        } else {
            library.playlists.append(playlist)
        }
    }
    func ensureEditablePlaylistsLoaded() async throws {
        try await loadCollection("playlists", force: true)
        for playlist in library.editablePlaylists {
            try await ensurePlaylistLoaded(playlist.id, requireEditable: true)
        }
    }

    func search(_ query: String) async throws -> MusicCatalog {
        try requireConnection()
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cached = searchCache[key], now().timeIntervalSince(cached.date) < 60 {
            return cached.catalog
        }
        let session = sessionGeneration
        let results = try await client.search(key)
        guard !isClosed, session == sessionGeneration else { throw CancellationError() }
        let tracks = results.tracks?.items ?? []
        let albums =
            (results.albums?.items ?? []).map { $0.model() }
            + tracks.compactMap { $0.album?.model() }
        let result = MusicCatalog(
            tracks: tracks.compactMap { $0.model() }, albums: albums,
            artists: results.artists?.items ?? [])
        let current = now()
        var evicted = false
        let beforeCount = searchCache.count
        searchCache = searchCache.filter { current.timeIntervalSince($0.value.date) < 60 }
        if searchCache.count != beforeCount { evicted = true }
        while searchCache.count >= Self.maxCachedSearches,
            let oldest = searchCache.min(by: { $0.value.date < $1.value.date })?.key
        {
            searchCache[oldest] = nil
            evicted = true
        }
        searchCache[key] = (current, result)
        if evicted { pruneDisposableCatalog() }
        catalog.merge(tracks: result.tracks, albums: result.albums, artists: result.artists)
        return result
    }
}
