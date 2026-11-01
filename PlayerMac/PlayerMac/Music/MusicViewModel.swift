import Foundation
import MusicCore
import Observation

@MainActor @Observable
final class MusicViewModel {
    enum Column: Int, CaseIterable { case source, albums, tracks }
    var store: any MusicLibraryStore
    var library: LibrarySnapshot
    var catalog: MusicCatalog
    var selection = BrowserSelection(source: .albums, albumID: "evening")
    var contents: BrowserContents
    var focusedColumn = Column.tracks
    var sortAlbumsByArtist = true
    var focusedTrackID: String?
    var focusedQueueID: UUID?
    var query = ""
    var searchRequested = false
    var isSearching = false
    var likeOptionsTrackID: String?
    var likeOptionsAnchor: String?
    var statusMessage: String?
    var favoriteFeedbackID: UUID?
    var favoriteFeedbackLiked: Bool?
    var disallowedActions: Set<String> = []
    var isMutating = false
    var undoMutations: [LibraryMutation] = []
    var retryChange: FavoriteChange?
    var retryPlaylist: (title: String, trackID: String)?
    var queue = MusicQueue()
    var paused = true
    var position: Double = 84
    var volume: Double = 0
    var isLoading = false
    var accountName: String?
    var searchResults: MusicCatalog?
    @ObservationIgnored var browsingTask: Task<Void, Never>?
    @ObservationIgnored var syncTask: Task<Void, Never>?
    @ObservationIgnored var musicEngine: (any MusicEngine)?
    @ObservationIgnored var engineFactory: (() -> any MusicEngine)?
    @ObservationIgnored weak var coordinator: PlaybackCoordinator?
    @ObservationIgnored var engineTask: Task<Void, Never>?
    @ObservationIgnored var playbackObservers: [UUID: (PlaybackEvent?) -> Void] = [:]
    @ObservationIgnored var lastSnapshot: MusicPlaybackSnapshot?
    @ObservationIgnored var retryPlayback: (() -> Void)?
    var outputName = L10n.text("This Mac")
    var playbackDuration: Double = 0
    var isPlaybackBusy = false
    var acceptsPlayback = true
    var beforeDemoPlayback: () -> Void = {}

    init(store: any MusicLibraryStore = DemoMusicLibraryStore()) {
        self.store = store
        library = store.library
        catalog = store.catalog
        var queue = MusicQueue()
        if let album = store.catalog.albums.first(where: { $0.id == "evening" }) {
            queue.start(store.catalog.tracks(in: album), at: 2)
        }
        self.queue = queue
        contents = BrowserSelection(source: .albums, albumID: "evening").contents(
            catalog: store.catalog, library: store.library, queue: queue)
        focusedTrackID = contents.tracks.first?.id
    }

    var isDemo: Bool { store is DemoMusicLibraryStore }
    var currentTrack: MusicTrack? { queue.current?.track }
    var nextTrack: MusicTrack? { queue.upcoming.first?.track }
    var album: MusicAlbum? { catalog.albums.first { $0.id == selection.albumID } }
    var isQueue: Bool { selection.source == .queue }
    var canUndo: Bool { !undoMutations.isEmpty && !isMutating }
    var currentLiked: Bool { currentTrack.map { library.likedTrackIDs.contains($0.id) } ?? false }

    var sortedAlbums: [MusicAlbum] {
        contents.albums.sorted {
            let lhs = sortAlbumsByArtist ? $0.artistNames : $0.title
            let rhs = sortAlbumsByArtist ? $1.artistNames : $1.title
            return lhs == rhs
                ? $0.year < $1.year : lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    func select(_ source: MusicSource) {
        selection.select(source: source)
        if case .albums = source {
            selection.select(
                albumID: catalog.albums.first { library.savedAlbumIDs.contains($0.id) }?.id)
        }
        refreshContents()
        if case .artist(let id) = source {
            loadSelection(artistID: id)
        } else if let id = selection.albumID {
            loadSelection(albumID: id)
        }
    }

    func selectAlbum(_ id: String?) {
        selection.select(albumID: id)
        refreshContents()
        if let id { loadSelection(albumID: id) }
    }

    func search() {
        if store is SpotifyLibraryStore {
            searchSpotify()
            return
        }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            select(.albums)
        } else {
            select(.search(query))
        }
    }

    func leaveSearch() {
        browsingTask?.cancel()
        searchResults = nil
        query = ""
        isSearching = false
        select(.albums)
    }

    func refreshContents() {
        if case .search = selection.source, let searchResults {
            let tracks =
                selection.albumID.flatMap { id in catalog.albums.first { $0.id == id } }.map {
                    catalog.tracks(in: $0)
                } ?? searchResults.tracks
            contents = BrowserContents(
                albums: searchResults.albums, artists: searchResults.artists, tracks: tracks)
        } else {
            contents = selection.contents(catalog: catalog, library: library, queue: queue)
        }
        focusedTrackID = contents.tracks.first?.id
        focusedQueueID = queue.current?.id
    }

    func toggleTrack(_ track: MusicTrack, anchor: String) {
        let change = FavoritesPolicy.track(
            track.id, liked: !library.likedTrackIDs.contains(track.id), in: library)
        guard !isLoading, !isMutating else { return }
        likeOptionsTrackID = change.opensLikeOptions ? track.id : nil
        likeOptionsAnchor = change.opensLikeOptions ? anchor : nil
        apply(change)
    }

    func toggleAlbum(_ album: MusicAlbum) {
        apply(
            FavoritesPolicy.album(
                album.id, saved: !library.savedAlbumIDs.contains(album.id), in: library))
    }

    func toggleArtist(_ artist: MusicArtist) {
        apply(
            FavoritesPolicy.artist(
                artist.id, followed: !library.followedArtistIDs.contains(artist.id), in: library))
    }

    func setMembership(trackID: String, playlistID: String, included: Bool) {
        apply(
            FavoritesPolicy.membership(
                trackID: trackID, playlistID: playlistID, included: included, in: library),
            remembersUndo: false)
    }

    func setFollowed(_ artist: MusicArtist, followed: Bool) {
        apply(
            FavoritesPolicy.artist(artist.id, followed: followed, in: library), remembersUndo: false
        )
    }

    private func apply(_ change: FavoriteChange, remembersUndo: Bool = true) {
        guard !isLoading, !isMutating, !change.mutations.isEmpty else { return }
        isMutating = true
        let original = library
        let store = store
        library.apply(change.mutations)
        // Keep visible rows frozen until navigation/reload, including a silently unliked row.
        Task { [weak self] in
            guard let self else { return }
            defer {
                if self.store === store {
                    self.isMutating = false
                    self.notifyPlayback()
                }
            }
            do {
                try await store.apply(change.mutations)
                guard self.store === store else { return }
                self.library = store.library
                if remembersUndo { self.undoMutations = change.undo }
                self.statusMessage = nil
                self.confirmFavoriteFeedback(change.mutations)
                self.retryChange = nil
                self.retryPlaylist = nil
                self.notifyPlayback()
            } catch {
                guard self.store === store else { return }
                self.library = original
                self.likeOptionsTrackID = nil
                self.likeOptionsAnchor = nil
                self.statusMessage = L10n.text("Could not update favorites.")
                self.retryChange = change
                self.retryPlaylist = nil
            }
        }
    }

    func undo() {
        guard canUndo else { return }
        apply(FavoriteChange(mutations: undoMutations))
    }

    func retry() {
        if let retryChange {
            apply(retryChange)
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
        guard !title.isEmpty, !isLoading, !isMutating else { return }
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
                self.notifyPlayback()
            } catch {
                guard self.store === store else { return }
                self.statusMessage = L10n.text("Could not create playlist.")
                self.retryPlaylist = (title, trackID)
                self.retryChange = nil
            }
        }
    }

}
