import Foundation
import MusicCore

struct MusicPlaybackSnapshot: Equatable, Sendable {
    var uri: String?
    var position: Double
    var duration: Double
    var paused: Bool
    var volume: Double?
    var deviceName: String
    var occurrenceID: UUID?
    var disallowedActions: Set<String> = []
}

enum MusicEngineEvent: Sendable {
    case state(MusicPlaybackSnapshot)
    case ended(occurrenceID: UUID)
    case availability(MusicEngineAvailability)
    case failure(String)
}

enum MusicEngineAvailability: Equatable, Sendable {
    case notInstalled, downloading, needsKey, needsPairing, starting, ready
    case reconnecting, expired, externalTakeover
    case failed(String)
}

/// Commands complete only after the service confirms the requested state.
@MainActor
protocol MusicEngine: AnyObject {
    var events: AsyncStream<MusicEngineEvent> { get }
    func canResume(_ queue: MusicQueue) -> Bool
    func play(queue: MusicQueue, position: Double) async throws
    func setPaused(_ paused: Bool) async throws
    func seek(absolute position: Double) async throws
    func setVolume(_ volume: Double) async throws
    func updateQueue(_ queue: MusicQueue, position: Double, paused: Bool) async throws
    func stop() async throws
    func shutdown() async
}
extension MusicEngine {
    func canResume(_ queue: MusicQueue) -> Bool { false }
}
