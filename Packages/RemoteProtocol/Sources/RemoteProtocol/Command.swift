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

    case setTrackLiked(trackId: String, liked: Bool)
    case setPlaylistMembership(trackId: String, playlistId: String, included: Bool)
    case setArtistFollowed(artistId: String, followed: Bool)
    case createPlaylist(title: String, trackId: String)
    case setShuffle(shuffle: Bool)
    case setRepeat(repeatMode: RemoteMusicRepeat)
    case queueMove(itemId: UUID, beforeId: UUID)
    case queueRemove(itemId: UUID)

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case togglePause, setPaused, seekRelative, seekAbsolute, setVolume
        case next, previous, openRecent, toggleFullscreen, setFullscreen
        case setScreensaver
        case setTrackLiked, setPlaylistMembership, setArtistFollowed, createPlaylist
        case setShuffle, setRepeat, queueMove, queueRemove
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
        case .setTrackLiked: .setTrackLiked
        case .setPlaylistMembership: .setPlaylistMembership
        case .setArtistFollowed: .setArtistFollowed
        case .createPlaylist: .createPlaylist
        case .setShuffle: .setShuffle
        case .setRepeat: .setRepeat
        case .queueMove: .queueMove
        case .queueRemove: .queueRemove
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, paused, seconds, volume, itemId, fullscreen, screensaver
        case trackId, liked, playlistId, included, artistId, followed, title, shuffle, repeatMode,
            beforeId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: rawKind) else {
            throw ProtocolError(code: .unknownMessage, message: "Unknown command.")
        }
        switch kind {
        case .setTrackLiked:
            self = .setTrackLiked(
                trackId: try container.decode(String.self, forKey: .trackId),
                liked: try container.decode(Bool.self, forKey: .liked))
        case .setPlaylistMembership:
            self = .setPlaylistMembership(
                trackId: try container.decode(String.self, forKey: .trackId),
                playlistId: try container.decode(String.self, forKey: .playlistId),
                included: try container.decode(Bool.self, forKey: .included))
        case .setArtistFollowed:
            self = .setArtistFollowed(
                artistId: try container.decode(String.self, forKey: .artistId),
                followed: try container.decode(Bool.self, forKey: .followed))
        case .createPlaylist:
            self = .createPlaylist(
                title: try container.decode(String.self, forKey: .title),
                trackId: try container.decode(String.self, forKey: .trackId))
        case .setShuffle:
            self = .setShuffle(shuffle: try container.decode(Bool.self, forKey: .shuffle))
        case .setRepeat:
            self = .setRepeat(
                repeatMode: try container.decode(RemoteMusicRepeat.self, forKey: .repeatMode))
        case .queueMove:
            self = .queueMove(
                itemId: try container.decode(UUID.self, forKey: .itemId),
                beforeId: try container.decode(UUID.self, forKey: .beforeId))
        case .queueRemove:
            self = .queueRemove(itemId: try container.decode(UUID.self, forKey: .itemId))
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
        case .setTrackLiked(let trackId, let liked):
            try container.encode(trackId, forKey: .trackId)
            try container.encode(liked, forKey: .liked)
        case .setPlaylistMembership(let trackId, let playlistId, let included):
            try container.encode(trackId, forKey: .trackId)
            try container.encode(playlistId, forKey: .playlistId)
            try container.encode(included, forKey: .included)
        case .setArtistFollowed(let artistId, let followed):
            try container.encode(artistId, forKey: .artistId)
            try container.encode(followed, forKey: .followed)
        case .createPlaylist(let title, let trackId):
            try container.encode(title, forKey: .title)
            try container.encode(trackId, forKey: .trackId)
        case .setShuffle(let shuffle): try container.encode(shuffle, forKey: .shuffle)
        case .setRepeat(let mode): try container.encode(mode, forKey: .repeatMode)
        case .queueMove(let itemId, let beforeId):
            try container.encode(itemId, forKey: .itemId)
            try container.encode(beforeId, forKey: .beforeId)
        case .queueRemove(let itemId): try container.encode(itemId, forKey: .itemId)
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

    static func validMusicID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
    }

    private func validate() throws {
        let valid: Bool
        switch self {
        case .seekRelative(let seconds): valid = seconds.isFinite
        case .seekAbsolute(let seconds): valid = seconds.isFinite && seconds >= 0
        case .setVolume(let volume): valid = volume.isFinite && (0...100).contains(volume)
        case .setTrackLiked(let id, _), .setArtistFollowed(let id, _): valid = Self.validMusicID(id)
        case .setPlaylistMembership(let trackId, let playlistId, _):
            valid = Self.validMusicID(trackId) && Self.validMusicID(playlistId)
        case .createPlaylist(let title, let trackId):
            valid =
                Self.validMusicID(trackId)
                && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && title.utf8.count <= 300
        default: valid = true
        }
        guard valid else {
            throw ProtocolError(code: .invalidPayload, message: "Invalid command parameter.")
        }
    }
}
