import Foundation
import MetaBrainzAPI
import MusicCore
import OSLog
import SpotifyWebAPI

@MainActor
final class SpotifyLibraryStore: MusicLibraryStore {
    var catalog = MusicCatalog()
    var library: LibrarySnapshot
    let client: SpotifyClient
    let favorites: FavoritesService
    let cache: SpotifyCacheStore?
    let now: @Sendable () -> Date
    var index = PlaylistMembershipIndex()
    var resources: [String: SpotifyResourceState] = [:]
    var tasks: [String: Task<Void, any Error>] = [:]
    var subscriptions: [String: Set<UUID>] = [:]
    var sessionGeneration = UUID()
    var mutationRevision: UInt64 = 0
    var revisions: [String: UInt64] = [:]
    var pendingResources = Set<String>()
    var needsRevalidation = Set<String>()
    var revalidationTask: Task<Void, Never>?
    var mutationBusy = false
    var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    var publicationRevision: UInt64 = 0
    var isClosed = false
    var isConnected: Bool {
        didSet { if oldValue != isConnected { onChange?() } }
    }
    var isRefreshing = false
    var isRestoring = false
    var restoreWaiters: [CheckedContinuation<Void, Never>] = []
    var cacheIsStale = false
    var onChange: (() -> Void)?
    var queuePlaylistID: String?
    static let maxCachedSearches = 10
    var confirmedMutationSnapshots: [String: String] = [:]
    var pendingCreation: (title: String, trackID: String, playlist: MusicPlaylist)?
    var searchCache: [String: (date: Date, catalog: MusicCatalog)] = [:]
    var recentDiscoveryTrackIDs = Set<String>()
    var recentDiscoveryAlbumIDs = Set<String>()
    var embeddedAlbums: [String: SpotifyAlbum] = [:]
    var restrictedPlaylistIDs = Set<String>()
    var discoveryCache: [String: (date: Date, value: SpotifyDiscoveryData)] = [:]
    var playHistory: [MusicPlayHistoryEntry] = []
    var listenBrainzStatus = MusicListenBrainzStatus.off
    var metaBrainzClient: MetaBrainzClient?
    var metaBrainzFactory: (() -> MetaBrainzClient)?
    var listenBrainzEnabled = false
    var consentGeneration = UUID()

    init(
        client: SpotifyClient, profile: SpotifyProfile? = nil, cache: SpotifyCacheStore? = nil,
        connected: Bool = true, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.cache = cache
        self.now = now
        self.isConnected = connected
        library = LibrarySnapshot(userID: profile?.id ?? "")
        favorites = FavoritesService(client: client)
    }

    var isInitialLoading: Bool {
        !resources[
            "albums",
            default: .init(isComplete: false, fetchedAt: .distantPast, expiresAt: .distantPast)
        ].isComplete
    }

    func restore() async {
        guard let cache else { return }
        let session = sessionGeneration
        isRestoring = true
        defer {
            isRestoring = false
            let waiters = restoreWaiters
            restoreWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if !isClosed, session == sessionGeneration { onChange?() }
        }
        do {
            await cache.activate(session)
            let preview = try await cache.preview()
            guard !isClosed, session == sessionGeneration else { return }
            install(preview)
            let restored = try await cache.restore()
            guard !isClosed, session == sessionGeneration else { return }
            install(restored, notify: false)
            let history = try await cache.playHistory()
            guard !isClosed, session == sessionGeneration else { return }
            let restoredIDs = Set(history.map(\.id))
            playHistory = MusicPlayHistoryEntry.retained(
                history + playHistory.filter { !restoredIDs.contains($0.id) },
                now: now())
        } catch is CancellationError {} catch { cacheFailure() }
    }

    func install(_ snapshot: SpotifyCachedLibrary, notify: Bool = true) {
        library = snapshot.library
        catalog = snapshot.catalog
        resources = snapshot.resources
        let excludedIDs = Set(
            library.playlists.filter {
                isExcludedQueuePlaylist(id: $0.id, title: $0.title, ownerID: $0.ownerID)
            }.map(\.id)
        ).union(queuePlaylistID.map { [$0] } ?? [])
        if !excludedIDs.isEmpty {
            library.playlists.removeAll { excludedIDs.contains($0.id) }
            for id in excludedIDs { resources["playlist:" + id] = nil }
        }
        rebuildIndex()
        if notify { onChange?() }
    }
    func awaitRestore() async {
        if isRestoring { await withCheckedContinuation { restoreWaiters.append($0) } }
    }

    func retire() {
        isClosed = true
        isConnected = false
        sessionGeneration = UUID()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        revalidationTask?.cancel()
        revalidationTask = nil
        searchCache.removeAll()
        recentDiscoveryTrackIDs.removeAll()
        recentDiscoveryAlbumIDs.removeAll()
        embeddedAlbums.removeAll()
        restrictedPlaylistIDs.removeAll()
        onChange = nil
        discoveryCache.removeAll()
        playHistory.removeAll()
        setListenBrainzEnabled(false)
    }

    func excludeQueuePlaylist(_ id: String) {
        queuePlaylistID = id
        library.playlists.removeAll { $0.id == id }
        resources["playlist:" + id] = nil
        rebuildIndex()
    }

    func isExcludedQueuePlaylist(id: String, title: String, ownerID: String) -> Bool {
        if id == queuePlaylistID { return true }
        return title == "Kinrox Queue" && !library.userID.isEmpty && ownerID == library.userID
    }

    func refresh() async throws {
        guard !isRefreshing else { return }
        try requireConnection()
        isRefreshing = true
        defer { isRefreshing = false }
        try await settleCompensation()
        if library.userID.isEmpty { library.userID = try await client.profile().id }
        try await SpotifyRequestContext.$priority.withValue(.background) {
            async let albums: Void = loadCollection("albums", force: true)
            async let playlists: Void = loadCollection("playlists", force: true)
            _ = try await (albums, playlists)
            async let liked: Void = loadCollection("liked", force: true)
            async let artists: Void = loadCollection("artists", force: true)
            _ = try await (liked, artists)
            for playlist in library.editablePlaylists {
                try Task.checkCancellation()
                if resources["playlist:" + playlist.id]?.snapshotID != playlist.snapshotID
                    || resources["playlist:" + playlist.id]?.isComplete != true
                {
                    try await ensurePlaylistLoaded(playlist.id, requireEditable: true)
                }
            }
        }
    }

    func requireConnection() throws {
        guard !isClosed, isConnected else { throw SpotifyError.authentication }
        try Task.checkCancellation()
    }
    func fresh(_ key: String) -> Bool { resources[key]?.isFresh(at: now()) == true }
    func mark(_ key: String, ttl: TimeInterval = 300, etag: String? = nil, snapshot: String? = nil)
    {
        resources[key] = SpotifyResourceState(
            etag: etag, snapshotID: snapshot,
            fetchedAt: now(), expiresAt: now().addingTimeInterval(ttl))
    }
    func stamp(_ key: String) -> String {
        "\(sessionGeneration):\(key):\(revisions[key, default: 0])"
    }
    func accepts(_ key: String, stamp: String) -> Bool {
        let valid =
            !Task.isCancelled && !isClosed && self.stamp(key) == stamp
            && !pendingResources.contains(key)
        if !valid, !isClosed { needsRevalidation.insert(key) }
        return valid
    }
    func shared(_ key: String, operation: @escaping @MainActor () async throws -> Void) async throws
    {
        try requireConnection()
        let taskKey = stamp(key)
        let subscriber = UUID()
        let task: Task<Void, any Error>
        if let existing = tasks[taskKey], !existing.isCancelled {
            task = existing
        } else {
            task = Task {
                try await SpotifyRequestContext.$revision.withValue(taskKey, operation: operation)
            }
            tasks[taskKey] = task
        }
        subscriptions[taskKey, default: []].insert(subscriber)
        defer { detach(subscriber, from: taskKey) }
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in self?.detach(subscriber, from: taskKey) }
        }
    }
    func detach(_ subscriber: UUID, from key: String) {
        guard subscriptions[key]?.remove(subscriber) != nil else { return }
        if subscriptions[key]?.isEmpty == true {
            tasks[key]?.cancel()
            tasks[key] = nil
            subscriptions[key] = nil
        }
    }
    func publish() async {
        guard !isClosed else { return }
        onChange?()
        guard let cache else { return }
        publicationRevision &+= 1
        let value = SpotifyCachedLibrary(library: library, catalog: catalog, resources: resources)
        do {
            try await cache.save(value, revision: publicationRevision, session: sessionGeneration)
        } catch { cacheFailure() }
    }
    func cacheFailure() {
        cacheIsStale = true
        Logger(subsystem: "app.kinrox.player", category: "SpotifyCache")
            .error("Spotify metadata cache unavailable; confirmed session state retained.")
    }
    func rebuildIndex() {
        index = PlaylistMembershipIndex()
        for playlist in library.playlists
        where resources["playlist:" + playlist.id]?.isComplete == true {
            index.update(
                playlistID: playlist.id, snapshotID: playlist.snapshotID,
                trackIDs: playlist.trackIDs)
        }
    }

    func pruneDisposableCatalog(
        pinnedTrackIDs: Set<String> = [],
        pinnedAlbumIDs: Set<String> = [],
        pinnedArtistIDs: Set<String> = []
    ) {
        let current = now()
        searchCache = searchCache.filter { current.timeIntervalSince($0.value.date) < 60 }
        var trackIDs = library.likedTrackIDs
            .union(recentDiscoveryTrackIDs)
            .union(pinnedTrackIDs)
        for playlist in library.playlists { trackIDs.formUnion(playlist.trackIDs) }
        if let pending = pendingCreation { trackIDs.insert(pending.trackID) }
        for entry in searchCache.values {
            trackIDs.formUnion(entry.catalog.tracks.map(\.id))
        }
        var albumIDs = library.savedAlbumIDs
            .union(recentDiscoveryAlbumIDs)
            .union(pinnedAlbumIDs)
            .union(embeddedAlbums.keys)
        for entry in searchCache.values {
            albumIDs.formUnion(entry.catalog.albums.map(\.id))
        }
        for album in catalog.albums {
            if resources["album:" + album.id] != nil
                || album.artists.contains(where: { resources["artist:" + $0.id] != nil })
            {
                albumIDs.insert(album.id)
            }
        }
        for track in catalog.tracks where trackIDs.contains(track.id) {
            albumIDs.insert(track.albumID)
        }
        for album in catalog.albums where albumIDs.contains(album.id) {
            trackIDs.formUnion(album.trackIDs)
        }
        let tracks = catalog.tracks.filter { trackIDs.contains($0.id) }
        let albums = catalog.albums.filter { albumIDs.contains($0.id) }
        var artistIDs = library.followedArtistIDs.union(pinnedArtistIDs)
        for key in resources.keys where key.hasPrefix("artist:") {
            artistIDs.insert(String(key.dropFirst(7)))
        }
        for entry in searchCache.values {
            artistIDs.formUnion(entry.catalog.artists.map(\.id))
        }
        for track in tracks {
            for artist in track.artists { artistIDs.insert(artist.id) }
        }
        for album in albums {
            for artist in album.artists { artistIDs.insert(artist.id) }
        }
        let artists = catalog.artists.filter { artistIDs.contains($0.id) }
        guard
            tracks.count != catalog.tracks.count
                || albums.count != catalog.albums.count
                || artists.count != catalog.artists.count
        else { return }
        catalog = MusicCatalog(tracks: tracks, albums: albums, artists: artists)
    }
}
