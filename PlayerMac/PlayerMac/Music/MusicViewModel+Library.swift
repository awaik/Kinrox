import Foundation
import MusicCore

extension MusicViewModel {
    func replaceStore(_ store: any MusicLibraryStore, accountName: String? = nil) {
        stopDiscoveryRadio()
        finishPlayHistory()
        playHistory = []
        listeningSessionID = UUID()
        lastCompletedTrackID = nil
        discoverySeedHistory = []
        discoveryHistoryTracks = [:]
        discoveryHistoryArtists = [:]
        discoverySeedTrack = nil
        discoverySeedArtist = nil
        discoverySeedTitle = ""
        discoverySeedAlbumID = nil
        discoverySeedPlaylistID = nil
        discoveryHasConnectedRefresh = false
        discoverySelectedGenre = nil
        discoveryRequestID = UUID()
        browsingTask?.cancel()
        syncTask?.cancel()
        (self.store as? SpotifyLibraryStore)?.onChange = nil
        self.store = store
        _ = synchronizeDiscoveryConsent()
        listenBrainzStatus = listenBrainzEnabled ? .ready : .off
        observeDiscoveryStore()
        if store is DisconnectedMusicLibraryStore {
            notInterestedTrackIDs.removeAll()
            notInterestedArtistIDs.removeAll()
            notInterestedUndo.removeAll()
            defaults?.removeObject(forKey: "app.kinrox.music.notInterestedTracks")
            defaults?.removeObject(forKey: "app.kinrox.music.notInterestedArtists")
        }
        self.accountName = accountName
        catalog = store.catalog
        library = store.library
        queue = MusicQueue()
        paused = true
        position = 0
        volume = 0
        volumeKnown = store is DemoMusicLibraryStore
        engineAvailability = .ready
        lastSnapshot = nil
        query = ""
        searchResults = nil
        leftSection = .home
        leftFilterQuery = ""
        playlistFilter = .all
        selectedPlaylistTheme = nil
        discoveredThemePlaylists = []
        isAlbumsOverview = false
        collectionFilterQuery = ""
        discoverySnapshot = nil
        isDiscovering = false
        undoMutations = []
        undoSnapshots = [:]
        retryChange = nil
        retryPlaylist = nil
        dismissPopovers()
        isLoading = false
        isRefreshing = false
        isMutating = false
        pendingSeek = nil
        pendingVolume = nil
        seekScheduled = false
        volumeScheduled = false
        favoriteFeedbackID = nil
        favoriteFeedbackLiked = nil
        disallowedActions = []
        acceptsPlayback = !(store is DisconnectedMusicLibraryStore)
        statusMessage =
            store is DisconnectedMusicLibraryStore ? L10n.text("Connect Spotify in Settings.") : nil
        if !(store is DisconnectedMusicLibraryStore),
            let persisted = Self.loadPersistedSelection(from: defaults)
        {
            selection = persisted
            if case .albums = selection.source, selection.albumID == nil {
                selection.select(
                    albumID: catalog.albums.first { library.savedAlbumIDs.contains($0.id) }?.id)
            }
            refreshContents()
            if selection.source == .similar { refreshAutomaticDiscovery() }
            if case .artist(let id) = selection.source {
                loadSelection(artistID: id)
            } else if case .playlist(let id) = selection.source {
                loadSelection(playlistID: id)
            } else if let id = selection.albumID {
                loadSelection(albumID: id)
            }
        } else {
            select(.albums)
        }
        notifyPlayback()
    }

    var preservesLikedRows: Bool {
        selection.source == .liked && !isRefreshing
            && (store as? SpotifyLibraryStore)?.isRestoring != true
            && contents.tracks.contains { !library.likedTrackIDs.contains($0.id) }
    }

    func acceptLibrary(_ store: SpotifyLibraryStore) {
        let preservesLiked = preservesLikedRows
        let updatesRows =
            isRefreshing || catalog != store.catalog || (!isMutating && library != store.library)
        if !isMutating { library = store.library }
        catalog = store.catalog
        isLoading = store.isInitialLoading && isRefreshing
        if selection.albumID == nil, selection.source == .albums {
            selection.select(
                albumID: catalog.albums.first { library.savedAlbumIDs.contains($0.id) }?.id)
            if let id = selection.albumID, store.embeddedAlbums[id] != nil {
                loadSelection(albumID: id)
            }
        }
        if updatesRows, !preservesLiked, !preservesLikedRows {
            refreshContents()
        }
        if selection.source == .similar, !isDiscovering,
            discoverySnapshot == nil || !discoveryHasConnectedRefresh
        {
            refreshAutomaticDiscovery()
        }
        notifyPlayback()
    }

    func syncLibrary() {
        guard let store = store as? SpotifyLibraryStore, !isRefreshing else { return }
        isRefreshing = true
        isLoading = store.isInitialLoading
        statusMessage = L10n.text("Loading Spotify library…")
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.store === store {
                    self.isLoading = false
                    self.isRefreshing = false
                }
            }
            do {
                try await store.refresh()
                guard self.store === store else { return }
                self.acceptLibrary(store)
                if let id = self.selection.albumID { try await store.loadAlbum(id) }
                self.statusMessage = nil
                if self.selection.source == .similar, !self.isDiscovering {
                    self.refreshAutomaticDiscovery()
                }
            } catch is CancellationError {} catch {
                if self.store === store { self.statusMessage = SpotifyStatus.message(error) }
            }
        }
    }

    func loadSelection(
        albumID: String? = nil, artistID: String? = nil, playlistID: String? = nil
    ) {
        guard let store = store as? SpotifyLibraryStore else { return }
        browsingTask?.cancel()
        let selection = selection
        browsingTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let albumID { try await store.loadAlbum(albumID) }
                if let artistID {
                    try await store.loadArtist(artistID)
                    let artistAlbums = store.catalog.albums.filter {
                        $0.artists.contains { $0.id == artistID }
                    }
                    let hasArtistTracks = store.catalog.tracks.contains {
                        $0.artists.contains { $0.id == artistID }
                    }
                    if let firstAlbum = artistAlbums.first,
                        artistAlbums.count == 1 || !hasArtistTracks,
                        firstAlbum.trackIDs.isEmpty
                    {
                        try? await store.loadAlbum(firstAlbum.id)
                    }
                }
                if let playlistID { try await store.ensurePlaylistLoaded(playlistID) }
                guard self.store === store, self.selection == selection else { return }
                self.catalog = store.catalog
                self.library = store.library
                if self.statusMessage
                    == L10n.text(
                        "Spotify only provides tracks for playlists you own or collaborate on.")
                {
                    self.statusMessage = nil
                }
                self.refreshContents()
            } catch is CancellationError {} catch {
                guard self.store === store, self.selection == selection else { return }
                self.catalog = store.catalog
                self.library = store.library
                self.statusMessage = SpotifyStatus.message(error)
                self.refreshContents()
            }
        }
    }

    func searchSpotify() {
        guard let store = store as? SpotifyLibraryStore else { return }
        browsingTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = nil
            select(.albums)
            return
        }
        isAlbumsOverview = false
        if selection.source != .search(query) {
            collectionFilterQuery = ""
            searchResults = MusicCatalog()
        }
        selection.select(source: .search(query))
        refreshContents()
        browsingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                let results = try await store.search(query)
                guard self.store === store, self.selection.source == .search(query) else { return }
                self.catalog = store.catalog
                self.searchResults = results
                self.statusMessage = nil
                self.refreshContents()
            } catch is CancellationError {} catch {
                self.statusMessage = SpotifyStatus.message(error)
            }
        }
    }
}
