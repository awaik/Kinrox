import Foundation
import RemoteProtocol

/// Read-only remote projection of MediaLibraryStore and RecentFilesStore.
/// Materializes grouped catalog and opaque IDs per `libraryRevision`; reads live WatchProgress per page.
@MainActor
final class RemoteLibraryBridge {
    let store: MediaLibraryStore
    let recents: RecentFilesStore
    let ids: RemoteLibraryIDs
    let artworkService: RemoteArtworkService
    weak var localAudio: LocalAudioViewModel?
    var changed: (() -> Void)?
    var isVideoPlaying: () -> Bool = { false }
    var currentVideoPath: () -> String? = { nil }
    var currentVideoTracks: () -> [MediaTrack] = { [] }

    private(set) var libraryRevision = UUID()
    private(set) var progressRevision = UUID()
    private(set) var progressPageRevision = UUID()
    private var cachedIndex: CatalogIndex?
    var hasConnectedClients: () -> Bool = { true }
    var hasCachedIndex: Bool { cachedIndex != nil }
    var index: CatalogIndex { ensureIndex() }

    private let now: () -> TimeInterval
    private let progressCoalesceInterval: TimeInterval
    private let metadataCoalesceInterval: TimeInterval
    private var storeObserver: UUID?
    private var recentObserver: UUID?
    private var lastProgressBump = -Double.infinity
    private var pendingProgressBump = false
    private var progressCoalesceTask: Task<Void, Never>?
    private var pendingMetadataBump = false
    private var metadataCoalesceTask: Task<Void, Never>?

    init(
        store: MediaLibraryStore, recents: RecentFilesStore, defaults: UserDefaults,
        localAudio: LocalAudioViewModel? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        progressCoalesceInterval: TimeInterval = 10,
        metadataCoalesceInterval: TimeInterval = 5
    ) {
        self.store = store
        self.recents = recents
        self.ids = RemoteLibraryIDs(defaults: defaults)
        self.artworkService = RemoteArtworkService(artwork: store.artwork)
        self.localAudio = localAudio
        self.now = now
        self.progressCoalesceInterval = progressCoalesceInterval
        self.metadataCoalesceInterval = metadataCoalesceInterval
        storeObserver = store.observeChanges { [weak self] change in
            self?.handleStoreChange(change)
        }
        recentObserver = recents.observeChanges { [weak self] in
            self?.bumpProgressRevisionNow()
        }
    }

    func disconnect() {
        if let storeObserver { store.removeObserver(storeObserver) }
        if let recentObserver { recents.removeObserver(recentObserver) }
        storeObserver = nil
        recentObserver = nil
        cachedIndex = nil
        progressCoalesceTask?.cancel()
        progressCoalesceTask = nil
        metadataCoalesceTask?.cancel()
        metadataCoalesceTask = nil
    }

    deinit {
        progressCoalesceTask?.cancel()
        metadataCoalesceTask?.cancel()
    }

    func ensureIndex() -> CatalogIndex {
        if let cachedIndex { return cachedIndex }
        let built = buildIndex(from: store.snapshot)
        cachedIndex = built
        return built
    }

    func releaseIndex() {
        cachedIndex = nil
        progressCoalesceTask?.cancel()
        progressCoalesceTask = nil
        metadataCoalesceTask?.cancel()
        metadataCoalesceTask = nil
    }

    func clientConnected() {
        if pendingMetadataBump {
            pendingMetadataBump = false
            cachedIndex = nil
            libraryRevision = UUID()
            progressPageRevision = UUID()
        }
        if pendingProgressBump {
            pendingProgressBump = false
            lastProgressBump = now()
            progressRevision = UUID()
            progressPageRevision = UUID()
        }
    }

    var state: RemoteLibraryState {
        let idx = ensureIndex()
        return RemoteLibraryState(
            revision: libraryRevision,
            progressRevision: progressRevision,
            folders: Self.clampCount(idx.folderCount),
            videos: Self.clampCount(idx.movies.count + idx.seriesGroups.count),
            series: Self.clampCount(idx.seriesGroups.count),
            albums: Self.clampCount(idx.albums.count),
            tracks: Self.clampCount(idx.tracks.count),
            scanning: store.isScanning)
    }

    func flushPendingProgressRevision() {
        guard pendingProgressBump else { return }
        bumpProgressRevisionNow()
    }

    func artworkKey(for id: String) -> String? {
        let idx = ensureIndex()
        if let target = idx.target(id: id) {
            switch target {
            case .movie(let video): return video.metadata?.posterPath
            case .series(let series): return series.posterPath
            case .episode(let episode, let series):
                return episode.video.metadata?.posterPath ?? series.posterPath
            case .album(let album): return album.artworkPath
            case .track(let track, let album):
                return track.track.artworkPath ?? album?.artworkPath
            }
        }
        if let current = localAudio?.currentTrack {
            if ids.id(kind: .track, key: current.id) == id { return current.artworkPath }
            if let key = current.file.albumKey, ids.id(kind: .album, key: key) == id {
                return current.artworkPath
            }
        }
        return nil
    }

    func resolvePlayTarget(_ id: String) -> PlayTarget? {
        let idx = ensureIndex()
        if let target = idx.target(id: id) {
            switch target {
            case .movie(let video):
                return .movie(
                    file: video.file, isOffline: video.isOffline, folder: video.folder,
                    isIndexed: true, fallbackProgressPath: nil)
            case .series(let series): return .series(series)
            case .episode(let episode, let series): return .episode(episode, series: series)
            case .album(let album): return .album(album, tracks: idx.tracks(for: album))
            case .track(let track, let album):
                return .track(track, albumTracks: album.map { idx.tracks(for: $0) })
            }
        }
        if let adHoc = resolveAdHocRecent(id: id) {
            guard let resolvedURL = recents.resolve(adHoc.recent) else {
                recents.refreshAvailability()
                return nil
            }
            let resolvedPath = VideoFiles.key(resolvedURL)
            let file = MediaLibraryFile(
                path: resolvedPath, size: 0, modified: adHoc.recent.openedAt,
                added: adHoc.recent.openedAt,
                video: VideoTitle(title: resolvedURL.lastPathComponent))
            let fallback = resolvedPath == adHoc.file.path ? nil : adHoc.file.path
            return .movie(
                file: file, isOffline: false, folder: nil, isIndexed: false,
                fallbackProgressPath: fallback)
        }
        return nil
    }

    func videoSourceSummary(model: PlayerViewModel?) -> RemoteSourceSummary? {
        guard let model, model.canControl else { return nil }
        let paused = model.paused || model.isAtEnd
        if let url = model.currentURL, let target = ensureIndex().target(path: VideoFiles.key(url))
        {
            switch target {
            case .episode(let episode, let series):
                let hasArt = (episode.video.metadata?.posterPath ?? series.posterPath) != nil
                let sub = Self.truncateUTF8("\(episode.label) · \(episode.title)", maxBytes: 2048)
                return RemoteSourceSummary(
                    title: series.title, subtitle: sub, paused: paused,
                    artwork: hasArt ? episode.id : nil)
            case .movie(let video):
                return RemoteSourceSummary(
                    title: video.title, subtitle: video.subtitle, paused: paused,
                    artwork: video.metadata?.posterPath != nil ? video.id : nil)
            default: break
            }
        }
        return RemoteSourceSummary(
            title: Self.truncateUTF8(model.displayTitle, maxBytes: 2048), subtitle: nil,
            paused: paused, artwork: nil)
    }

    func localMusicSourceSummary(audio: LocalAudioViewModel?) -> RemoteSourceSummary? {
        guard let audio, let track = audio.currentTrack else { return nil }
        let parts = [track.artist, track.album].filter { !$0.isEmpty }
        let subtitle =
            parts.isEmpty
            ? nil : Self.truncateUTF8(parts.joined(separator: " · "), maxBytes: 2048)
        let artId = track.artworkPath != nil ? ids.id(kind: .track, key: track.id) : nil
        return RemoteSourceSummary(
            title: Self.truncateUTF8(track.title, maxBytes: 2048), subtitle: subtitle,
            paused: audio.paused, artwork: artId)
    }

    func spotifySourceSummary(music: MusicViewModel?) -> RemoteSourceSummary? {
        guard let music, let track = music.currentTrack, music.acceptsPlayback else { return nil }
        let artists = track.artists.map(\.name).filter { !$0.isEmpty }.joined(separator: ", ")
        let subtitle = artists.isEmpty ? nil : Self.truncateUTF8(artists, maxBytes: 2048)
        return RemoteSourceSummary(
            title: Self.truncateUTF8(track.title, maxBytes: 2048), subtitle: subtitle,
            paused: music.paused, artwork: nil)
    }

    func resolveAdHocRecent(id: String) -> (recent: RecentItem, file: MediaLibraryFile)? {
        let idx = ensureIndex()
        for item in recents.items where !recents.unavailable.contains(item.id) {
            let path = VideoFiles.key(URL(fileURLWithPath: item.path))
            guard idx.byPath[path] == nil else { continue }
            if ids.id(kind: .movie, key: path) == id {
                let file = MediaLibraryFile(
                    path: path, size: 0, modified: item.openedAt, added: item.openedAt,
                    video: VideoTitle(title: item.title))
                return (item, file)
            }
        }
        return nil
    }

    private func handleStoreChange(_ change: MediaLibraryStore.LibraryChange) {
        switch change {
        case .catalog:
            metadataCoalesceTask?.cancel()
            metadataCoalesceTask = nil
            pendingMetadataBump = false
            cachedIndex = nil
            libraryRevision = UUID()
            progressPageRevision = UUID()
            changed?()
        case .metadata:
            pendingMetadataBump = true
            guard hasConnectedClients() else {
                cachedIndex = nil
                return
            }
            guard metadataCoalesceTask == nil else { return }
            let delay = max(0, metadataCoalesceInterval)
            metadataCoalesceTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.metadataCoalesceTask = nil
                guard self.pendingMetadataBump else { return }
                self.flushPendingMetadataRevision()
            }
        case .metadataFinished:
            guard pendingMetadataBump, hasConnectedClients() else { return }
            flushPendingMetadataRevision()
        case .scanning:
            changed?()
        case .progress(let progress):
            handleProgressUpdate(progress)
        }
    }

    private func flushPendingMetadataRevision() {
        metadataCoalesceTask?.cancel()
        metadataCoalesceTask = nil
        pendingMetadataBump = false
        cachedIndex = nil
        libraryRevision = UUID()
        progressPageRevision = UUID()
        changed?()
    }

    private func handleProgressUpdate(_ progress: WatchProgress) {
        guard hasConnectedClients() else {
            pendingProgressBump = true
            return
        }
        if progress.completed || !isVideoPlaying() {
            bumpProgressRevisionNow()
            return
        }
        let elapsed = now() - lastProgressBump
        if elapsed >= progressCoalesceInterval {
            bumpProgressRevisionNow()
        } else {
            pendingProgressBump = true
            guard progressCoalesceTask == nil else { return }
            let delay = max(0, progressCoalesceInterval - elapsed)
            progressCoalesceTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.progressCoalesceTask = nil
                guard self.pendingProgressBump else { return }
                self.bumpProgressRevisionNow()
            }
        }
    }

    private func bumpProgressRevisionNow() {
        progressCoalesceTask?.cancel()
        progressCoalesceTask = nil
        pendingProgressBump = false
        lastProgressBump = now()
        progressRevision = UUID()
        progressPageRevision = UUID()
        changed?()
    }

    static func nextEpisode(
        in episodes: [IndexedEpisode], progress: [String: WatchProgress]
    ) -> IndexedEpisode? {
        let last = episodes.filter { progress[$0.video.file.path] != nil }.max {
            (progress[$0.video.file.path]?.updated ?? .distantPast)
                < (progress[$1.video.file.path]?.updated ?? .distantPast)
        }
        if let last, progress[last.video.file.path]?.completed != true { return last }
        if let last, let idx = episodes.firstIndex(where: { $0.id == last.id }) {
            return episodes.dropFirst(idx + 1).first {
                progress[$0.video.file.path]?.completed != true
            }
        }
        return episodes.first { progress[$0.video.file.path]?.completed != true }
    }

    static func validYear(_ value: Int?) -> Int? {
        guard let value, (0...9999).contains(value) else { return nil }
        return value
    }

    static func clampCount(_ value: Int) -> Int {
        min(1_000_000, max(0, value))
    }

    static func parseYear(_ value: String?) -> Int? {
        guard let value, value.count >= 4, let year = Int(value.prefix(4)),
            (0...9999).contains(year)
        else { return nil }
        return year
    }

    static func alphabetical(_ first: String, _ second: String) -> Bool {
        first.localizedStandardCompare(second) == .orderedAscending
    }

    static func truncateUTF8(_ value: String, maxBytes: Int) -> String {
        guard value.utf8.count > maxBytes else { return value }
        var result = ""
        var bytes = 0
        for character in value {
            let size = String(character).utf8.count
            guard bytes + size <= maxBytes else { break }
            result.append(character)
            bytes += size
        }
        return result
    }
}
