import Foundation
import MusicCore
import Observation

@MainActor @Observable
final class LocalAudioViewModel {
    private(set) var queue = MusicQueue()
    private(set) var paused = true
    private(set) var volume: Double
    private(set) var displayedPosition: Double = 0
    private(set) var duration: Double = 0
    private(set) var artworkData: Data?
    private(set) var loading = false
    var errorMessage: String?

    var currentTrack: LocalAudioTrack? { queue.current.flatMap { tracks[$0.track.id] } }
    func track(for id: String) -> LocalAudioTrack? { tracks[id] }
    func title(for track: MusicTrack) -> String { tracks[track.id]?.title ?? track.title }

    @discardableResult
    func mutateQueue(_ mutate: (inout MusicQueue) -> Bool) -> Bool {
        guard mutate(&queue) else { return false }
        notify()
        return true
    }
    var canNext: Bool {
        !queue.upcoming.isEmpty || (!queue.context.isEmpty && queue.repeatMode == .all)
    }
    var canPrevious: Bool { !queue.history.isEmpty }
    var position: Double { latestPosition }

    @ObservationIgnored weak var coordinator: PlaybackCoordinator?
    private let artwork: ArtworkCache
    private let engineFactory: @MainActor (Double) throws -> any LocalAudioEngine
    private let parkDelay: Duration
    private var tracks: [String: LocalAudioTrack] = [:]
    @ObservationIgnored private var engine: (any LocalAudioEngine)?
    @ObservationIgnored private var retirement: Task<Void, Never>?
    @ObservationIgnored private var engineEpoch = UUID()
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var tagTask: Task<Void, Never>?
    @ObservationIgnored private var pendingLoad: PendingLoad?
    @ObservationIgnored private var loadedToken: UUID?
    @ObservationIgnored private var latestPosition: Double = 0
    @ObservationIgnored private var lastDisplayUpdate = -Double.infinity
    @ObservationIgnored private var observers: [UUID: (PlaybackEvent?) -> Void] = [:]

    private struct PendingLoad {
        let token: UUID
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }

    init(
        artwork: ArtworkCache, initialVolume: Double = 100, parkDelay: Duration = .seconds(20),
        engineFactory: @escaping @MainActor (Double) throws -> any LocalAudioEngine = {
            try MPVAudioEngine(initialVolume: $0)
        }
    ) {
        self.artwork = artwork
        volume = min(100, max(0, initialVolume))
        self.parkDelay = parkDelay
        self.engineFactory = engineFactory
    }

    @discardableResult
    func play(_ urls: [URL], using library: MediaLibraryStore) -> Bool {
        let files = urls.filter(LocalAudioFiles.isAudio)
        guard !files.isEmpty else { return false }
        let known = Dictionary(uniqueKeysWithValues: library.audioTracks.map { ($0.id, $0) })
        let values = files.map { url in
            let path = VideoFiles.key(url)
            return known[path]
                ?? LocalAudioTrack(
                    file: MediaLibraryFile(
                        path: path, size: 0, modified: Date(), added: Date(),
                        audio: LocalAudioTags(title: url.deletingPathExtension().lastPathComponent)),
                    metadata: nil, isOffline: false)
        }
        return play(values)
    }

    @discardableResult
    func play(
        _ tracks: [LocalAudioTrack], at index: Int = 0, shuffled: Bool = false,
        pinSelected: Bool = false
    ) -> Bool {
        guard tracks.indices.contains(index),
            !tracks[index].isOffline || (shuffled && !pinSelected)
        else { return false }
        let available = tracks.filter { !$0.isOffline }
        guard !available.isEmpty else { return false }
        let selected =
            shuffled && !pinSelected
            ? 0 : available.firstIndex { $0.id == tracks[index].id } ?? 0
        coordinator?.exitScreensaverForLocalAudioOpen()
        start { player in
            player.tracks = Dictionary(
                available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let items = available.map(Self.queueTrack)
            if shuffled {
                var random = SystemRandomNumberGenerator()
                if pinSelected {
                    player.queue.startShuffled(items, startingAt: selected, using: &random)
                } else {
                    player.queue.startShuffled(items, using: &random)
                }
            } else {
                player.queue.start(items, at: selected)
            }
            try await player.loadCurrent(from: 0)
        }
        return true
    }

    @discardableResult
    func setPaused(_ value: Bool) -> Bool {
        guard currentTrack != nil, value || coordinator?.blocksLocalAudioTransport != true else {
            return false
        }
        if value {
            coordinator?.cancelPending(.localAudio)
            do { try pauseForSourceChange() } catch {
                errorMessage = LocalAudioFailure.alertMessage(for: error)
                return false
            }
        } else {
            start { player in
                if player.loadedToken == nil {
                    try await player.loadCurrent(from: player.latestPosition)
                } else {
                    try player.engine?.setPaused(false)
                    player.stopParking()
                    player.paused = false
                    player.notify()
                }
            }
        }
        return true
    }

    @discardableResult
    func togglePause() -> Bool {
        guard coordinator?.blocksLocalAudioTransport != true else { return false }
        return setPaused(!paused || loading)
    }

    func pauseForSourceChange() throws {
        try engine?.setPaused(true)
        paused = true
        scheduleParking()
        notify()
    }

    @discardableResult
    func setVolume(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        let value = max(0, min(100, value))
        do {
            try engine?.setVolume(value)
            volume = value
            notify()
            return true
        } catch {
            errorMessage = LocalAudioFailure.alertMessage(for: error)
            return false
        }
    }

    @discardableResult
    func seek(_ position: Double) -> Bool {
        guard currentTrack != nil, position.isFinite, !loading,
            coordinator?.blocksLocalAudioTransport != true
        else { return false }
        let position = min(max(0, position), duration > 0 ? duration : max(0, position))
        do {
            if loadedToken != nil { try engine?.seek(position) }
            updatePosition(position, force: true)
            return true
        } catch {
            errorMessage = LocalAudioFailure.alertMessage(for: error)
            return false
        }
    }

    @discardableResult
    func next() -> Bool {
        guard canNext, coordinator?.blocksLocalAudioTransport != true else { return false }
        start { player in
            guard player.queue.next() != nil else { return }
            try await player.loadCurrent(from: 0)
        }
        return true
    }

    @discardableResult
    func previous() -> Bool {
        guard canPrevious, coordinator?.blocksLocalAudioTransport != true else { return false }
        start { player in
            guard player.queue.previous() != nil else { return }
            try await player.loadCurrent(from: 0)
        }
        return true
    }

    func jump(to id: UUID) {
        guard coordinator?.blocksLocalAudioTransport != true else { return }
        start { player in
            guard let first = player.queue.upcoming.first?.id else { return }
            guard id == first || player.queue.move(id, before: first), player.queue.next() != nil
            else { return }
            try await player.loadCurrent(from: 0)
        }
    }

    func remove(_ id: UUID) {
        if queue.remove(id) { notify() }
    }

    func move(_ id: UUID, by offset: Int) {
        if queue.moveOffset(id, by: offset) { notify() }
    }

    func toggleShuffle() {
        var random = SystemRandomNumberGenerator()
        queue.setShuffle(!queue.shuffled, using: &random)
        notify()
    }

    func cycleRepeat() {
        queue.repeatMode =
            switch queue.repeatMode {
            case .off: .all
            case .all: .one
            case .one: .off
            }
        notify()
    }

    func shutdownPlayback() async {
        stopParking()
        tagTask?.cancel()
        artworkTask?.cancel()
        paused = true
        loading = false
        queue.clear()
        tracks.removeAll()
        artworkData = nil
        duration = 0
        displayedPosition = 0
        latestPosition = 0
        await retire()
        notify()
    }

    private func start(_ action: @escaping @MainActor (LocalAudioViewModel) async throws -> Void) {
        if let coordinator {
            coordinator.start(.localAudio) { [weak self] in
                if let self { try await action(self) }
            }
        } else {
            Task { [weak self] in
                guard let self else { return }
                do { try await action(self) } catch {
                    self.errorMessage = LocalAudioFailure.alertMessage(for: error)
                }
            }
        }
    }

    private func loadCurrent(from position: Double) async throws {
        guard let track = currentTrack else { return }
        stopParking()
        paused = true
        loading = true
        loadedToken = nil
        latestPosition = position
        displayedPosition = position
        duration = track.file.audio?.duration ?? 0
        lastDisplayUpdate = -Double.infinity
        artworkData = nil
        errorMessage = nil
        notify()
        let token = UUID()
        do {
            let engine = try await getEngine()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled, self?.pendingLoad?.token == token else { return }
                    self?.finishLoad(.failure(LocalAudioFailure.loadTimeout))
                }
                pendingLoad = PendingLoad(
                    token: token, continuation: continuation, timeout: timeout)
                do { try engine.load(track.file.url, id: token, position: position) } catch {
                    finishLoad(.failure(error))
                }
            }
            loading = false
            let shouldPlay = coordinator?.allowsPendingStart(.localAudio) ?? true
            if shouldPlay {
                try engine.setPaused(false)
                paused = false
            } else {
                scheduleParking()
            }
            prepareArtwork(track)
            notify()
        } catch {
            loading = false
            await retire()
            notify()
            throw error
        }
    }

    private func getEngine() async throws -> any LocalAudioEngine {
        await retirement?.value
        if let engine { return engine }
        let engine = try engineFactory(volume)
        self.engine = engine
        let epoch = engineEpoch
        eventTask = Task { [weak self] in
            for await event in engine.events {
                guard let self, self.engineEpoch == epoch, !Task.isCancelled else { return }
                self.receive(event)
            }
            guard let self, self.engineEpoch == epoch else { return }
            if let token = self.pendingLoad?.token {
                self.receive(.failed(token, "Local audio engine exited."))
            } else {
                self.paused = true
                await self.retire()
                self.notify()
            }
        }
        return engine
    }

    private func receive(_ event: LocalAudioEvent) {
        switch event {
        case .loaded(let token):
            guard pendingLoad?.token == token else { return }
            loadedToken = token
            finishLoad(.success(()))
        case .failed(let token, let error):
            guard pendingLoad?.token == token else { return }
            finishLoad(.failure(LocalAudioFailure.engine(error)))
        case .ended(let token):
            guard loadedToken == token else { return }
            loadedToken = nil
            paused = true
            latestPosition = 0
            displayedPosition = 0
            notify()
            if coordinator?.mayAdvanceLocalAudio == false || (!canNext && queue.repeatMode != .one)
            {
                scheduleParking()
                return
            }
            start { player in
                guard player.queue.next(automatically: true) != nil else { return }
                try await player.loadCurrent(from: 0)
            }
        case .duration(let seconds) where seconds.isFinite && seconds > 0:
            duration = seconds
            notify()
        case .position(let seconds) where loadedToken != nil && !loading && seconds.isFinite:
            updatePosition(max(0, seconds))
        default: break
        }
    }

    private func finishLoad(_ result: Result<Void, Error>) {
        guard let pendingLoad else { return }
        self.pendingLoad = nil
        pendingLoad.timeout.cancel()
        pendingLoad.continuation.resume(with: result)
    }

    private func scheduleParking() {
        stopParking()
        guard engine != nil else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: self?.parkDelay ?? .seconds(20))
            guard let self, !Task.isCancelled, self.paused, !self.loading else { return }
            self.idleTask = nil
            await self.retire()
        }
    }

    private func stopParking() {
        idleTask?.cancel()
        idleTask = nil
    }

    private func retire() async {
        if let engine {
            self.engine = nil
            engineEpoch = UUID()
            loadedToken = nil
            eventTask?.cancel()
            eventTask = nil
            finishLoad(.failure(CancellationError()))
            retirement = Task { await engine.shutdown() }
        }
        await retirement?.value
    }

    private func updatePosition(_ seconds: Double, force: Bool = false) {
        latestPosition = seconds
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastDisplayUpdate >= 0.25 else { return }
        displayedPosition = seconds
        lastDisplayUpdate = now
        notify(.property(.position, .number(seconds)))
    }

    private func prepareArtwork(_ track: LocalAudioTrack) {
        artworkTask?.cancel()
        tagTask?.cancel()
        let id = queue.current?.id
        if track.file.size == 0 {
            let artwork = artwork
            tagTask = Task { [weak self] in
                let (tags, size) = await Task.detached(priority: .utility) {
                    let url = track.file.url
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return (await LocalAudioTagReader.read(url, artwork: artwork), Int64(size))
                }.value
                guard let self, !Task.isCancelled, self.queue.current?.id == id else { return }
                let file = MediaLibraryFile(
                    path: track.file.path, size: size, modified: track.file.modified,
                    added: track.file.added, audio: tags)
                self.tracks[track.id] = LocalAudioTrack(
                    file: file, metadata: track.metadata, isOffline: false)
                self.loadArtwork(tags.artworkPath, occurrence: id)
                self.notify()
            }
        } else {
            loadArtwork(track.artworkPath, occurrence: id)
        }
    }

    private func loadArtwork(_ key: String?, occurrence: UUID?) {
        guard let key else { return }
        artworkTask = Task { [weak self, artwork] in
            let data = await artwork.thumbnail(key)
            guard let self, !Task.isCancelled, self.queue.current?.id == occurrence else { return }
            self.artworkData = data
            self.notify()
        }
    }

    private static func queueTrack(_ track: LocalAudioTrack) -> MusicTrack {
        MusicTrack(
            id: track.id, uri: track.file.url.absoluteString, title: track.title,
            artists: track.artist.isEmpty
                ? [] : [MusicArtist(id: track.artist, uri: "", name: track.artist)],
            albumID: track.file.albumKey ?? "", albumTitle: track.album,
            duration: track.file.audio?.duration ?? 0)
    }

    private func notify(_ event: PlaybackEvent? = nil) {
        for observer in Array(observers.values) { observer(event) }
    }

    func observePlayback(_ observer: @escaping (PlaybackEvent?) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removePlaybackObserver(_ id: UUID) { observers[id] = nil }
}
