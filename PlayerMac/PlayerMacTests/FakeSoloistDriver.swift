import Foundation

@testable import Kinrox

actor FakeSoloistDriver: SoloistDriving {
    enum Mode { case normal, dropAcknowledgement, deferredObservation, deactivateAfterPause }
    private var mode = Mode.normal
    private var callback: (@Sendable (SoloistInput) async -> Void)?
    private var epoch: UInt64 = 0
    private var uri = ""
    private var paused = false
    private var position: Double = 0
    private var volume: Double = 0
    private var alive = false
    private var delay = Duration.zero
    private var inFlight = 0
    private var stopDelay = Duration.zero
    private var stopping = false
    private(set) var maximumInFlight = 0
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var overlaps = 0
    private(set) var commands: [SoloistCommand.Kind] = []

    func configure(_ mode: Mode, delay: Duration = .zero) {
        self.mode = mode
        self.delay = delay
    }
    func delayStop(by delay: Duration) { stopDelay = delay }
    func simulateExternalPause() async throws {
        paused = true
        try await snapshot()
    }
    func simulateExternalResume(includePosition: Bool) async throws {
        paused = false
        var frame: [String: Any] = ["type": "playback_changed", "status": "playing"]
        if includePosition { frame["position"] = ["position_ms": position * 1000, "speed": 1] }
        try await emit(frame)
    }
    func simulateSocketLoss() async {
        await callback?(.disconnected(epoch: epoch))
    }
    func start(
        uri: String, epoch: UInt64, receive: @escaping @Sendable (SoloistInput) async -> Void
    ) async throws {
        if alive || stopping { overlaps += 1 }
        alive = true
        starts += 1
        self.epoch = epoch
        self.uri = uri
        self.callback = receive
        paused = false
        position = 0
        volume = 0
        try await emit(["type": "auth_state", "logged_in": true, "is_active": true])
        try await snapshot()
    }
    func send(_ command: SoloistCommand) async throws {
        commands.append(command.command)
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        if delay != .zero { try await Task.sleep(for: delay) }
        switch command.command {
        case .pause: paused = true
        case .play: paused = false
        case .seek: position = command.positionMS! / 1000
        case .volume: volume = command.volume!
        case .state:
            try await snapshot()
            if mode == .deactivateAfterPause, paused {
                try await emit(["type": "device_changed", "is_active": false])
            }
            return
        }
        if mode != .deferredObservation {
            if command.command == .volume {
                try await emit(["type": "volume_changed", "volume": volume])
            } else {
                try await snapshot()
            }
        }
        if mode != .dropAcknowledgement {
            try await emit(["type": "command_result", "command": command.command.rawValue])
        }
    }
    func stop() async {
        if stopping { return }
        guard alive else { return }
        stops += 1
        stopping = true
        if stopDelay != .zero {
            let duration = stopDelay
            await Task.detached { try? await Task.sleep(for: duration) }.value
        }
        alive = false
        stopping = false
    }
    func close() async { await stop() }
    private func snapshot() async throws {
        try await emit([
            "type": "playback_state", "status": paused ? "paused" : "playing", "is_active": true,
            "item": ["uri": uri, "decorations": ["playback": ["duration_ms": 100_000]]],
            "position": ["position_ms": position * 1000, "speed": paused ? 0 : 1], "volume": volume,
        ])
    }
    private func emit(_ value: [String: Any]) async throws {
        let frame = try SoloistFrame.decode(JSONSerialization.data(withJSONObject: value))
        await callback?(.frame(frame, epoch: epoch))
    }
}
