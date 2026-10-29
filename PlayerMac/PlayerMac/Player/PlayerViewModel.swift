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
    private(set) var screensaver = Screensaver.off
    private(set) var isStartingScreensaver = false
    let screensaverPresentation = ScreensaverPresentation()
    @ObservationIgnored private var screensaverPauseTask: Task<Void, Never>?
    @ObservationIgnored private var screensaverStartCompletions: [(Bool) -> Void] = []
    var isScreensaverEngaged: Bool { screensaver != .off || isStartingScreensaver }
    /// Auto-advance to next folder file at video end.
    @ObservationIgnored var autoAdvance = true
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
    func open(url: URL) -> Bool {
        guard !isClosing else { return false }
        stopScreensaver()
        cancelEOFRefresh()
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
            if isStartingScreensaver { stopScreensaver() }
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
            if paused, isStartingScreensaver { activateMatrix() }
            if !paused, screensaver == .matrix { setPaused(true) }
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
            else { return }
            self.open(url: next)
        }
    }

    func cancelEOFRefresh() {
        eofGeneration = UUID()
        eofTask?.cancel()
        eofTask = nil
    }

    private func resetMedia() {
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
        hardwareDecoder = ""
        audioOutput = ""
        lastPositionUpdate = -Double.infinity
    }

    func shutdown() async {
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
        playlist = nil
    }

    /// Only expose the animation after mpv confirms the pause; preserve position and fullscreen.
    @discardableResult
    func startMatrix(completion: ((Bool) -> Void)? = nil) -> Bool {
        guard !isClosing, !isLoading else {
            completion?(false)
            return false
        }
        if screensaver == .matrix {
            completion?(true)
            return true
        }
        if let completion { screensaverStartCompletions.append(completion) }
        guard !isStartingScreensaver else { return true }
        cancelEOFRefresh()
        trackController.presentation = nil
        if !hasMedia || (paused && requestedPause != false) {
            activateMatrix()
            return true
        }
        isStartingScreensaver = true
        guard setPaused(true) else {
            stopScreensaver()
            return false
        }
        screensaverPauseTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, !Task.isCancelled, self.isStartingScreensaver else { return }
            self.stopScreensaver()
            self.errorMessage = L10n.text("The movie could not be paused. Try again.")
        }
        return true
    }

    private func activateMatrix() {
        screensaverPauseTask?.cancel()
        screensaverPauseTask = nil
        isStartingScreensaver = false
        screensaver = .matrix
        screensaverPresentation.start()
        let completions = takeScreensaverStartCompletions()
        notifyPlayback()
        for completion in completions { completion(true) }
    }

    @discardableResult
    func stopScreensaver() -> Bool {
        screensaverPauseTask?.cancel()
        screensaverPauseTask = nil
        let changed = isScreensaverEngaged
        isStartingScreensaver = false
        screensaver = .off
        screensaverPresentation.stop()
        let completions = takeScreensaverStartCompletions()
        if changed { notifyPlayback() }
        for completion in completions { completion(false) }
        return true
    }

    private func takeScreensaverStartCompletions() -> [(Bool) -> Void] {
        let completions = screensaverStartCompletions
        screensaverStartCompletions.removeAll()
        return completions
    }
}
