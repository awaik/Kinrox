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
    var retryChange: MusicFavoriteRequest?
    var undoSnapshots: [String: String] = [:]
    var retryPlaylist: (title: String, trackID: String)?
    var queue = MusicQueue()
    var paused = true { didSet { lastPositionTimestamp = .now } }
    var position: Double = 84 { didSet { lastPositionTimestamp = .now } }
    @ObservationIgnored var lastPositionTimestamp = ContinuousClock.now
    @ObservationIgnored var pendingSeek: Double?
    @ObservationIgnored var pendingVolume: Double?
    @ObservationIgnored var seekScheduled = false
    @ObservationIgnored var volumeScheduled = false
    var positionAge: Double {
        guard !paused else { return 0 }
        let elapsed = lastPositionTimestamp.duration(to: .now).components
        return max(0, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
    var displayedPosition: Double {
        min(currentTrack?.duration ?? 0, max(0, position + positionAge))
    }
    var volume: Double = 0
    var volumeKnown = false
    var engineAvailability = MusicEngineAvailability.ready
    var engineNeedsSetup = false
    var isLoading = false
    var isRefreshing = false
    var isInitialLoading: Bool {
        isLoading && (store as? SpotifyLibraryStore)?.isInitialLoading != false
    }
    var canMutate: Bool {
        !isMutating && !isInitialLoading && ((store as? SpotifyLibraryStore)?.isConnected ?? true)
    }
    @ObservationIgnored var sortedAlbumCache:
        (albums: [MusicAlbum], byArtist: Bool, sorted: [MusicAlbum])?
    var accountName: String?
    var searchResults: MusicCatalog?
    @ObservationIgnored var browsingTask: Task<Void, Never>?
    @ObservationIgnored var syncTask: Task<Void, Never>?
    @ObservationIgnored var musicEngine: (any MusicEngine)?
    @ObservationIgnored var engineFactory: (() throws -> any MusicEngine)?
    @ObservationIgnored var engineRecovery: (() -> Void)?
    @ObservationIgnored var engineAvailabilityChanged: ((MusicEngineAvailability) -> Void)?
    @ObservationIgnored weak var coordinator: PlaybackCoordinator?
    @ObservationIgnored var engineTask: Task<Void, Never>?
    @ObservationIgnored var playbackObservers: [UUID: (PlaybackEvent?) -> Void] = [:]
    @ObservationIgnored var lastSnapshot: MusicPlaybackSnapshot?
    @ObservationIgnored var retryPlayback: (() -> Void)?
    @ObservationIgnored var retryPlaybackStartsPlayback = false
    var outputName = L10n.text("This Mac")
    var playbackDuration: Double = 0
    var isPlaybackBusy = false
    var acceptsPlayback = true
    var beforeDemoPlayback: () -> Void = {}

    init(store: any MusicLibraryStore = DemoMusicLibraryStore()) {
        self.store = store
        volumeKnown = store is DemoMusicLibraryStore
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
    var album: MusicAlbum? { selection.albumID.flatMap { catalog.album(id: $0) } }
    var isQueue: Bool { selection.source == .queue }
    var canUndo: Bool { !undoMutations.isEmpty && !isMutating }
    var currentLiked: Bool { currentTrack.map { library.likedTrackIDs.contains($0.id) } ?? false }

    var sortedAlbums: [MusicAlbum] {
        if let cache = sortedAlbumCache, cache.albums == contents.albums,
            cache.byArtist == sortAlbumsByArtist
        {
            return cache.sorted
        }
        let sorted = contents.albums.sorted {
            let lhs = sortAlbumsByArtist ? $0.artistNames : $0.title
            let rhs = sortAlbumsByArtist ? $1.artistNames : $1.title
            return lhs == rhs
                ? $0.year < $1.year : lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        sortedAlbumCache = (contents.albums, sortAlbumsByArtist, sorted)
        return sorted
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
        } else if case .playlist(let id) = source {
            loadSelection(playlistID: id)
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
                selection.albumID.flatMap { id in catalog.album(id: id) }.map {
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

}
