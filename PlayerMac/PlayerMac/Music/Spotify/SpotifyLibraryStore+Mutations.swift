import Foundation
import MusicCore
import SpotifyWebAPI

extension SpotifyLibraryStore {
    func acquireMutation() async throws {
        await awaitRestore()
        try requireConnection()
        if mutationBusy {
            await withCheckedContinuation { mutationWaiters.append($0) }
        } else {
            mutationBusy = true
        }
        do { try requireConnection() } catch {
            releaseMutation()
            throw error
        }
    }
    func releaseMutation() {
        if mutationWaiters.isEmpty {
            mutationBusy = false
            scheduleRevalidation()
        } else {
            mutationWaiters.removeFirst().resume()
        }
    }
    func settleCompensation() async throws {
        try await acquireMutation()
        defer { releaseMutation() }
        try await compensate()
    }
    func compensate() async throws {
        let affected = Set(favorites.pendingCompensation.flatMap(\.resourceKeys)).union(
            pendingResources)
        guard !affected.isEmpty else {
            _ = try await favorites.apply([], to: library)
            return
        }
        invalidate(affected)
        _ = try await favorites.apply([], to: library)
        invalidate(affected)
        pendingResources.subtract(affected)
        // Compensation changed remote snapshots even when the local values were restored.
        for key in affected {
            resources[key]?.etag = nil
            resources[key]?.expiresAt = .distantPast
            if key.hasPrefix("playlist:") { resources[key]?.isComplete = false }
        }
        rebuildIndex()
        for key in affected.sorted() { try await revalidate(key) }
    }
    func prepare(_ request: MusicFavoriteRequest) async throws {
        switch request {
        case .track(let id, let liked):
            try await loadCollection("liked")
            if (liked ?? !library.likedTrackIDs.contains(id)) == false {
                try await ensureEditablePlaylistsLoaded()
            }
        case .album: try await loadCollection("albums")
        case .artist: try await loadCollection("artists")
        case .membership(_, let id, _): try await ensurePlaylistLoaded(id)
        case .undo(let mutations, let expected):
            for key in Set(mutations.flatMap(\.resourceKeys)).sorted() where key != "playlists" {
                if key.hasPrefix("playlist:") {
                    let id = String(key.dropFirst(9))
                    try await ensurePlaylistLoaded(id)
                    guard let version = expected[id],
                        library.playlists.first(where: { $0.id == id })?.snapshotID == version
                    else {
                        throw SpotifyError.invalidResponse
                    }
                } else {
                    try await loadCollection(key)
                }
            }
        }
    }
    func change(_ request: MusicFavoriteRequest) async throws -> FavoriteChange {
        try await acquireMutation()
        defer { releaseMutation() }
        try await compensate()
        try await prepare(request)
        try requireConnection()
        let change = request.change(in: library)
        try await commit(change.mutations)
        return change
    }
    func apply(_ mutations: [LibraryMutation]) async throws {
        try await acquireMutation()
        defer { releaseMutation() }
        try await compensate()
        try await commit(mutations)
    }
    func invalidate(_ keys: Set<String>) {
        mutationRevision &+= 1
        for key in keys { revisions[key] = mutationRevision }
    }
    func commit(_ mutations: [LibraryMutation]) async throws {
        try requireConnection()
        guard !mutations.isEmpty else { return }
        let keys = Set(mutations.flatMap(\.resourceKeys))
        invalidate(keys)
        pendingResources.formUnion(keys)
        let session = sessionGeneration
        do {
            let next = try await favorites.apply(mutations, to: library)
            guard !isClosed, session == sessionGeneration else { throw CancellationError() }
            if keys.contains("liked") { library.likedTrackIDs = next.likedTrackIDs }
            if keys.contains("albums") { library.savedAlbumIDs = next.savedAlbumIDs }
            if keys.contains("artists") { library.followedArtistIDs = next.followedArtistIDs }
            for playlist in next.playlists where keys.contains("playlist:" + playlist.id) {
                installPlaylist(playlist)
            }
            for key in keys {
                if key == "playlists" {
                    resources[key]?.etag = nil
                    resources[key]?.expiresAt = .distantPast
                    continue
                }
                let snapshot =
                    key.hasPrefix("playlist:")
                    ? library.playlists.first { "playlist:" + $0.id == key }?.snapshotID : nil
                mark(key, ttl: 0, snapshot: snapshot)
            }
            rebuildIndex()
            confirmedMutationSnapshots = Dictionary(
                uniqueKeysWithValues: library.playlists.filter {
                    keys.contains("playlist:" + $0.id)
                }.map { ($0.id, $0.snapshotID) })
            invalidate(keys)
            pendingResources.subtract(keys)
            needsRevalidation.formUnion(keys)
            await publish()
        } catch {
            invalidate(keys)
            if favorites.pendingCompensation.isEmpty { pendingResources.subtract(keys) }
            needsRevalidation.formUnion(keys)
            for key in keys {
                resources[key]?.etag = nil
                resources[key]?.expiresAt = .distantPast
                if key.hasPrefix("playlist:") { resources[key]?.isComplete = false }
            }
            rebuildIndex()
            await publish()
            throw error
        }
    }
    func createPlaylist(title: String, trackID: String) async throws -> MusicPlaylist {
        try await acquireMutation()
        defer { releaseMutation() }
        try await compensate()
        try requireConnection()
        var keys: Set<String> = ["playlists"]
        invalidate(keys)
        pendingResources.formUnion(keys)
        let session = sessionGeneration
        do {
            var playlist: MusicPlaylist
            if let pendingCreation, pendingCreation.title == title,
                pendingCreation.trackID == trackID
            {
                playlist = pendingCreation.playlist
            } else {
                playlist = try await client.createPlaylist(name: title).model()
                guard !isClosed, session == sessionGeneration else { throw CancellationError() }
                pendingCreation = (title, trackID, playlist)
                installPlaylist(playlist)
            }
            keys.insert("playlist:" + playlist.id)
            invalidate(keys)
            pendingResources.formUnion(keys)
            playlist.snapshotID = try await client.insertItems(
                playlistID: playlist.id, uris: ["spotify:track:" + trackID], position: 0)
            guard !isClosed, session == sessionGeneration else { throw CancellationError() }
            playlist.trackIDs = [trackID]
            pendingCreation = nil
            installPlaylist(playlist)
            mark("playlist:" + playlist.id, ttl: 0, snapshot: playlist.snapshotID)
            // Creating one playlist does not imply that the entire collection was loaded.
            resources["playlists"]?.expiresAt = .distantPast
            resources["playlists"]?.etag = nil
            rebuildIndex()
            invalidate(keys)
            pendingResources.subtract(keys)
            needsRevalidation.formUnion(keys)
            await publish()
            return playlist
        } catch {
            invalidate(keys)
            pendingResources.subtract(keys)
            needsRevalidation.formUnion(keys)
            await publish()
            throw error
        }
    }
    func revalidate(_ key: String) async throws {
        if key.hasPrefix("playlist:") {
            try await ensurePlaylistLoaded(String(key.dropFirst(9)))
        } else if ["liked", "albums", "artists", "playlists"].contains(key) {
            try await loadCollection(key, force: true)
        }
    }
    func scheduleRevalidation() {
        guard !isClosed, revalidationTask == nil, !needsRevalidation.isEmpty else { return }
        revalidationTask = Task { [weak self] in
            guard let self else { return }
            let keys = self.needsRevalidation.subtracting(self.pendingResources)
            self.needsRevalidation.subtract(keys)
            for key in keys.sorted() {
                guard !Task.isCancelled, !self.mutationBusy, !self.isClosed else {
                    self.needsRevalidation.formUnion(keys)
                    break
                }
                do {
                    try await SpotifyRequestContext.$priority.withValue(.background) {
                        try await self.revalidate(key)
                    }
                } catch {
                    // Keep confirmed state stale; user retry/refresh observes shared cooldown.
                }
            }
            self.revalidationTask = nil
            if !self.mutationBusy,
                !self.needsRevalidation.subtracting(self.pendingResources).isEmpty
            {
                self.scheduleRevalidation()
            }
        }
    }
}
