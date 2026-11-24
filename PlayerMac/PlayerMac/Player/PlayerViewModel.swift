import Foundation
import Observation
import RemoteProtocol

@MainActor @Observable
final class PlayerViewModel {
    private(set) var title = ""
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var paused = false
    var volume: Double = 100
    private(set) var hasMedia = false
    private(set) var isLoading = false
    /// Shows the Video Home & History screen while preserving the paused movie.
    private(set) var isShowingHome = false
    var isStartingHome = false
    var isShowingConnectPhone = false
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
    var screensaver = Screensaver.off
    var isStartingScreensaver = false
    let screensaverPresentation = ScreensaverPresentation()
    @ObservationIgnored var screensaverPauseTask: Task<Void, Never>?
    @ObservationIgnored var screensaverPreparation: UUID?
    @ObservationIgnored var screensaverStartCompletions: [(Bool) -> Void] = []
    var isScreensaverEngaged: Bool { screensaver != .off || isStartingScreensaver }
    /// Auto-advance to next folder file at video end.
    @ObservationIgnored var autoAdvance = true
    @ObservationIgnored var beforeStartingPlayback: ((@escaping @MainActor () -> Void) -> Bool)?
    @ObservationIgnored var beforeStartingMatrix: ((@escaping (Bool) -> Void) -> Bool)?
    @ObservationIgnored var writeWatchProgress: ((WatchProgress) -> Void)?
    @ObservationIgnored var watchProgress = VideoWatchProgress()
    @ObservationIgnored var cancelPendingPlayback: (() -> Void)?
    @ObservationIgnored var onToggleFullscreen: (() -> Void)?
    @ObservationIgnored var onSetFullscreen: ((Bool) -> Void)?
    @ObservationIgnored let engine: any PlayerEngine
    @ObservationIgnored let recents: RecentFilesStore?
    @ObservationIgnored private let playlistProvider: (@Sendable (URL) -> FolderPlaylist)?
    @ObservationIgnored private let folderDependencies: FolderMonitor.Dependencies
    @ObservationIgnored private let usesSnapshotProvider: Bool
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var folderMonitor: FolderMonitor?
    @ObservationIgnored private var folderGeneration = UUID()
    @ObservationIgnored private(set) var eofTask: Task<Void, Never>?
    @ObservationIgnored private var eofGeneration = UUID()
    @ObservationIgnored private var lastPositionUpdate = -Double.infinity
    @ObservationIgnored private var latestPosition: Double = 0
    var endReached = false
    /// Command intent before pause confirmation; displayed state still provided by mpv.
    @ObservationIgnored var requestedPause: Bool?
    @ObservationIgnored var replayPending = false
    @ObservationIgnored var idleParkDelay: Duration = PlayerViewModel.defaultIdleParkDelay
    @ObservationIgnored var idleParkTask: Task<Void, Never>?
    @ObservationIgnored var isVideoSurfaceVisible = false
    var parkedVideo: ParkedVideo?
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

    func notifyPlayback(_ event: PlaybackEvent? = nil) {
        // Shutdown handler may unsubscribe during notification.
        for observer in Array(playbackObservers.values) { observer(event) }
    }

    init(
        engine: any PlayerEngine, recents: RecentFilesStore? = nil,
        folderDependencies: FolderMonitor.Dependencies? = nil,
        playlistProvider: (@Sendable (URL) -> FolderPlaylist)? = nil
    ) {
        self.engine = engine
        trackController = TrackController(engine: engine)
        self.recents = recents
        self.playlistProvider = playlistProvider
        self.folderDependencies = folderDependencies ?? .init()
        usesSnapshotProvider = playlistProvider != nil && folderDependencies == nil
        let events = engine.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }
                self?.receive(event)
            }
        }
    }

    isolated deinit {
        idleParkTask?.cancel()
        screensaverPauseTask?.cancel()
        eventTask?.cancel()
        folderMonitor?.stop()
        eofTask?.cancel()
    }

    /// Video reached end and rests on last frame (keep-open).
    var isAtEnd: Bool { hasMedia && endReached }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return currentURL?.lastPathComponent ?? ""
    }

    @discardableResult
    func open(
        url: URL, startPosition: Double? = nil, startPaused: Bool = false,
        showTracks: MediaTrackKind? = nil
    ) -> Bool {
        guard !isClosing else { return false }
        if let beforeStartingPlayback {
            return beforeStartingPlayback { [weak self] in
                _ = self?.loadForPlayback(
                    url, startPosition: startPosition, paused: startPaused, tracks: showTracks)
            }
        }
        return loadForPlayback(
            url, startPosition: startPosition, paused: startPaused, tracks: showTracks)
    }

    func loadForPlayback(
        _ url: URL, startPosition: Double?, paused: Bool, tracks: MediaTrackKind?,
        preserveShortStart: Bool = false,
        restoringTracks: TrackController.SessionSelection? = nil,
        restoringAtEnd: Bool = false
    ) -> Bool {
        guard !isClosing else { return false }
        recordWatchProgress(force: true)
        do {
            try engine.load(url: url, paused: paused)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        cancelIdlePark()
        parkedVideo = nil
        stopScreensaver()
        cancelEOFRefresh()
        isStartingHome = false
        isShowingHome = false
        isShowingConnectPhone = false
        errorMessage = nil
        setVideoStart(
            url, at: startPosition, showTracks: tracks, preserveShortStart: preserveShortStart,
            restoringAtEnd: restoringAtEnd)
        trackController.prepare(for: url, restoring: restoringTracks)
        isLoading = true
        currentURL = url
        updatePlaylist(for: url)
        notifyPlayback()
        return true
    }

    private func updatePlaylist(for url: URL) {
        let folder = URL(
            fileURLWithPath: VideoFiles.key(url.deletingLastPathComponent()), isDirectory: true)
        if folderMonitor?.folder == folder {
            if let playlist { self.playlist = FolderPlaylist(items: playlist.items, current: url) }
            return
        }
        stopFolderMonitor()
        playlist = nil
        let generation = folderGeneration
        var dependencies = folderDependencies
        if let playlistProvider {
            // Legacy snapshot providers own their filesystem, which may be entirely virtual.
            dependencies.scan = { _ in playlistProvider(url).items }
            if usesSnapshotProvider { dependencies.watch = { _ in AsyncStream { _ in } } }
        }
        folderMonitor = FolderMonitor(folder: folder, dependencies: dependencies) {
            [weak self] result in
            guard let self, self.folderGeneration == generation, !self.isClosing,
                let current = self.currentURL
            else { return }
            let items: [URL]
            switch result {
            case .success(let scanned): items = scanned
            case .failure:
                guard self.playlist == nil else { return }
                items = []
            }
            let updated = FolderPlaylist(items: items, current: current)
            guard updated != self.playlist else { return }
            self.playlist = updated
            self.notifyPlayback()
        }
    }

    private func stopFolderMonitor() {
        folderGeneration = UUID()
        folderMonitor?.stop()
        folderMonitor = nil
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
            if !engine.reportsLoadedPath { applyVideoStart() }
            if !isShowingHome { isShowingConnectPhone = false }
            if let currentURL {
                recents?.noteOpened(currentURL)
                recents?.updateDuration(duration, for: currentURL)
            }
            updateIdleParkTimer()
        case .seeking: break
        case .playbackRestarted:
            position = latestPosition
            // New time-pos may arrive after seek confirmation.
            lastPositionUpdate = -Double.infinity
        case .ended(let error):
            if error != nil { watchProgress = VideoWatchProgress() }
            trackController.stop()
            resetMedia()
            errorMessage = error
            if error != nil { clearCurrentFile() }
        case .failure(let error):
            watchProgress.pending = nil
            watchProgress.panel = nil
            if isStartingScreensaver { stopScreensaver() }
            isStartingHome = false
            if !paused {
                setShowingHome(false)
                isShowingConnectPhone = false
            }
            isLoading = false
            requestedPause = nil
            replayPending = false
            errorMessage = error
        case .shutdown:
            stopScreensaver()
            trackController.close()
            resetMedia()
            clearCurrentFile()
        case .property(let property, let value):
            apply(property, value)
        case .tracksLoaded(let path, let tracks):
            trackController.loaded(path: path, tracks: tracks)
            applyVideoStart(path: path)
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
            if paused {
                recordWatchProgress(force: true)
                position = latestPosition
                if isStartingHome {
                    isStartingHome = false
                    recents?.refreshAvailability()
                    isShowingHome = true
                }
            } else {
                isStartingHome = false
                isShowingHome = false
                isShowingConnectPhone = false
            }
            if paused, isStartingScreensaver, screensaverPreparation == nil { activateMatrix() }
            if !paused, screensaver == .matrix { setPaused(true) }
            updateIdleParkTimer()
        case (.endReached, .flag(let reached)):
            let wasReached = endReached
            if !reached, let key = currentURL.map(VideoFiles.key),
                watchProgress.restoredAtEndKey == key
            {
                endReached = true
            } else {
                endReached = reached
            }
            if !endReached { replayPending = false }
            if endReached { position = latestPosition }
            if reached, !wasReached, !isLoading {
                recordWatchProgress(force: true, completed: true)
                advanceAfterEnd()
            }
            updateIdleParkTimer()
        case (.position, .number(let seconds)) where seconds.isFinite:
            latestPosition = max(0, seconds)
            if !isLoading {
                observeResumedPosition(seconds)
                recordWatchProgress()
            }
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
        case (.idle, .flag(true)):
            if !isLoading { resetMedia() }
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
        guard !isScreensaverEngaged, autoAdvance, hasMedia,
            let url = currentURL, let monitor = folderMonitor
        else {
            return
        }
        if let next = playlist?.next, !monitor.isDirty,
            usesSnapshotProvider || folderDependencies.isReachable(next)
        {
            open(url: next)
            return
        }
        cancelEOFRefresh()
        let generation = eofGeneration
        eofTask = Task { [weak self] in
            let items = await monitor.refresh()
            guard let self, !Task.isCancelled, self.eofGeneration == generation else { return }
            self.eofTask = nil
            // Use this check's snapshot even if another publication wins the actor scheduling race.
            guard let items, self.autoAdvance, self.isAtEnd, !self.replayPending,
                !self.isClosing, !self.isScreensaverEngaged, self.currentURL == url,
                let next = FolderPlaylist(items: items, current: url).next
            else {
                self.updateIdleParkTimer()
                return
            }
            self.open(url: next)
        }
    }

    func cancelEOFRefresh() {
        eofGeneration = UUID()
        eofTask?.cancel()
        eofTask = nil
    }

    private func resetMedia() {
        cancelIdlePark()
        parkedVideo = nil
        cancelEOFRefresh()
        title = ""
        position = 0
        latestPosition = 0
        endReached = false
        requestedPause = nil
        replayPending = false
        duration = 0
        hasMedia = false
        isLoading = false
        isStartingHome = false
        isShowingHome = false
        isShowingConnectPhone = false
        hardwareDecoder = ""
        audioOutput = ""
        lastPositionUpdate = -Double.infinity
    }

    func updateParkedPosition(_ seconds: Double) {
        guard let parked = parkedVideo else { return }
        let clamped = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        position = clamped
        latestPosition = clamped
        endReached = false
        replayPending = false
        parkedVideo = ParkedVideo(
            url: parked.url, position: clamped, duration: parked.duration, title: parked.title,
            isAtEnd: false, trackSelection: parked.trackSelection)
        notifyPlayback()
    }

    func setShowingHome(_ showing: Bool) {
        guard isShowingHome != showing else { return }
        isShowingHome = showing
        notifyPlayback()
    }

    func clearMedia() {
        recordWatchProgress(force: true)
        resetMedia()
        clearCurrentFile()
        notifyPlayback()
    }

    func shutdown() async {
        recordWatchProgress(force: true)
        cancelIdlePark()
        parkedVideo = nil
        stopScreensaver()
        trackController.close()
        isClosing = true
        cancelEOFRefresh()
        stopFolderMonitor()
        notifyPlayback(.shutdown)
        eventTask?.cancel()
        eventTask = nil
        await engine.shutdown()
        resetMedia()
        clearCurrentFile()
    }

    private func clearCurrentFile() {
        cancelEOFRefresh()
        stopFolderMonitor()
        currentURL = nil
        watchProgress = VideoWatchProgress()
        playlist = nil
    }
}
