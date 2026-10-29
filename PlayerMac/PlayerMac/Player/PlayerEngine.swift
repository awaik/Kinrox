import Foundation

enum PlaybackProperty: String, Sendable, CaseIterable {
    case paused = "pause"
    case position = "time-pos"
    case duration
    case volume
    case title = "media-title"
    case endReached = "eof-reached"
    case idle = "idle-active"
    case buffering = "paused-for-cache"
    case hardwareDecoder = "hwdec-current"
    case audioOutput = "current-ao"
    case audioCodec = "audio-codec-name"
    case tracks = "track-list"
}

enum PlaybackValue: Sendable, Equatable {
    case flag(Bool)
    case number(Double)
    case text(String)
    case tracks([MediaTrack])
    case unavailable
}

enum PlaybackEvent: Sendable, Equatable {
    case property(PlaybackProperty, PlaybackValue)
    case started
    case loaded
    case seeking
    case playbackRestarted
    case ended(error: String?)
    case failure(String)
    case tracksLoaded(path: String, tracks: [MediaTrack])
    case trackCommandCompleted(id: UInt64, error: String?)
    case shutdown
}

@MainActor
protocol PlayerEngine: AnyObject {
    var events: AsyncStream<PlaybackEvent> { get }
    func load(url: URL) throws
    func setPaused(_ paused: Bool) throws
    func seek(relative seconds: Double) throws
    func seek(absolute seconds: Double) throws
    func setVolume(_ volume: Double) throws
    func selectTrack(kind: MediaTrackKind, number: Int64?, requestID: UInt64) throws
    func addTrack(url: URL, kind: MediaTrackKind, requestID: UInt64) throws
    func cancelTrackCommand(id: UInt64)
    func stop() throws
    func shutdown() async
}
