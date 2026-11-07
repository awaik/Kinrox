import Foundation

/// Explicit task chain serializes complete commands across actor suspension points.
actor SoloistRuntime {
    enum Operation: Sendable {
        case load(uri: String, occurrenceID: UUID, position: Double)
        case pause(Bool)
        case seek(Double)
        case volume(Double)
        case stop
        case parkIfIdle(epoch: UInt64, command: UInt64)
    }
    nonisolated let events: AsyncStream<MusicEngineEvent>
    private let output: SoloistEventBuffer
    private let driver: any SoloistDriving
    private let parkDelay: Duration
    private let dispatchTimeout: Double
    private let observationTimeout: Double
    private var state = SoloistStateReducer()
    private var epoch: UInt64 = 0
    private var commandID: UInt64 = 0
    private var tail: Task<Void, Never>?
    private var jobs: [UUID: Task<Void, Error>] = [:]
    private var parking: Task<Void, Never>?
    private var resumeQuery: Task<Void, Never>?
    private var resumeRecheck = false
    private var playbackActivity: (any NSObjectProtocol)?
    private var alive = false
    private var closed = false
    private var gain: Double
    private let onVolumeChange: (@MainActor @Sendable (Double) -> Void)?
    private var acknowledgements: UInt64 = 0
    private var errors: UInt64 = 0
    private var awaiting: SoloistCommand.Kind?

    init(
        driver: any SoloistDriving, parkDelay: Duration = .seconds(20),
        dispatchTimeout: Double = 2, observationTimeout: Double = 10,
        initialVolume: Double = 0,
        onVolumeChange: (@MainActor @Sendable (Double) -> Void)? = nil
    ) {
        self.driver = driver
        self.parkDelay = parkDelay
        self.dispatchTimeout = dispatchTimeout
        self.observationTimeout = observationTimeout
        self.gain = Double(Int(min(100, max(0, initialVolume))))
        self.onVolumeChange = onVolumeChange
        let output = SoloistEventBuffer()
        self.output = output
        events = AsyncStream(unfolding: { await output.next() })
    }

    func perform(_ operation: Operation) async throws {
        guard !closed, jobs.count < 32 else { throw SoloistFailure.closed }
        let previous = tail
        let id = UUID()
        let job = Task {
            await previous?.value
            try Task.checkCancellation()
            guard !self.closed else { throw SoloistFailure.closed }
            if case .parkIfIdle(let epoch, let command) = operation {
                guard self.epoch == epoch, self.commandID == command, self.state.snapshot.paused,
                    self.resumeQuery == nil
                else { return }
            }
            self.commandID &+= 1
            self.parking?.cancel()
            do {
                try await self.execute(operation)
            } catch {
                await self.park()
                if !self.closed, !(error is CancellationError) {
                    await self.output.send(
                        .availability(.failed("Soloist could not confirm the playback command.")))
                }
                throw error
            }
        }
        jobs[id] = job
        tail = Task { _ = await job.result }
        defer { jobs.removeValue(forKey: id) }
        try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    func confirmedSnapshot() -> MusicPlaybackSnapshot { state.current(at: .now) }

    /// Power transitions retire pending commands and preserve the pre-sleep position.
    func suspend() async {
        guard !closed else { return }
        let snapshot = state.current(at: .now)
        let wasRunning = alive || !jobs.isEmpty
        parking?.cancel()
        for job in jobs.values { job.cancel() }
        await tail?.value
        guard !closed else { return }
        await park()
        guard !closed else { return }
        if state.snapshot.occurrenceID == snapshot.occurrenceID {
            state.setParkedPosition(snapshot.position, now: .now)
            await output.send(.state(state.snapshot))
        }
        if wasRunning { await output.send(.availability(.ready)) }
    }

    private func execute(_ operation: Operation) async throws {
        switch operation {
        case .load(let uri, let id, let position):
            guard position.isFinite, position >= 0 else { throw SoloistFailure.invalidCommand }
            try await load(uri: uri, id: id, position: position)
        case .pause(let paused):
            if paused, !alive {
                // Video may start before music has ever loaded. Join any teardown, without
                // requiring an occurrence or launching Soloist merely to confirm silence.
                await park()
                return
            }
            guard state.snapshot.occurrenceID != nil else { throw SoloistFailure.emptyQueue }
            if !paused, !alive || state.inactive {
                guard let uri = state.snapshot.uri, let id = state.snapshot.occurrenceID else {
                    throw SoloistFailure.emptyQueue
                }
                let resumePosition =
                    state.snapshot.duration > 0
                        && state.snapshot.position >= state.snapshot.duration - 1.5
                    ? 0 : state.snapshot.position
                try await load(uri: uri, id: id, position: resumePosition)
            } else if alive {
                state.suppressEnd = paused
                try await mutate(.init(command: paused ? .pause : .play)) {
                    paused ? $0.snapshot.paused : $0.ready
                }
                if paused {
                    try await query()
                    scheduleParking()
                }
            }
        case .seek(let target):
            guard target.isFinite, state.snapshot.occurrenceID != nil else {
                throw SoloistFailure.invalidCommand
            }
            let target = min(max(0, target), max(0, state.snapshot.duration - 1))
            if !alive {
                state.setParkedPosition(target, now: .now)
                await output.send(.state(state.snapshot))
            } else {
                state.suppressEnd = true
                let paused = state.snapshot.paused
                try await mutate(.init(command: .seek, positionMS: target * 1000)) {
                    abs($0.snapshot.position - target) < 1
                        && (paused ? $0.snapshot.paused : $0.ready)
                }
                state.suppressEnd = paused
                if paused { scheduleParking() }
            }
        case .volume(let volume):
            guard volume.isFinite, alive else { throw SoloistFailure.unavailable }
            let target = Double(Int(min(100, max(0, volume))))
            try await mutate(.init(command: .volume, volume: target)) {
                $0.snapshot.volume == target
            }
            gain = target
            await onVolumeChange?(target)
            if state.snapshot.paused { scheduleParking() }
        case .stop:
            await park()
            state.setParkedPosition(0, now: .now)
            await output.send(.state(state.snapshot))
        case .parkIfIdle:
            await park()
        }
    }

    private func load(uri: String, id: UUID, position: Double) async throws {
        let loadStart = ContinuousClock.now
        defer { SoloistTiming.record(.load, since: loadStart) }
        parking?.cancel()
        parking = nil
        resumeQuery?.cancel()
        resumeQuery = nil
        resumeRecheck = false
        state.retire(now: .now)
        alive = false
        epoch &+= 1
        state.begin(epoch: epoch, occurrenceID: id, uri: uri, now: .now)
        state.suppressEnd = true
        await output.send(.availability(.starting))
        alive = true
        setPlaybackActivity(true)
        try await driver.replace(uri: uri, epoch: epoch) { [weak self] input in
            await self?.receive(input)
        }
        let socketStart = ContinuousClock.now
        try await wait(seconds: 15) { self.state.ready && self.state.loggedIn }
        SoloistTiming.record(.socketToPlayback, since: socketStart)
        if position >= 1, state.snapshot.duration <= 0 || position < state.snapshot.duration - 1.5 {
            let target = min(position, max(0, state.snapshot.duration - 1))
            try await mutate(.init(command: .seek, positionMS: target * 1000)) {
                $0.ready && abs($0.snapshot.position - target) < 1
            }
        }
        if state.snapshot.volume != gain {
            try await mutate(.init(command: .volume, volume: gain)) {
                $0.snapshot.volume == self.gain
            }
        }
        state.suppressEnd = false
        await output.send(.availability(.ready))
        await output.send(.state(state.current(at: .now)))
    }

    private func mutate(_ command: SoloistCommand, confirmed: (SoloistStateReducer) -> Bool)
        async throws
    {
        let sequence = acknowledgements
        let failures = errors
        let revision = state.revision
        awaiting = command.command
        let sending = Task { try await driver.send(command) }
        defer {
            sending.cancel()
            awaiting = nil
        }
        do {
            try await wait(seconds: dispatchTimeout) {
                self.acknowledgements > sequence || self.errors > failures
            }
        } catch {
            // There are no request IDs. A missing ACK retires this process/epoch before another command.
            await park()
            try Task.checkCancellation()
            throw SoloistFailure.dispatchTimeout
        }
        guard errors == failures else { throw SoloistFailure.rejected }
        if state.revision == revision, confirmed(state) { try await query() }
        do {
            try await wait(seconds: observationTimeout) {
                confirmed(self.state) && self.state.revision > revision
            }
        } catch {
            try Task.checkCancellation()
            // Acceptance arrived: reconcile on the same healthy socket before deciding to stop.
            try await query()
            guard confirmed(state) else { throw SoloistFailure.observationTimeout }
        }
    }

    private func query() async throws {
        let revision = state.stateRevision
        let sending = Task { try await driver.send(.init(command: .state)) }
        defer { sending.cancel() }
        try await wait(seconds: 2) { self.state.stateRevision > revision }
    }

    private func wait(seconds: Double, until predicate: () -> Bool) async throws {
        let expected = epoch
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !predicate() {
            try Task.checkCancellation()
            guard !closed, alive, epoch == expected else { throw SoloistFailure.closed }
            guard ContinuousClock.now < deadline else { throw SoloistFailure.observationTimeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        guard !closed, epoch == expected else { throw SoloistFailure.closed }
    }

    private func receive(_ input: SoloistInput) async {
        guard !closed else { return }
        switch input {
        case .frame(let frame, let source):
            guard source == epoch, alive else { return }
            if frame.type == "command_result", frame.command == awaiting?.rawValue {
                acknowledgements &+= 1
            }
            if frame.type == "error" { errors &+= 1 }
            let wasPaused = state.snapshot.paused
            let events = state.receive(frame, epoch: source, now: .now)
            if frame.status == "paused", !wasPaused, state.snapshot.paused {
                // Connect can pause playback without a Kinrox command; apply the same idle policy.
                scheduleParking()
            }
            if wasPaused, !state.snapshot.paused {
                parking?.cancel()
                parking = nil
            }
            if frame.type == "playback_changed", frame.status == "playing",
                state.snapshot.paused, state.hasPlayed, !state.terminalBoundary
            {
                reconcileResume()
            }
            setPlaybackActivity(alive && (!state.snapshot.paused || !state.hasPlayed))
            for event in events {
                await output.send(event)
                if case .availability(.externalTakeover) = event { await park() }
            }
        case .exited(let code, let source):
            guard source == epoch, alive else { return }
            alive = false
            parking?.cancel()
            let events = state.processExited(code: code, epoch: source, now: .now)
            if !events.contains(where: { if case .ended = $0 { true } else { false } }) {
                setPlaybackActivity(false)
            }
            for event in events {
                await output.send(event)
            }
        case .disconnected(let source), .protocolFailure(let source):
            guard source == epoch, alive else { return }
            // A natural process exit closes the socket too; allow its direct exit notification first.
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard source == self.epoch, self.alive, !self.closed else { return }
                await self.park()
                await self.output.send(.availability(.reconnecting))
            }
        }
    }

    private func reconcileResume() {
        parking?.cancel()
        parking = nil
        if resumeQuery != nil {
            resumeRecheck = true
            return
        }
        let expected = epoch
        // Do not await inside receive: the socket loop must deliver the requested full state.
        resumeQuery = Task {
            defer {
                if self.epoch == expected {
                    self.resumeQuery = nil
                    self.resumeRecheck = false
                }
            }
            do {
                repeat {
                    self.resumeRecheck = false
                    try await self.query()
                    guard self.epoch == expected, self.alive else { return }
                } while self.resumeRecheck && self.state.snapshot.paused
                if self.state.snapshot.paused, self.state.wireStatus == "paused",
                    !self.state.terminalBoundary
                {
                    self.scheduleParking()
                }
            } catch {
                guard self.epoch == expected, self.alive, !self.closed else { return }
                await self.park()
                await self.output.send(.availability(.reconnecting))
            }
        }
    }

    private func scheduleParking() {
        parking?.cancel()
        let expected = epoch
        let command = commandID
        parking = Task {
            do { try await Task.sleep(for: parkDelay) } catch { return }
            guard expected == epoch, command == commandID, state.snapshot.paused, !closed else {
                return
            }
            // Join the command chain. A new Play must await teardown, not race its suspension.
            parking = nil
            try? await perform(.parkIfIdle(epoch: expected, command: command))
        }
    }

    private func park() async {
        resumeQuery?.cancel()
        resumeQuery = nil
        resumeRecheck = false
        parking?.cancel()
        parking = nil
        setPlaybackActivity(false)
        let position = state.position(at: .now)
        state.retire(now: .now)
        alive = false
        epoch &+= 1
        let retired = epoch
        await driver.stop()
        guard epoch == retired else { return }
        state.setParkedPosition(position, now: .now)
        if !closed { await output.send(.state(state.snapshot)) }
    }

    func shutdown() async {
        guard !closed else { return }
        closed = true
        setPlaybackActivity(false)
        await output.finish()
        resumeQuery?.cancel()
        resumeQuery = nil
        resumeRecheck = false
        parking?.cancel()
        for job in jobs.values { job.cancel() }
        state.retire(now: .now)
        alive = false
        epoch &+= 1
        await driver.close()
        await tail?.value
    }

    private func setPlaybackActivity(_ active: Bool) {
        if active, !closed {
            guard playbackActivity == nil else { return }
            playbackActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Kinrox Spotify playback")
        } else if let activity = playbackActivity {
            playbackActivity = nil
            ProcessInfo.processInfo.endActivity(activity)
        }
    }
}
