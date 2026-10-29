import Foundation
import Observation

@MainActor @Observable
final class PlayerViewModel {
    private(set) var title = ""
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var paused = false
    var volume: Double = 100
    private(set) var hasMedia = false
    private(set) var isLoading = false
    private(set) var hardwareDecoder = ""
    private(set) var audioOutput = ""
    /// Most recently requested file (before engine confirmation).
    private(set) var currentURL: URL?
    /// Video in same folder; populated after background folder read.
    private(set) var playlist: FolderPlaylist?
    /// Window state managed by PlayerWindowController.
    var isFullscreen = false { didSet { notifyPlayback() } }
    /// Unlike UI slider position, this is mpv-confirmed value.
    private(set) var playbackVolume: Double = 100
    var errorMessage: String?
    let trackController: TrackController
    /// Auto-advance to next folder file at video end.
    @ObservationIgnored var autoAdvance = true
    @ObservationIgnored var onToggleFullscreen: (() -> Void)?
    @ObservationIgnored var onSetFullscreen: ((Bool) -> Void)?
    @ObservationIgnored let engine: any PlayerEngine
    @ObservationIgnored let recents: RecentFilesStore?
    @ObservationIgnored private let playlistProvider: @Sendable (URL) -> FolderPlaylist
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var playlistTask: Task<Void, Never>?
    @ObservationIgnored private var lastPositionUpdate = -Double.infinity
    @ObservationIgnored private var latestPosition: Double = 0
    private var endReached = false
    /// Command intent before pause confirmation; displayed state still provided by mpv.
    @ObservationIgnored var requestedPause: Bool?
    @ObservationIgnored var replayPending = false
    @ObservationIgnored private(set) var isClosing = false
    @ObservationIgnored private var playbackObservers: [UUID: (PlaybackEvent?) -> Void] = [:]

    // System center receives accurate mpv time independent of UI throttle.
    var playbackPosition: Double { latestPosition }

    func observePlayback(_ observer: @escaping (PlaybackEvent?) -> Void) -> UUID {
        let id = UUID()
        playbackObservers[id] = observer
        return id
    }

    func removePlaybackObserver(_ id: UUID) { playbackObservers[id] = nil }

    private func notifyPlayback(_ event: PlaybackEvent? = nil) {
        // Shutdown handler may unsubscribe during notification.
        for observer in Array(playbackObservers.values) { observer(event) }
    }

    init(
        engine: any PlayerEngine, recents: RecentFilesStore? = nil,
        playlistProvider: @escaping @Sendable (URL) -> FolderPlaylist = FolderPlaylist.scan
    ) {
        self.engine = engine
        trackController = TrackController(engine: engine)
        self.recents = recents
        self.playlistProvider = playlistProvider
        let events = engine.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }
                self?.receive(event)
            }
        }
    }

    deinit {
        eventTask?.cancel()
        playlistTask?.cancel()
    }

    /// Video reached end and rests on last frame (keep-open).
    var isAtEnd: Bool { hasMedia && endReached }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return currentURL?.lastPathComponent ?? ""
    }

    @discardableResult
    func open(url: URL) -> Bool {
        guard !isClosing else { return false }
        errorMessage = nil
        do {
            try engine.load(url: url)
            trackController.prepare(for: url)
            isLoading = true
            currentURL = url
            updatePlaylist(for: url)
            notifyPlayback()
            return true
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func updatePlaylist(for url: URL) {
        // Neighboring file from same playlist does not require new folder read.
        if let playlist, let index = playlist.index(of: url) {
            self.playlist = FolderPlaylist(items: playlist.items, current: playlist.items[index])
            return
        }
        playlist = nil
        playlistTask?.cancel()
        let provider = playlistProvider
        playlistTask = Task { [weak self] in
            let scanned = await Task.detached(priority: .utility) { provider(url) }.value
            guard let self, !Task.isCancelled, self.currentURL == url else { return }
            self.playlist = scanned
            self.notifyPlayback()
        }
    }

    func receive(_ event: PlaybackEvent) {
        guard !isClosing else { return }
        defer { notifyPlayback(event) }
        switch event {
        case .started:
            trackController.stop()
            resetMedia()
            isLoading = true
        case .loaded:
            hasMedia = true
            isLoading = false
            if let currentURL {
                recents?.noteOpened(currentURL)
                recents?.updateDuration(duration, for: currentURL)
            }
        case .seeking: break
        case .playbackRestarted:
            position = latestPosition
            // New time-pos may arrive after seek confirmation.
            lastPositionUpdate = -Double.infinity
        case .ended(let error):
            trackController.stop()
            resetMedia()
            errorMessage = error
            if error != nil { clearCurrentFile() }
        case .failure(let error):
            isLoading = false
            requestedPause = nil
            replayPending = false
            errorMessage = error
        case .shutdown:
            trackController.close()
            resetMedia()
            clearCurrentFile()
        case .property(let property, let value):
            apply(property, value)
        case .tracksLoaded(let path, let tracks):
            trackController.loaded(path: path, tracks: tracks)
        case .trackCommandCompleted(let id, let error):
            trackController.completed(id: id, error: error)
        }
    }

    private func apply(_ property: PlaybackProperty, _ value: PlaybackValue) {
        switch (property, value) {
        case (.tracks, .tracks(let tracks)): trackController.update(tracks)
        case (.title, .text(let title)): self.title = title
        case (.paused, .flag(let paused)):
            self.paused = paused
            if requestedPause == paused { requestedPause = nil }
            if paused { position = latestPosition }
        case (.endReached, .flag(let reached)):
            let wasReached = endReached
            endReached = reached
            if !reached { replayPending = false }
            if reached { position = latestPosition }
            if reached, !wasReached { advanceAfterEnd() }
        case (.position, .number(let seconds)) where seconds.isFinite:
            latestPosition = max(0, seconds)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastPositionUpdate >= 0.1 || paused || endReached {
                position = latestPosition
                lastPositionUpdate = now
            }
        case (.duration, .number(let seconds)) where seconds.isFinite:
            duration = max(0, seconds)
            if hasMedia, !isLoading, let currentURL {
                recents?.updateDuration(duration, for: currentURL)
            }
        case (.volume, .number(let volume)) where volume.isFinite:
            self.volume = min(100, max(0, volume))
            playbackVolume = self.volume
        case (.hardwareDecoder, .text(let name)): hardwareDecoder = name
        case (.audioOutput, .text(let name)): audioOutput = name
        case (.idle, .flag(true)): resetMedia()
        case (.position, .unavailable):
            position = 0
            latestPosition = 0
            lastPositionUpdate = -Double.infinity
        case (.endReached, .unavailable):
            endReached = false
            replayPending = false
        case (.duration, .unavailable): duration = 0
        case (.title, .unavailable): title = ""
        case (.hardwareDecoder, .unavailable): hardwareDecoder = ""
        case (.audioOutput, .unavailable): audioOutput = ""
        default: break
        }
    }

    private func advanceAfterEnd() {
        // With keep-open last file stays on last frame.
        guard autoAdvance, hasMedia, let next = playlist?.next else { return }
        open(url: next)
    }

    private func resetMedia() {
        title = ""
        position = 0
        latestPosition = 0
        endReached = false
        requestedPause = nil
        replayPending = false
        duration = 0
        hasMedia = false
        isLoading = false
        hardwareDecoder = ""
        audioOutput = ""
        lastPositionUpdate = -Double.infinity
    }

    func shutdown() async {
        trackController.close()
        isClosing = true
        notifyPlayback(.shutdown)
        eventTask?.cancel()
        eventTask = nil
        playlistTask?.cancel()
        playlistTask = nil
        await engine.shutdown()
        resetMedia()
        clearCurrentFile()
    }

    private func clearCurrentFile() {
        currentURL = nil
        playlist = nil
        playlistTask?.cancel()
    }
}
