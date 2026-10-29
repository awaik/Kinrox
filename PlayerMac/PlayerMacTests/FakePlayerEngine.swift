import Foundation

@testable import Kinrox

/// Engine without libmpv: records commands, test supplies events.
@MainActor
final class FakePlayerEngine: PlayerEngine {
    enum Command: Equatable {
        case load(URL)
        case paused(Bool)
        case seekRelative(Double)
        case seekAbsolute(Double)
        case volume(Double)
        case stop
        case selectTrack(MediaTrackKind, Int64?, UInt64)
        case addTrack(URL, MediaTrackKind, UInt64)
        case cancelTrack(UInt64)
    }

    let events: AsyncStream<PlaybackEvent>
    let continuation: AsyncStream<PlaybackEvent>.Continuation
    var commands: [Command] = []
    var loadError: Error?
    var commandError: Error?
    var shutdownCount = 0

    var openedURLs: [URL] {
        commands.compactMap { if case .load(let url) = $0 { url } else { nil } }
    }

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func load(url: URL) throws {
        if let loadError { throw loadError }
        commands.append(.load(url))
    }
    func setPaused(_ paused: Bool) throws {
        if let commandError { throw commandError }
        commands.append(.paused(paused))
    }
    func seek(relative seconds: Double) throws {
        if let commandError { throw commandError }
        commands.append(.seekRelative(seconds))
    }
    func seek(absolute seconds: Double) throws {
        if let commandError { throw commandError }
        commands.append(.seekAbsolute(seconds))
    }
    func setVolume(_ volume: Double) throws { commands.append(.volume(volume)) }
    func stop() throws { commands.append(.stop) }
    func selectTrack(kind: MediaTrackKind, number: Int64?, requestID: UInt64) throws {
        if let commandError { throw commandError }
        commands.append(.selectTrack(kind, number, requestID))
    }
    func addTrack(url: URL, kind: MediaTrackKind, requestID: UInt64) throws {
        if let commandError { throw commandError }
        commands.append(.addTrack(url, kind, requestID))
    }
    func cancelTrackCommand(id: UInt64) { commands.append(.cancelTrack(id)) }
    func shutdown() async {
        shutdownCount += 1
        continuation.finish()
    }
}
