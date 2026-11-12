import Foundation
import MusicCore
import Observation

@MainActor @Observable
final class MusicPopoverState {
    var likeOptionsTrackID: String?
    var likeOptionsAnchor: String?
    var previewAlbumID: String?
    var previewAlbumTrack: MusicTrack?
    var previewAlbumAnchor: String?
    var previewArtists: [MusicArtist] = []
    var previewArtistID: String?
    var previewArtistAnchor: String?
}

@MainActor @Observable
final class MusicFocusState {
    var focusedColumn = MusicViewModel.Column.tracks
    var focusedTrackID: String?
    var focusedQueueID: UUID?
}

@MainActor @Observable
final class MusicViewModel {
    enum Column: Int, CaseIterable { case source, albums, tracks }
    enum LeftColumnSection: String, CaseIterable, Sendable {
        case home, playlists, artists, albums
    }
    enum PlaylistOwnershipFilter: String, CaseIterable, Sendable {
        case all, mine, subscribed
    }
    var store: any MusicLibraryStore
    var library: LibrarySnapshot
    var catalog: MusicCatalog
    var selection = BrowserSelection(source: .albums, albumID: "evening") {
        didSet {
            if oldValue.source == .similar, selection.source != .similar {
                releaseDiscoveryWorkspace()
            }
        }
    }
    private(set) var isWorkspaceActive = true
    @ObservationIgnored var discoveryNeedsRefresh = false

    func setWorkspaceActive(_ active: Bool) {
        guard isWorkspaceActive != active else { return }
        isWorkspaceActive = active
        workspaceActivityChanged()
    }
    var contents: BrowserContents
    @ObservationIgnored let focus = MusicFocusState()
    @ObservationIgnored let popovers = MusicPopoverState()
    var focusedColumn: Column {
        get { focus.focusedColumn }
        set { focus.focusedColumn = newValue }
    }
    var leftSection = LeftColumnSection.home
    var leftFilterQuery = ""
    var playlistFilter = PlaylistOwnershipFilter.all
    var selectedPlaylistTheme: String?
    var discoveredThemePlaylists: [MusicPlaylist] = []
    var isAlbumsOverview = false
    var albumsFilterSavedOnly = true
    var expandedAlbumCardIDs: Set<String> = []
    var collectionFilterQuery = ""
    var discoverySnapshot: MusicDiscoverySnapshot?
    var discoveryMode = MusicDiscoveryMode.sameSpirit
    var discoveryHideLiked = false
    var discoverySelectedGenre: String?
    var discoverySeedTitle = ""
    var discoverySeedTrack: MusicTrack?
    var discoverySeedArtist: MusicArtist?
    var isDiscovering = false
    @ObservationIgnored var discoveryHasConnectedRefresh = false
    @ObservationIgnored var discoverySnapshotConsent = false
    @ObservationIgnored var discoveryDefaultsObservation: MusicDefaultsObservation?
    @ObservationIgnored var discoverySeedAlbumID: String?
    @ObservationIgnored var discoverySeedPlaylistID: String?
    var discoverySeedHistory: [MusicDiscoverySeed] = []
    @ObservationIgnored var discoveryHistoryTracks: [String: MusicTrack] = [:]
    @ObservationIgnored var discoveryHistoryArtists: [String: MusicArtist] = [:]
    var notInterestedTrackIDs: Set<String> = []
    var notInterestedArtistIDs: Set<String> = []
    var notInterestedUndo: [(track: String?, artist: String?)] = []
    var listenBrainzEnabled = ListenBrainzPreference.defaultValue {
        didSet {
            guard oldValue != listenBrainzEnabled else { return }
            defaults?.set(listenBrainzEnabled, forKey: ListenBrainzPreference.key)
            (store as? SpotifyLibraryStore)?.setListenBrainzEnabled(listenBrainzEnabled)
            listenBrainzStatus = listenBrainzEnabled ? .ready : .off
            if selection.source == .similar { refreshAutomaticDiscovery() }
        }
    }
    var listenBrainzStatus = MusicListenBrainzStatus.off
    var isDiscoveryRadioActive = false
    var isRefillingRadio = false
    /// A remote-initiated Similar start is looking for its first tracks.
    var isStartingSimilar = false
    @ObservationIgnored var radioSessionID = UUID()
    @ObservationIgnored var radioRefillTask: Task<Void, Never>?
    @ObservationIgnored var radioSeenTrackIDs: Set<String> = []
    @ObservationIgnored var radioSeenDedupeKeys: Set<String> = []
    @ObservationIgnored var radioAttemptedOccurrences: Set<UUID> = []
    @ObservationIgnored var radioDiscoveryProvider:
        ((MusicTrack) async throws -> MusicDiscoverySnapshot)?
    var playHistory: [MusicPlayHistoryEntry] = []
    @ObservationIgnored var activePlaySession: MusicActivePlaySession?
    @ObservationIgnored var listeningSessionID = UUID()
    @ObservationIgnored var lastCompletedTrackID: String?
    @ObservationIgnored var historyNow: () -> Date = { Date() }

    var sortAlbumsByArtist = true
    var focusedTrackID: String? {
        get { focus.focusedTrackID }
        set { focus.focusedTrackID = newValue }
    }
    var focusedQueueID: UUID? {
        get { focus.focusedQueueID }
        set { focus.focusedQueueID = newValue }
    }
    var query = ""
    var searchRequested = false
    var isSearching = false
    var likeOptionsTrackID: String? {
        get { popovers.likeOptionsTrackID }
        set { popovers.likeOptionsTrackID = newValue }
    }
    var likeOptionsAnchor: String? {
        get { popovers.likeOptionsAnchor }
        set { popovers.likeOptionsAnchor = newValue }
    }
    var previewAlbumID: String? {
        get { popovers.previewAlbumID }
        set { popovers.previewAlbumID = newValue }
    }
    var previewAlbumTrack: MusicTrack? {
        get { popovers.previewAlbumTrack }
        set { popovers.previewAlbumTrack = newValue }
    }
    var previewAlbumAnchor: String? {
        get { popovers.previewAlbumAnchor }
        set { popovers.previewAlbumAnchor = newValue }
    }
    var previewArtists: [MusicArtist] {
        get { popovers.previewArtists }
        set { popovers.previewArtists = newValue }
    }
    var previewArtistID: String? {
        get { popovers.previewArtistID }
        set { popovers.previewArtistID = newValue }
    }
    var previewArtistAnchor: String? {
        get { popovers.previewArtistAnchor }
        set { popovers.previewArtistAnchor = newValue }
    }
    var trackSortOrders: [String: TrackSortOrder] = [:]
    var rememberedTrackIDs: [String: String] = [:]
    @ObservationIgnored let defaults: UserDefaults?
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
    @ObservationIgnored var discoveryRequestID = UUID()
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

    init(
        store: any MusicLibraryStore = DemoMusicLibraryStore(), defaults: UserDefaults? = nil,
        workspaceActive: Bool = true
    ) {
        isWorkspaceActive = workspaceActive
        self.store = store
        self.defaults = defaults
        trackSortOrders = Self.loadPersistedSortOrders(from: defaults)
        rememberedTrackIDs = Self.loadPersistedRememberedTracks(from: defaults)
        volumeKnown = store is DemoMusicLibraryStore
        acceptsPlayback = !(store is DisconnectedMusicLibraryStore)
        statusMessage =
            store is DisconnectedMusicLibraryStore ? L10n.text("Connect Spotify in Settings.") : nil
        library = store.library
        catalog = store.catalog
        var queue = MusicQueue()
        if let album = store.catalog.albums.first(where: { $0.id == "evening" }) {
            queue.start(store.catalog.tracks(in: album), at: 2)
        }
        self.queue = queue
        let initialAlbumID =
            store.catalog.albums.first(where: { $0.id == "evening" })?.id
            ?? store.catalog.albums.first { store.library.savedAlbumIDs.contains($0.id) }?.id
        var initialSelection = BrowserSelection(source: .albums, albumID: initialAlbumID)
        if !(store is DisconnectedMusicLibraryStore),
            let persisted = Self.loadPersistedSelection(from: defaults)
        {
            initialSelection = persisted
            if case .albums = initialSelection.source, initialSelection.albumID == nil {
                initialSelection.select(albumID: initialAlbumID)
            }
        }
        selection = initialSelection
        contents = BrowserContents(albums: [], artists: [], tracks: [])
        listenBrainzEnabled = ListenBrainzPreference.isEnabled(in: defaults)
        listenBrainzStatus = listenBrainzEnabled ? .ready : .off
        notInterestedTrackIDs = Set(
            defaults?.stringArray(forKey: "app.kinrox.music.notInterestedTracks") ?? [])
        notInterestedArtistIDs = Set(
            defaults?.stringArray(forKey: "app.kinrox.music.notInterestedArtists") ?? [])
        (store as? SpotifyLibraryStore)?.setListenBrainzEnabled(listenBrainzEnabled)
        refreshContents()
        observeDiscoveryPreferences()
        observeDiscoveryStore()
        if selection.source == .similar { refreshAutomaticDiscovery() }
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
        dismissPopovers()
        if statusMessage
            == L10n.text("Spotify only provides tracks for playlists you own or collaborate on.")
        {
            statusMessage = nil
        }
        isAlbumsOverview = (source == .albums)
        collectionFilterQuery = ""
        selection.select(source: source)
        if case .albums = source {
            selection.select(
                albumID: catalog.albums.first { library.savedAlbumIDs.contains($0.id) }?.id)
        }
        persistSelection()
        if case .similar = source, discoverySnapshot == nil {
            refreshDiscovery()
        }
        refreshContents()
        if case .artist(let id) = source {
            if contents.albums.count == 1, contents.tracks.isEmpty {
                selection.select(albumID: contents.albums[0].id)
                refreshContents()
            }
            loadSelection(artistID: id)
        } else if case .playlist(let id) = source {
            loadSelection(playlistID: id)
        } else if let id = selection.albumID {
            loadSelection(albumID: id)
        }
    }

    func selectAlbum(_ id: String?) {
        dismissPopovers()
        isAlbumsOverview = false
        collectionFilterQuery = ""
        if selection.source != .albums && selection.source != .artist("") {
            if case .artist = selection.source {
            } else if case .search = selection.source {
            } else {
                selection.select(source: .albums)
            }
        }
        selection.select(albumID: id)
        persistSelection()
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
        let rawContents: BrowserContents
        if case .search = selection.source, let searchResults {
            let tracks =
                selection.albumID.flatMap { id in catalog.album(id: id) }.map {
                    catalog.tracks(in: $0)
                } ?? searchResults.tracks
            rawContents = BrowserContents(
                albums: searchResults.albums, artists: searchResults.artists, tracks: tracks)
        } else if case .similar = selection.source, let discoverySnapshot {
            rawContents = BrowserContents(
                albums: catalog.albums, artists: catalog.artists,
                tracks: discoverySnapshot.displayTracks)
        } else {
            rawContents = selection.contents(catalog: catalog, library: library, queue: queue)
        }
        var sorted =
            selection.source == .similar ? rawContents.tracks : sortedTracks(rawContents.tracks)
        let filter = collectionFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !filter.isEmpty {
            sorted = sorted.filter { track in
                track.title.localizedStandardContains(filter)
                    || track.albumTitle.localizedStandardContains(filter)
                    || track.artists.contains { $0.name.localizedStandardContains(filter) }
            }
        }
        contents = BrowserContents(
            albums: rawContents.albums, artists: rawContents.artists, tracks: sorted)
        if let remembered = rememberedTrackID(for: selection),
            sorted.contains(where: { $0.id == remembered })
        {
            focusedTrackID = remembered
        } else {
            focusedTrackID = sorted.first?.id
        }
        focusedQueueID = queue.current?.id
    }

}
