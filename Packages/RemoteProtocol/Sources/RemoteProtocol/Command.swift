import Foundation

/// v1 commands. Encoding by `kind` preserves flat JSON format.
public enum Command: Codable, Sendable, Equatable {
    case togglePause
    case setPaused(paused: Bool)
    case seekRelative(seconds: Double)
    case seekAbsolute(seconds: Double)
    case setVolume(volume: Double)
    case next
    case previous
    case openRecent(itemId: UUID)
    case toggleFullscreen
    case setFullscreen(fullscreen: Bool)
    case setScreensaver(screensaver: Screensaver)

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case togglePause, setPaused, seekRelative, seekAbsolute, setVolume
        case next, previous, openRecent, toggleFullscreen, setFullscreen
        case setScreensaver
    }

    public var kind: Kind {
        switch self {
        case .togglePause: .togglePause
        case .setPaused: .setPaused
        case .seekRelative: .seekRelative
        case .seekAbsolute: .seekAbsolute
        case .setVolume: .setVolume
        case .next: .next
        case .previous: .previous
        case .openRecent: .openRecent
        case .toggleFullscreen: .toggleFullscreen
        case .setFullscreen: .setFullscreen
        case .setScreensaver: .setScreensaver
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, paused, seconds, volume, itemId, fullscreen, screensaver
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: rawKind) else {
            throw ProtocolError(code: .unknownMessage, message: "Unknown command.")
        }
        switch kind {
        case .togglePause: self = .togglePause
        case .setPaused: self = .setPaused(paused: try container.decode(Bool.self, forKey: .paused))
        case .seekRelative:
            self = .seekRelative(seconds: try container.decode(Double.self, forKey: .seconds))
        case .seekAbsolute:
            self = .seekAbsolute(seconds: try container.decode(Double.self, forKey: .seconds))
        case .setVolume:
            self = .setVolume(volume: try container.decode(Double.self, forKey: .volume))
        case .next: self = .next
        case .previous: self = .previous
        case .openRecent:
            self = .openRecent(itemId: try container.decode(UUID.self, forKey: .itemId))
        case .toggleFullscreen: self = .toggleFullscreen
        case .setFullscreen:
            self = .setFullscreen(fullscreen: try container.decode(Bool.self, forKey: .fullscreen))
        case .setScreensaver:
            self = .setScreensaver(
                screensaver: try container.decode(Screensaver.self, forKey: .screensaver))
        }
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .setPaused(let paused): try container.encode(paused, forKey: .paused)
        case .seekRelative(let seconds), .seekAbsolute(let seconds):
            try container.encode(seconds, forKey: .seconds)
        case .setVolume(let volume): try container.encode(volume, forKey: .volume)
        case .openRecent(let itemId): try container.encode(itemId, forKey: .itemId)
        case .setFullscreen(let fullscreen): try container.encode(fullscreen, forKey: .fullscreen)
        case .setScreensaver(let screensaver):
            try container.encode(screensaver, forKey: .screensaver)
        case .togglePause, .next, .previous, .toggleFullscreen: break
        }
    }

    private func validate() throws {
        let valid: Bool
        switch self {
        case .seekRelative(let seconds): valid = seconds.isFinite
        case .seekAbsolute(let seconds): valid = seconds.isFinite && seconds >= 0
        case .setVolume(let volume): valid = volume.isFinite && (0...100).contains(volume)
        default: valid = true
        }
        guard valid else {
            throw ProtocolError(code: .invalidPayload, message: "Invalid command parameter.")
        }
    }
}
