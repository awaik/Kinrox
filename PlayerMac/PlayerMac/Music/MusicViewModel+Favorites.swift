import Foundation
import MusicCore

extension MusicViewModel {
    func toggleTrack(_ track: MusicTrack, anchor: String) {
        changeFavorite(.track(track.id, liked: nil), anchor: anchor)
    }
    func setTrackLiked(_ track: MusicTrack, liked: Bool) {
        changeFavorite(.track(track.id, liked: liked))
    }
    func toggleAlbum(_ album: MusicAlbum) { changeFavorite(.album(album.id, saved: nil)) }
    func toggleArtist(_ artist: MusicArtist) { changeFavorite(.artist(artist.id, followed: nil)) }
    func setMembership(trackID: String, playlistID: String, included: Bool) {
        changeFavorite(
            .membership(track: trackID, playlist: playlistID, included: included),
            remembersUndo: false)
    }
    func setFollowed(_ artist: MusicArtist, followed: Bool) {
        changeFavorite(.artist(artist.id, followed: followed), remembersUndo: false)
    }
    func changeFavorite(
        _ request: MusicFavoriteRequest, remembersUndo: Bool = true, anchor: String? = nil
    ) {
        guard canMutate else { return }
        isMutating = true
        let store = store
        // Offline/demo stores are already complete. Real policies wait for resource validation.
        if !(store is SpotifyLibraryStore) {
            let preview = request.change(in: store.library)
            library.apply(preview.mutations)
            showLikeOptions(preview, anchor: anchor)
        }
        Task { [weak self] in
            guard let self else { return }
            defer {
                if self.store === store {
                    self.isMutating = false
                    self.notifyPlayback()
                }
            }
            do {
                let change = try await store.change(request)
                guard self.store === store else { return }
                self.library = store.library
                if remembersUndo {
                    self.undoMutations = change.undo
                    let affected = Set(change.undo.flatMap(\.resourceKeys))
                    self.undoSnapshots =
                        (store as? SpotifyLibraryStore)?.confirmedMutationSnapshots
                        ?? Dictionary(
                            uniqueKeysWithValues: store.library.playlists.filter {
                                affected.contains("playlist:" + $0.id)
                            }.map { ($0.id, $0.snapshotID) })
                }
                self.showLikeOptions(change, anchor: anchor)
                self.statusMessage = nil
                self.confirmFavoriteFeedback(change.mutations)
                self.retryChange = nil
                self.retryPlaylist = nil
            } catch {
                guard self.store === store else { return }
                self.library = store.library
                self.likeOptionsTrackID = nil
                self.likeOptionsAnchor = nil
                self.statusMessage = L10n.text("Could not update favorites.")
                self.retryChange = request
                self.retryPlaylist = nil
            }
        }
    }
    private func showLikeOptions(_ change: FavoriteChange, anchor: String?) {
        guard let anchor else { return }
        let id = change.mutations.compactMap { mutation -> String? in
            if case .trackLiked(let id, true) = mutation { return id }
            return nil
        }.first
        likeOptionsTrackID = change.opensLikeOptions ? id : nil
        likeOptionsAnchor = change.opensLikeOptions ? anchor : nil
    }
    func undo() {
        guard canUndo else { return }
        changeFavorite(.undo(undoMutations, snapshots: undoSnapshots))
    }
    func retry() {
        if let retryChange {
            changeFavorite(retryChange)
        } else if let retryPlaylist {
            createPlaylist(retryPlaylist.title, trackID: retryPlaylist.trackID)
        } else if let retryPlayback {
            retryPlayback()
        } else {
            syncLibrary()
        }
    }
    func createPlaylist(_ title: String, trackID: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, canMutate else { return }
        isMutating = true
        let store = store
        Task { [weak self] in
            guard let self else { return }
            defer {
                if self.store === store {
                    self.isMutating = false
                    self.notifyPlayback()
                }
            }
            do {
                _ = try await store.createPlaylist(title: title, trackID: trackID)
                guard self.store === store else { return }
                self.library = store.library
                self.statusMessage = nil
                self.retryPlaylist = nil
                self.retryChange = nil
            } catch {
                guard self.store === store else { return }
                self.library = store.library
                self.statusMessage = L10n.text("Could not create playlist.")
                self.retryPlaylist = (title, trackID)
                self.retryChange = nil
            }
        }
    }
}
