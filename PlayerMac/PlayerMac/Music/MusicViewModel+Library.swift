import Foundation
import MusicCore

extension MusicViewModel {
    func replaceStore(_ store: any MusicLibraryStore, accountName: String? = nil) {
        browsingTask?.cancel()
        syncTask?.cancel()
        self.store = store
        self.accountName = accountName
        catalog = store.catalog
        library = store.library
        queue = MusicQueue()
        paused = true
        position = 0
        query = ""
        searchResults = nil
        undoMutations = []
        retryChange = nil
        retryPlaylist = nil
        likeOptionsTrackID = nil
        likeOptionsAnchor = nil
        isLoading = false
        isMutating = false
        favoriteFeedbackID = nil
        favoriteFeedbackLiked = nil
        disallowedActions = []
        statusMessage =
            store is DisconnectedMusicLibraryStore ? L10n.text("Connect Spotify in Settings.") : nil
        select(.albums)
        notifyPlayback()
    }

    func syncLibrary() {
        guard let store = store as? SpotifyLibraryStore, !isMutating, !isLoading else { return }
        browsingTask?.cancel()
        isLoading = true
        statusMessage = L10n.text("Loading Spotify library…")
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.store === store { self.isLoading = false } }
            do {
                try await store.refresh()
                guard self.store === store else { return }
                self.library = store.library
                self.catalog = store.catalog
                if self.selection.albumID == nil, self.selection.source == .albums {
                    self.selection.select(
                        albumID: self.catalog.albums.first {
                            self.library.savedAlbumIDs.contains($0.id)
                        }?.id)
                }
                if let id = self.selection.albumID {
                    try await store.loadAlbum(id)
                    self.catalog = store.catalog
                }
                self.statusMessage = nil
                self.refreshContents()
                self.notifyPlayback()
            } catch is CancellationError {} catch {
                if self.store === store { self.statusMessage = SpotifyStatus.message(error) }
            }
        }
    }

    func loadSelection(albumID: String? = nil, artistID: String? = nil) {
        guard let store = store as? SpotifyLibraryStore else { return }
        browsingTask?.cancel()
        let selection = selection
        browsingTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let albumID { try await store.loadAlbum(albumID) }
                if let artistID { try await store.loadArtist(artistID) }
                guard self.store === store, self.selection == selection else { return }
                self.catalog = store.catalog
                self.refreshContents()
            } catch is CancellationError {} catch {
                self.statusMessage = SpotifyStatus.message(error)
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
        selection.select(source: .search(query))
        searchResults = MusicCatalog()
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
