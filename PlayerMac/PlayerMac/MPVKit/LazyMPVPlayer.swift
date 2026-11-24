import Foundation
import Observation

/// Defers libmpv and OpenGL initialization until a video is opened and releases
/// both completely when the video closes or parks after a long pause.
@MainActor @Observable
final class LazyMPVPlayer: PlayerEngine {
    @ObservationIgnored let events: AsyncStream<PlaybackEvent>
    private(set) var videoLayer: VideoLayer?
    var isActive: Bool { current != nil }

    @ObservationIgnored private let output: AsyncStream<PlaybackEvent>.Continuation
    @ObservationIgnored private let factory: @MainActor (Double) throws -> MPVPlayer
    @ObservationIgnored private var current: MPVPlayer?
    @ObservationIgnored private var forwarding: Task<Void, Never>?
    @ObservationIgnored private var retiring: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var inFlightLoads = 0
    @ObservationIgnored private var volume: Double = 100
    @ObservationIgnored private var isClosing = false

    init(
        factory: @escaping @MainActor (Double) throws -> MPVPlayer = {
            try MPVPlayer(initialVolume: $0)
        }
    ) {
        self.factory = factory
        (events, output) = AsyncStream.makeStream()
    }

    deinit {
        forwarding?.cancel()
    }

    var reportsLoadedPath: Bool { true }

    /// Verifies that libmpv and the OpenGL render context initialize cleanly under
    /// Hardened Runtime without retaining them afterward.
    func verifyStartup() throws {
        guard !isClosing, current == nil else { return }
        let probe = try factory(volume)
        retire(probe)
    }

    func load(url: URL) throws { try load(url: url, paused: false) }

    func load(url: URL, paused: Bool) throws {
        guard !isClosing else { throw MPVError("Player is already shutting down.") }
        try MPVPlayer.validate(url: url)
        let engine = try ensureEngine()
        try engine.load(url: url, paused: paused)
        inFlightLoads += 1
    }

    func setPaused(_ paused: Bool) throws {
        guard let current else { throw MPVError("No active video.") }
        try current.setPaused(paused)
    }

    func seek(relative seconds: Double) throws {
        guard let current else { throw MPVError("No active video.") }
        try current.seek(relative: seconds)
    }

    func seek(absolute seconds: Double) throws {
        guard let current else { throw MPVError("No active video.") }
        try current.seek(absolute: seconds)
    }

    func setVolume(_ value: Double) throws {
        guard !isClosing else { throw MPVError("Player is already shutting down.") }
        guard value.isFinite else { throw MPVError("Invalid volume.") }
        let clamped = min(100, max(0, value))
        volume = clamped
        if let current {
            try current.setVolume(clamped)
        } else {
            output.yield(.property(.volume, .number(clamped)))
        }
    }

    func selectTrack(kind: MediaTrackKind, number: Int64?, requestID: UInt64) throws {
        guard let current else { throw MPVError("No active video.") }
        try current.selectTrack(kind: kind, number: number, requestID: requestID)
    }

    func addTrack(url: URL, kind: MediaTrackKind, requestID: UInt64) throws {
        guard let current else { throw MPVError("No active video.") }
        try current.addTrack(url: url, kind: kind, requestID: requestID)
    }

    func cancelTrackCommand(id: UInt64) {
        current?.cancelTrackCommand(id: id)
    }

    func stop() throws {
        guard !isClosing else { throw MPVError("Player is already shutting down.") }
        releaseEngine()
    }

    func park() {
        releaseEngine()
    }

    func shutdown() async {
        isClosing = true
        releaseEngine()
        while !retiring.isEmpty {
            let pending = Array(retiring.values)
            for task in pending { await task.value }
        }
        output.finish()
    }

    private func ensureEngine() throws -> MPVPlayer {
        if let current { return current }
        guard !isClosing else { throw MPVError("Player is already shutting down.") }
        let engine = try factory(volume)
        current = engine
        videoLayer = engine.videoLayer
        let stream = engine.events
        let continuation = output
        forwarding = Task { [weak self, weak engine] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                guard let self, self.current === engine else { break }
                if case .shutdown = event { break }
                if case .ended(let error) = event {
                    if self.inFlightLoads > 0 { self.inFlightLoads -= 1 }
                    continuation.yield(event)
                    if error != nil, self.inFlightLoads == 0 {
                        self.releaseEngine()
                        break
                    }
                    continue
                }
                continuation.yield(event)
            }
        }
        return engine
    }

    private func releaseEngine() {
        forwarding?.cancel()
        forwarding = nil
        inFlightLoads = 0
        videoLayer = nil
        guard let previous = current else { return }
        current = nil
        retire(previous)
    }

    private func retire(_ engine: MPVPlayer) {
        let id = UUID()
        retiring[id] = Task { [weak self] in
            await engine.shutdown()
            self?.retiring[id] = nil
        }
    }
}
