import Foundation
import MusicCore

public struct SpotifyPage<Item: Decodable & Sendable>: Decodable, Sendable {
    public let items: [Item]
    public let next: String?
}

public struct SpotifyProfile: Decodable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }

    public let id: String
    public let displayName: String?
}

public struct SpotifyAlbum: Decodable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, uri, name, artists, tracks
        case totalTracks = "total_tracks"
        case releaseDate = "release_date"
    }

    public let id: String
    public let uri: String
    public let name: String
    public let artists: [MusicArtist]
    public let totalTracks: Int?
    public let releaseDate: String?
    public let tracks: SpotifyPage<SpotifyTrack>?

    public func model(trackIDs: [String] = []) -> MusicAlbum {
        MusicAlbum(
            id: id, uri: uri, title: name, artists: artists,
            year: String((releaseDate ?? "").prefix(4)), trackIDs: trackIDs,
            totalTrackCount: totalTracks)
    }
}

public struct SpotifyTrack: Decodable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, uri, name, artists, album, type, explicit
        case durationMS = "duration_ms"
        case isLocal = "is_local"
        case isPlayable = "is_playable"
        case linkedFrom = "linked_from"
    }

    public let id: String?
    public let uri: String?
    public let name: String
    public let artists: [MusicArtist]?
    public let album: SpotifyAlbum?
    public let durationMS: Double
    public let isLocal: Bool?
    public let explicit: Bool?
    public let isPlayable: Bool?
    public let type: String?
    public let linkedFrom: LinkedTrack?

    public struct LinkedTrack: Decodable, Sendable {
        public let id: String
        public let uri: String?
    }

    public func model(album fallback: SpotifyAlbum? = nil) -> MusicTrack? {
        guard let id, let uri, uri.hasPrefix("spotify:track:"), isLocal != true,
            type == nil || type == "track", let album = album ?? fallback
        else { return nil }
        return MusicTrack(
            id: id, uri: uri, title: name, artists: artists ?? [],
            albumID: album.id, albumTitle: album.name, duration: durationMS / 1000,
            explicit: explicit, isPlayable: isPlayable)
    }
}

public struct SpotifySavedTrack: Decodable, Sendable { public let track: SpotifyTrack? }
public struct SpotifySavedAlbum: Decodable, Sendable { public let album: SpotifyAlbum }
public struct SpotifyFollowedArtists: Decodable, Sendable {
    public let artists: SpotifyPage<MusicArtist>
}

public struct SpotifyPlaylist: Decodable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, uri, name, owner, collaborative, `public`
        case snapshotID = "snapshot_id"
    }

    public let id: String
    public let uri: String
    public let name: String
    public let owner: Owner
    public let collaborative: Bool?
    public let `public`: Bool?
    public let snapshotID: String?
    public struct Owner: Decodable, Sendable { public let id: String }
    public func model(trackIDs: [String] = []) -> MusicPlaylist {
        MusicPlaylist(
            id: id, uri: uri, title: name, ownerID: owner.id,
            collaborative: collaborative ?? false, snapshotID: snapshotID ?? "", trackIDs: trackIDs
        )
    }
}

public struct SpotifyPlaylistItem: Decodable, Sendable {
    public let item: SpotifyTrack?
    // Read the pre-migration spelling only as a compatibility fallback.
    public let track: SpotifyTrack?
    public var value: SpotifyTrack? { item ?? track }
}

public struct SpotifySnapshot: Decodable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
    }
    public let snapshotID: String
}
public struct SpotifySearchResults: Decodable, Sendable {
    public let tracks: SpotifyPage<SpotifyTrack>?
    public let albums: SpotifyPage<SpotifyAlbum>?
    public let artists: SpotifyPage<MusicArtist>?
}

public struct SpotifyDevice: Decodable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, name, type
        case isActive = "is_active"
        case isRestricted = "is_restricted"
        case volumePercent = "volume_percent"
        case supportsVolume = "supports_volume"
    }

    public let id: String?
    public let name: String
    public let type: String
    public let isActive: Bool
    public let isRestricted: Bool
    public let volumePercent: Double?
    public let supportsVolume: Bool?
}
public struct SpotifyDevices: Decodable, Sendable { public let devices: [SpotifyDevice] }
public struct SpotifyPlayback: Decodable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case device, item, context, actions
        case isPlaying = "is_playing"
        case progressMS = "progress_ms"
        case shuffleState = "shuffle_state"
        case repeatState = "repeat_state"
    }

    public let device: SpotifyDevice
    public let isPlaying: Bool
    public let progressMS: Double?
    public let item: SpotifyTrack?
    public let shuffleState: Bool
    public let repeatState: String
    public let context: Context?
    public let actions: SpotifyActions?
    public struct Context: Decodable, Sendable { public let uri: String? }
}
