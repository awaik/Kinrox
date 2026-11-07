import Foundation
import MusicCore

extension MusicViewModel {
    static let playlistThemes = ["#Cosmic", "#Harp", "#Psybient", "#Techno"]

    func expandLeftSection(_ section: LeftColumnSection) {
        dismissPopovers()
        leftSection = section
        leftFilterQuery = ""
        selectedPlaylistTheme = nil
        discoveredThemePlaylists = []
        if section == .albums {
            openAlbumsOverview()
        }
    }

    func collapseLeftSection() {
        leftSection = .home
        leftFilterQuery = ""
        selectedPlaylistTheme = nil
        discoveredThemePlaylists = []
    }

    func openAlbumsOverview() {
        dismissPopovers()
        if statusMessage
            == L10n.text("Spotify only provides tracks for playlists you own or collaborate on.")
        {
            statusMessage = nil
        }
        isAlbumsOverview = true
        collectionFilterQuery = ""
        selection.select(source: .albums)
        if selection.albumID == nil {
            selection.select(
                albumID: catalog.albums.first { library.savedAlbumIDs.contains($0.id) }?.id)
        }
        persistSelection()
        refreshContents()
    }

    func toggleAlbumCardExpansion(_ albumID: String) {
        if expandedAlbumCardIDs.contains(albumID) {
            expandedAlbumCardIDs.remove(albumID)
        } else {
            expandedAlbumCardIDs.insert(albumID)
            loadSelection(albumID: albumID)
        }
    }

    var filteredLeftPlaylists: [MusicPlaylist] {
        var base = library.playlists
        switch playlistFilter {
        case .all:
            break
        case .mine:
            base = base.filter { $0.isEditable(by: library.userID) }
        case .subscribed:
            base = base.filter { !$0.isEditable(by: library.userID) }
        }
        if let theme = selectedPlaylistTheme {
            let keyword = theme.replacingOccurrences(of: "#", with: "").trimmingCharacters(
                in: .whitespacesAndNewlines)
            let localMatches = base.filter { $0.title.localizedStandardContains(keyword) }
            var combined = localMatches
            for remote in discoveredThemePlaylists
            where !combined.contains(where: { $0.id == remote.id }) {
                combined.append(remote)
            }
            base = combined.isEmpty ? base : combined
        }
        let filter = leftFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return base }
        return base.filter { $0.title.localizedStandardContains(filter) }
    }

    var filteredLeftArtists: [MusicArtist] {
        let filter = leftFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return catalog.artists }
        return catalog.artists.filter { $0.name.localizedStandardContains(filter) }
    }

    var filteredLeftAlbums: [MusicAlbum] {
        let base =
            albumsFilterSavedOnly
            ? catalog.albums.filter { library.savedAlbumIDs.contains($0.id) }
            : catalog.albums
        let sorted = base.sorted {
            let lhs = sortAlbumsByArtist ? $0.artistNames : $0.title
            let rhs = sortAlbumsByArtist ? $1.artistNames : $1.title
            return lhs == rhs
                ? $0.year < $1.year : lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        let filter = leftFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return sorted }
        return sorted.filter {
            $0.title.localizedStandardContains(filter)
                || $0.artistNames.localizedStandardContains(filter)
        }
    }

    var overviewAlbums: [MusicAlbum] {
        let base =
            albumsFilterSavedOnly
            ? catalog.albums.filter { library.savedAlbumIDs.contains($0.id) }
            : catalog.albums
        let sorted = base.sorted {
            let lhs = sortAlbumsByArtist ? $0.artistNames : $0.title
            let rhs = sortAlbumsByArtist ? $1.artistNames : $1.title
            return lhs == rhs
                ? $0.year < $1.year : lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        let filter = collectionFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return sorted }
        return sorted.filter {
            $0.title.localizedStandardContains(filter)
                || $0.artistNames.localizedStandardContains(filter)
        }
    }

    func selectPlaylistTheme(_ theme: String?) {
        if selectedPlaylistTheme == theme {
            selectedPlaylistTheme = nil
            discoveredThemePlaylists = []
            return
        }
        selectedPlaylistTheme = theme
        discoveredThemePlaylists = []
        guard let theme, let store = store as? SpotifyLibraryStore else { return }
        let query = theme.replacingOccurrences(of: "#", with: "")
        Task { [weak self] in
            guard let self else { return }
            if let remote = try? await store.searchPlaylists(query),
                self.store === store, self.selectedPlaylistTheme == theme
            {
                self.discoveredThemePlaylists = remote
            }
        }
    }

    func openSimilar(
        forTrack track: MusicTrack? = nil,
        album: MusicAlbum? = nil,
        playlist: MusicPlaylist? = nil,
        artist: MusicArtist? = nil
    ) {
        dismissPopovers()
        isAlbumsOverview = false
        collectionFilterQuery = ""
        if let track {
            discoverySeedTrack = track
            discoverySeedArtist = track.artists.first
            discoverySeedTitle = "\(track.artistNames) — \(track.title)"
        } else if let album {
            let firstTrack = catalog.tracks(in: album).first
            discoverySeedTrack = firstTrack
            discoverySeedArtist = album.artists.first ?? firstTrack?.artists.first
            discoverySeedTitle = "\(album.artistNames) — \(album.title)"
        } else if let playlist {
            let firstTrack = playlist.trackIDs.compactMap { catalog.track(id: $0) }.first
            discoverySeedTrack = firstTrack
            discoverySeedArtist = firstTrack?.artists.first
            discoverySeedTitle = playlist.title
        } else if let artist {
            discoverySeedTrack = catalog.tracks.first {
                $0.artists.contains { $0.id == artist.id }
            }
            discoverySeedArtist = artist
            discoverySeedTitle = artist.name
        } else if let current = currentTrack {
            discoverySeedTrack = current
            discoverySeedArtist = current.artists.first
            discoverySeedTitle = "\(current.artistNames) — \(current.title)"
        } else {
            let fallback =
                catalog.tracks.first { library.likedTrackIDs.contains($0.id) }
                ?? catalog.tracks.first
            discoverySeedTrack = fallback
            discoverySeedArtist = fallback?.artists.first ?? catalog.artists.first
            discoverySeedTitle =
                fallback.map { "\($0.artistNames) — \($0.title)" }
                ?? L10n.text("Liked tracks")
        }
        selection.select(source: .similar)
        persistSelection()
        refreshDiscovery()
    }

    func setDiscoveryMode(_ mode: MusicDiscoveryMode) {
        guard discoveryMode != mode else { return }
        discoveryMode = mode
        refreshDiscovery()
    }

    func setDiscoveryGenre(_ genre: String?) {
        discoverySelectedGenre = discoverySelectedGenre == genre ? nil : genre
        refreshDiscovery()
    }

    func toggleDiscoveryHideLiked() {
        discoveryHideLiked.toggle()
        refreshDiscovery()
    }

    func addTracksToQueue(_ tracks: [MusicTrack], before destination: UUID? = nil) {
        let playable = tracks.filter { $0.isPlayable != false }
        guard !playable.isEmpty else { return }
        editQueue { _ = $0.insert(playable, before: destination) }
    }

    func insertTrackInQueue(trackID: String, before destination: UUID? = nil) {
        guard let track = catalog.track(id: trackID) else { return }
        addTracksToQueue([track], before: destination)
    }

    func insertAlbumInQueue(_ album: MusicAlbum, before destination: UUID? = nil) {
        let tracks = catalog.tracks(in: album)
        if !tracks.isEmpty,
            !(store is SpotifyLibraryStore) || tracks.count >= album.totalTrackCount
        {
            addTracksToQueue(tracks, before: destination)
            return
        }
        guard let store = store as? SpotifyLibraryStore else {
            addTracksToQueue(tracks, before: destination)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.loadAlbum(album.id)
                guard self.store === store else { return }
                self.catalog = store.catalog
                if let loaded = self.catalog.album(id: album.id) {
                    self.addTracksToQueue(self.catalog.tracks(in: loaded), before: destination)
                }
            } catch is CancellationError {} catch {
                self.statusMessage = SpotifyStatus.message(error)
            }
        }
    }

    func insertPlaylistInQueue(_ playlist: MusicPlaylist, before destination: UUID? = nil) {
        let resolved = library.playlists.first { $0.id == playlist.id } ?? playlist
        let existing = resolved.trackIDs.compactMap { catalog.track(id: $0) }
        if !existing.isEmpty, !(store is SpotifyLibraryStore) {
            addTracksToQueue(existing, before: destination)
            return
        }
        guard let store = store as? SpotifyLibraryStore else {
            addTracksToQueue(existing, before: destination)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.ensurePlaylistLoaded(playlist.id)
                guard self.store === store else { return }
                self.catalog = store.catalog
                self.library = store.library
                let updated = self.library.playlists.first { $0.id == playlist.id } ?? resolved
                let tracks = updated.trackIDs.compactMap { self.catalog.track(id: $0) }
                self.addTracksToQueue(tracks, before: destination)
            } catch is CancellationError {} catch {
                if self.store === store {
                    self.catalog = store.catalog
                    self.library = store.library
                    self.statusMessage = SpotifyStatus.message(error)
                }
            }
        }
    }

    @discardableResult
    func handleQueueDrop(_ payload: String, before destination: UUID? = nil) -> Bool {
        if payload.hasPrefix("track:") {
            insertTrackInQueue(trackID: String(payload.dropFirst(6)), before: destination)
            return true
        }
        if payload.hasPrefix("album:") {
            guard let album = catalog.album(id: String(payload.dropFirst(6))) else { return false }
            insertAlbumInQueue(album, before: destination)
            return true
        }
        if payload.hasPrefix("playlist:") {
            let id = String(payload.dropFirst(9))
            guard
                let playlist = library.playlists.first(where: { $0.id == id })
                    ?? discoveredThemePlaylists.first(where: { $0.id == id })
            else { return false }
            insertPlaylistInQueue(playlist, before: destination)
            return true
        }
        if let sourceID = UUID(uuidString: payload) {
            guard queue.upcoming.contains(where: { $0.id == sourceID }) else { return false }
            moveQueue(sourceID, before: destination)
            return true
        }
        return false
    }

    func moveQueueOffset(_ id: UUID, by delta: Int) {
        editQueue { _ = $0.moveOffset(id, by: delta) }
    }
    func clearManualQueue() { editQueue { $0.clearManual() } }

    func refreshDiscovery() {
        let seedTitle =
            discoverySeedTitle.isEmpty
            ? (currentTrack.map { "\($0.artistNames) — \($0.title)" }
                ?? L10n.text("Liked tracks"))
            : discoverySeedTitle
        let seedTrack = discoverySeedTrack ?? currentTrack ?? catalog.tracks.first
        let seedArtist = discoverySeedArtist ?? seedTrack?.artists.first ?? catalog.artists.first
        let seedTrackIDs: Set<String> = seedTrack.map { [$0.id] } ?? library.likedTrackIDs
        let seedArtistIDs: Set<String> = seedArtist.map { [$0.id] } ?? library.followedArtistIDs

        discoverySnapshot = MusicDiscoveryEngine.build(
            seedTitle: seedTitle,
            seedTrackIDs: seedTrackIDs,
            seedArtistIDs: seedArtistIDs,
            seedArtistName: seedArtist?.name ?? "",
            mode: discoveryMode,
            genres: discoverySnapshot?.genres ?? [],
            selectedGenre: discoverySelectedGenre,
            hideLiked: discoveryHideLiked,
            catalog: catalog,
            library: library)
        refreshContents()

        guard let store = store as? SpotifyLibraryStore else { return }
        let requestID = UUID()
        discoveryRequestID = requestID
        browsingTask?.cancel()
        isDiscovering = true
        let mode = discoveryMode
        let selectedGenre = discoverySelectedGenre
        let hideLiked = discoveryHideLiked
        browsingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.store === store, self.discoveryRequestID == requestID {
                    self.isDiscovering = false
                }
            }
            do {
                let remoteSnapshot = try await store.discover(
                    seedTitle: seedTitle,
                    seedTrack: seedTrack,
                    seedArtist: seedArtist,
                    mode: mode,
                    selectedGenre: selectedGenre,
                    hideLiked: hideLiked)
                guard !Task.isCancelled, self.store === store,
                    self.discoveryRequestID == requestID,
                    self.selection.source == .similar
                else { return }
                self.catalog = store.catalog
                self.discoverySnapshot = remoteSnapshot
                self.refreshContents()
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, self.store === store,
                    self.discoveryRequestID == requestID
                else { return }
                self.statusMessage = SpotifyStatus.message(error)
            }
        }
    }
}
