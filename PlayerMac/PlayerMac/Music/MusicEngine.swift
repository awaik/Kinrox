import Foundation
import MusicCore

struct MusicPlaybackSnapshot: Equatable, Sendable {
    var uri: String?
    var position: Double
    var duration: Double
    var paused: Bool
    var volume: Double
    var deviceName: String
    var occurrenceID: UUID?
    var disallowedActions: Set<String> = []
}

enum MusicEngineEvent: Sendable {
    case state(MusicPlaybackSnapshot)
    case ended
    case failure(String)
}

/// Commands complete only after the service confirms the requested state.
@MainActor
protocol MusicEngine: AnyObject {
    var events: AsyncStream<MusicEngineEvent> { get }
    func play(queue: MusicQueue, position: Double) async throws
    func setPaused(_ paused: Bool) async throws
    func seek(absolute position: Double) async throws
    func setVolume(_ volume: Double) async throws
    func updateQueue(_ queue: MusicQueue, position: Double, paused: Bool) async throws
    func stop() async throws
    func shutdown() async
}
