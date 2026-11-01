import Foundation
import MusicCore

@testable import Kinrox

@MainActor
final class FakeMusicEngine: MusicEngine {
    enum Command: Equatable {
        case play([UUID], Double)
        case pause(Bool)
        case seek(Double)
        case volume(Double)
        case update([UUID])
        case stop
    }
    let events: AsyncStream<MusicEngineEvent>
    let continuation: AsyncStream<MusicEngineEvent>.Continuation
    var commands: [Command] = []
    var pauseError: Error?
    var pauseGate: CheckedContinuation<Void, Never>?
    var waitsForPause = false
    var shutdownCount = 0
    init() { (events, continuation) = AsyncStream.makeStream() }
    func play(queue: MusicQueue, position: Double) async throws {
        commands.append(.play(queue.items.map(\.id), position))
    }
    func setPaused(_ paused: Bool) async throws {
        commands.append(.pause(paused))
        if let pauseError { throw pauseError }
        if waitsForPause { await withCheckedContinuation { pauseGate = $0 } }
    }
    func seek(absolute position: Double) async throws { commands.append(.seek(position)) }
    func setVolume(_ volume: Double) async throws { commands.append(.volume(volume)) }
    func updateQueue(_ queue: MusicQueue, position: Double, paused: Bool) async throws {
        commands.append(.update(queue.items.map(\.id)))
    }
    func stop() async throws { commands.append(.stop) }
    func shutdown() async {
        shutdownCount += 1
        continuation.finish()
    }
}
