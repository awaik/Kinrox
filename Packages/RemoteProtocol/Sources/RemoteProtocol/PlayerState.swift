import Foundation

/// State confirmed by playback engine; receipt timestamp is maintained by the client.
public struct PlayerState: Codable, Sendable, Equatable {
    public var title: String
    public var position: Double
    public var duration: Double
    public var paused: Bool
    public var volume: Double
    public var fullscreen: Bool
    public var hasMedia: Bool
    public var canNext: Bool
    public var canPrevious: Bool
    public var screensaver: Screensaver?

    public init(
        title: String, position: Double, duration: Double, paused: Bool, volume: Double,
        fullscreen: Bool, hasMedia: Bool, canNext: Bool, canPrevious: Bool,
        screensaver: Screensaver? = nil
    ) {
        self.title = title
        self.position = position
        self.duration = duration
        self.paused = paused
        self.volume = volume
        self.fullscreen = fullscreen
        self.hasMedia = hasMedia
        self.canNext = canNext
        self.canPrevious = canPrevious
        self.screensaver = screensaver
    }
}

/// Network model intentionally excludes file path and bookmark.
public struct RecentItem: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var duration: Double?
    public var available: Bool

    public init(id: UUID, title: String, duration: Double? = nil, available: Bool) {
        self.id = id
        self.title = title
        self.duration = duration
        self.available = available
    }
}
