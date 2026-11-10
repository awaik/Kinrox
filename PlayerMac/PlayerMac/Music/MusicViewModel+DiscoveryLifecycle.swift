import Foundation
import MusicCore

enum ListenBrainzPreference {
    static let key = "app.kinrox.music.listenBrainzEnabled"
    static let defaultValue = true

    static func isEnabled(in defaults: UserDefaults?) -> Bool {
        // In-memory models have no persistent connection preferences or network consent.
        guard let defaults else { return false }
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}

/// Owns the notification token without retaining the model. Removal is safe on any thread.
final class MusicDefaultsObservation: @unchecked Sendable {
    private let token: any NSObjectProtocol

    init(changed: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { _ in changed() }
    }

    deinit { NotificationCenter.default.removeObserver(token) }
}

extension MusicViewModel {
    func observeDiscoveryPreferences() {
        guard defaults != nil else { return }
        discoveryDefaultsObservation = MusicDefaultsObservation { [weak self] in
            Task { @MainActor [weak self] in self?.synchronizeDiscoveryConsent() }
        }
    }

    @discardableResult
    func synchronizeDiscoveryConsent() -> Bool {
        guard let defaults else { return false }
        let stored = ListenBrainzPreference.isEnabled(in: defaults)
        guard stored != listenBrainzEnabled else { return false }
        listenBrainzEnabled = stored
        return true
    }

    func observeDiscoveryStore() {
        guard let spotify = store as? SpotifyLibraryStore else { return }
        // Reapply even when the preference is unchanged: Disconnect retires the old store.
        spotify.setListenBrainzEnabled(listenBrainzEnabled)
        spotify.onChange = { [weak self, weak spotify] in
            guard let self, let spotify, self.store === spotify else { return }
            self.acceptLibrary(spotify)
        }
    }

    func loadDiscoverySeed(store: SpotifyLibraryStore, requestID: UUID) async throws {
        let albumID = discoverySeedAlbumID
        let playlistID = discoverySeedPlaylistID
        guard albumID != nil || playlistID != nil else { return }
        if let albumID { try await store.loadAlbum(albumID) }
        if let playlistID {
            do {
                try await store.ensurePlaylistLoaded(playlistID)
            } catch SpotifyPlaylistError.itemsUnavailable {
                // A restricted playlist remains a valid title seed.
            }
        }
        guard !Task.isCancelled, self.store === store, discoveryRequestID == requestID
        else { throw CancellationError() }
        catalog = store.catalog
        library = store.library
        if let albumID, let album = catalog.album(id: albumID) {
            discoverySeedTrack = catalog.tracks(in: album).first
            discoverySeedArtist = album.artists.first ?? discoverySeedTrack?.artists.first
        } else if let playlistID,
            let playlist = library.playlists.first(where: { $0.id == playlistID })
        {
            discoverySeedTrack = playlist.trackIDs.compactMap { catalog.track(id: $0) }.first
            discoverySeedArtist = discoverySeedTrack?.artists.first
        }
        discoverySeedAlbumID = nil
        discoverySeedPlaylistID = nil
    }
}
