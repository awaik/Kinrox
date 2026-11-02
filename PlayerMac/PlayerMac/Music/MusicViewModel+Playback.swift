import Foundation
import MusicCore

extension MusicViewModel {
    func connect(engine: any MusicEngine) {
        engineTask?.cancel()
        musicEngine = engine
        engineTask = Task { [weak self] in
            for await event in engine.events {
                guard let self, self.musicEngine === engine else { return }
                switch event {
                case .state(let state): self.receive(state)
                case .ended: self.advance(automatically: true)
                case .failure(let message): self.statusMessage = message
                }
            }
        }
    }

    func receive(_ state: MusicPlaybackSnapshot) {
        lastSnapshot = state
        disallowedActions = state.disallowedActions
        if let id = state.occurrenceID, queue.current?.id != id,
            queue.upcoming.contains(where: { $0.id == id })
        {
            while queue.current?.id != id { guard queue.next() != nil else { break } }
            if isQueue { refreshContents() }
        }
        guard state.occurrenceID == queue.current?.id else { return }
        paused = state.paused
        position = state.position
        volume = state.volume
        outputName = state.deviceName
        playbackDuration = state.duration
        notifyPlayback(.property(.position, .number(position)))
    }

    func play(_ tracks: [MusicTrack], at index: Int = 0) {
        guard allows("interrupting_playback"), tracks.indices.contains(index),
            tracks[index].isPlayable != false
        else { return }
        runPlayback(startsPlayback: true) { model in
            var next = MusicQueue()
            next.start(tracks, at: index)
            try await model.startQueue(next)
        }
    }

    func playAlbum(_ album: MusicAlbum) {
        guard let store = store as? SpotifyLibraryStore else {
            play(catalog.tracks(in: album))
            return
        }
        browsingTask?.cancel()
        browsingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await store.loadAlbum(album.id)
                guard self.store === store else { return }
                self.catalog = store.catalog
                if let loaded = self.catalog.albums.first(where: { $0.id == album.id }) {
                    self.play(self.catalog.tracks(in: loaded))
                }
            } catch is CancellationError {} catch {
                self.statusMessage = SpotifyStatus.message(error)
            }
        }
    }

    func togglePause() { setPaused(!paused) }
    func setPaused(_ value: Bool) {
        guard currentTrack != nil, allows(value ? "pausing" : "resuming") else { return }
        if value { coordinator?.cancelPending(.music) }
        runPlayback(startsPlayback: !value) { model in
            if value {
                try await model.pauseForSourceChange()
            } else if let engine = model.musicEngine, engine.canResume(model.queue) {
                try await engine.setPaused(false)
            } else {
                try await model.startQueue(model.queue, position: model.displayedPosition)
            }
        }
    }
    func pauseForSourceChange() async throws {
        if let musicEngine {
            try await musicEngine.setPaused(true)
        } else if isDemo {
            position = displayedPosition
            paused = true
            notifyPlayback()
        }
    }
    func stop() {
        guard allows("pausing"), allows("seeking") else { return }
        coordinator?.cancelPending(.music)
        runPlayback { model in
            if let engine = model.musicEngine {
                try await engine.stop()
            } else if model.isDemo {
                model.paused = true
                model.position = 0
            }
            model.notifyPlayback()
        }
    }
    func next() { advance(automatically: false) }
    func advance(automatically: Bool) {
        guard automatically || allows("skipping_next") else { return }
        runPlayback(startsPlayback: true) { model in
            var next = model.queue
            guard next.next(automatically: automatically) != nil else { return }
            try await model.startQueue(next)
        }
    }
    func previous() {
        guard allows("skipping_prev") else { return }
        runPlayback(startsPlayback: true) { model in
            var next = model.queue
            guard next.previous() != nil else { return }
            try await model.startQueue(next)
        }
    }
    func seek(_ value: Double) {
        guard value.isFinite, allows("seeking"), acceptsPlayback else { return }
        pendingSeek = value
        guard !seekScheduled else { return }
        seekScheduled = true
        let store = store
        runPlayback { model in
            defer { if model.store === store { model.seekScheduled = false } }
            while model.store === store, let value = model.pendingSeek {
                model.pendingSeek = nil
                let target = min(max(0, value), model.currentTrack?.duration ?? 0)
                do {
                    if let engine = model.musicEngine {
                        try await engine.seek(absolute: target)
                    } else if model.isDemo {
                        model.position = target
                    }
                    model.notifyPlayback(.playbackRestarted)
                } catch {
                    if model.pendingSeek == nil {
                        model.pendingSeek = value
                        throw error
                    }
                }
            }
        }
    }
    func setVolume(_ value: Double) {
        guard value.isFinite, allows("volume"), acceptsPlayback else { return }
        pendingVolume = value
        guard !volumeScheduled else { return }
        volumeScheduled = true
        let store = store
        runPlayback { model in
            defer { if model.store === store { model.volumeScheduled = false } }
            while model.store === store, let value = model.pendingVolume {
                model.pendingVolume = nil
                do {
                    if let engine = model.musicEngine {
                        try await engine.setVolume(value)
                    } else if model.isDemo {
                        model.volume = min(100, max(0, value))
                    }
                    model.notifyPlayback()
                } catch {
                    if model.pendingVolume == nil {
                        model.pendingVolume = value
                        throw error
                    }
                }
            }
        }
    }
    func shuffleCollection() {
        if isQueue {
            shuffle()
        } else {
            playShuffled(contents.tracks)
        }
    }

    func playShuffled(_ tracks: [MusicTrack]) {
        guard allows("interrupting_playback"), allows("toggling_shuffle"), !tracks.isEmpty else {
            return
        }
        runPlayback(startsPlayback: true) { model in
            var next = MusicQueue()
            var random = SystemRandomNumberGenerator()
            next.startShuffled(tracks, using: &random)
            try await model.startQueue(next)
        }
    }

    func shuffle() {
        guard allows("toggling_shuffle") else { return }
        editQueue { queue in
            var random = SystemRandomNumberGenerator()
            queue.setShuffle(!queue.shuffled, using: &random)
        }
    }
    func cycleRepeat() {
        setRepeat(queue.repeatMode == .off ? .all : queue.repeatMode == .all ? .one : .off)
    }
    func setRepeat(_ value: MusicRepeat) {
        guard
            allows(
                value == .one || queue.repeatMode == .one
                    ? "toggling_repeat_track" : "toggling_repeat_context")
        else { return }
        editQueue { $0.repeatMode = value }
    }
    func setShuffle(_ value: Bool) {
        guard allows("toggling_shuffle") else { return }
        editQueue { queue in
            var random = SystemRandomNumberGenerator()
            queue.setShuffle(value, using: &random)
        }
    }
    func addToQueue(_ track: MusicTrack) {
        guard track.isPlayable != false else { return }
        editQueue { $0.add(track) }
    }
    func removeFromQueue(_ id: UUID) { editQueue { $0.remove(id) } }
    func moveQueue(_ id: UUID, before target: UUID) { editQueue { $0.move(id, before: target) } }

    private func editQueue(_ edit: @escaping (inout MusicQueue) -> Void) {
        guard paused || allows("interrupting_playback") else { return }
        runPlayback { model in
            var next = model.queue
            edit(&next)
            guard next != model.queue else { return }
            if let engine = model.musicEngine {
                try await engine.updateQueue(
                    next, position: model.displayedPosition, paused: model.paused)
            }
            model.queue = next
            if model.isQueue { model.refreshContents() }
            model.notifyPlayback()
        }
    }

    private func startQueue(_ next: MusicQueue, position: Double = 0) async throws {
        if musicEngine == nil, let engineFactory { connect(engine: engineFactory()) }
        guard next.current?.track.isPlayable != false else { throw SpotifyPlaybackError.restricted }
        let original = queue
        queue = next
        do {
            if let musicEngine {
                try await musicEngine.play(queue: next, position: position)
            } else if isDemo {
                beforeDemoPlayback()
                paused = false
                self.position = position
            } else {
                queue = original
                return
            }
            if isQueue { refreshContents() }
            notifyPlayback(.playbackRestarted)
        } catch {
            queue = original
            throw error
        }
    }

    private func runPlayback(
        startsPlayback: Bool = false,
        action: @escaping @MainActor (MusicViewModel) async throws -> Void
    ) {
        guard acceptsPlayback else { return }
        let store = store
        let operation: @MainActor () async throws -> Void = { [weak self] in
            guard let self, self.acceptsPlayback, self.store === store else { return }
            self.isPlaybackBusy = true
            defer {
                self.isPlaybackBusy = false
                self.notifyPlayback()
            }
            do {
                try await action(self)
                self.statusMessage = nil
                self.retryPlayback = nil
            } catch {
                self.retryPlayback = { [weak self] in
                    self?.runPlayback(startsPlayback: startsPlayback, action: action)
                }
                throw error
            }
        }
        if let coordinator {
            coordinator.perform(.music, startsPlayback: startsPlayback, action: operation)
        } else {
            Task {
                do { try await operation() } catch {
                    self.statusMessage = SpotifyStatus.message(error)
                }
            }
        }
    }

    func shutdownPlayback() async {
        if let musicEngine { await musicEngine.shutdown() }
        engineTask?.cancel()
        engineTask = nil
        musicEngine = nil
        paused = true
        lastSnapshot = nil
        notifyPlayback()
    }
    @discardableResult
    func observePlayback(_ observer: @escaping (PlaybackEvent?) -> Void) -> UUID {
        let id = UUID()
        playbackObservers[id] = observer
        return id
    }
    func removePlaybackObserver(_ id: UUID) { playbackObservers[id] = nil }
    func notifyPlayback(_ event: PlaybackEvent = .playbackRestarted) {
        for observer in playbackObservers.values { observer(event) }
    }
}
