import Foundation
import MusicCore

/// Native adapter prepared behind the plan's cutover gates; library requests remain separate.
@MainActor
final class SoloistMusicEngine: MusicEngine {
    let events: AsyncStream<MusicEngineEvent>
    private let runtime: SoloistRuntime
    private var current: UUID?
    private var closed = false
    private var sleeping = false
    private var sleepGeneration: UInt64 = 0
    private var sleepTask: Task<Void, Never>?
    private var sleepObserver: SoloistSleepObserver?

    init(runtime: SoloistRuntime, observeSystemSleep: Bool = true) {
        self.runtime = runtime
        events = runtime.events
        if observeSystemSleep {
            sleepObserver = SoloistSleepObserver(
                sleep: { [weak self] in self?.willSleep() },
                wake: { [weak self] in Task { await self?.didWake() } })
        }
    }

    func canResume(_ queue: MusicQueue) -> Bool {
        !closed && !sleeping && current != nil && current == queue.current?.id
    }
    func play(queue: MusicQueue, position: Double) async throws {
        guard !closed, !sleeping else { throw SoloistFailure.unavailable }
        guard let item = queue.current else { throw SoloistFailure.emptyQueue }
        guard item.track.isPlayable != false else { throw SoloistFailure.unavailable }
        try await runtime.perform(
            .load(uri: item.track.uri, occurrenceID: item.id, position: position))
        guard !closed else { throw SoloistFailure.closed }
        current = item.id
    }
    func setPaused(_ paused: Bool) async throws {
        guard paused || !sleeping else { throw SoloistFailure.unavailable }
        try await runtime.perform(.pause(paused))
    }
    func seek(absolute position: Double) async throws {
        guard !sleeping else { throw SoloistFailure.unavailable }
        try await runtime.perform(.seek(position))
    }
    func setVolume(_ volume: Double) async throws {
        guard !sleeping else { throw SoloistFailure.unavailable }
        try await runtime.perform(.volume(volume))
    }
    func updateQueue(_ queue: MusicQueue, position: Double, paused: Bool) async throws {
        guard current == queue.current?.id else { throw SoloistFailure.invalidCommand }
        // Upcoming order/repeat/shuffle belong to MusicQueue, never the backend queue.
    }
    func stop() async throws { try await runtime.perform(.stop) }
    func willSleep() {
        guard !closed else { return }
        sleeping = true
        sleepGeneration &+= 1
        let previous = sleepTask
        sleepTask = Task {
            await previous?.value
            await runtime.suspend()
        }
    }
    func didWake() async {
        let generation = sleepGeneration
        await sleepTask?.value
        guard !closed, generation == sleepGeneration else { return }
        sleeping = false
    }
    func shutdown() async {
        guard !closed else { return }
        closed = true
        sleepObserver?.stop()
        sleepObserver = nil
        current = nil
        await runtime.shutdown()
        await sleepTask?.value
        sleepTask = nil
    }
}
