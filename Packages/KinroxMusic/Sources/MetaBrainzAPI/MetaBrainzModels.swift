import Foundation

public struct MetaBrainzArtist: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
}

public struct MetaBrainzResolution: Codable, Equatable, Sendable {
    public var recordingMBID: String?
    public var artists: [MetaBrainzArtist]
    public var genres: [String]
}

public struct MetaBrainzSimilarArtist: Codable, Sendable {
    public let artistMBID: String
    public let name: String
    public let score: Double
    enum CodingKeys: String, CodingKey {
        case artistMBID = "artist_mbid"
        case name = "name"
        case score
    }
}

public struct MetaBrainzRecording: Codable, Sendable {
    public let recordingMBID: String
    public let recordingName: String
    public let artistCreditName: String
    public let score: Double?
    enum CodingKeys: String, CodingKey {
        case recordingMBID = "recording_mbid"
        case recordingName = "recording_name"
        case artistCreditName = "artist_credit_name"
        case score
    }
}

public struct MetaBrainzSpotifyMapping: Codable, Sendable {
    public let recordingMBID: String
    public let spotifyTrackIDs: [String]
    enum CodingKeys: String, CodingKey {
        case recordingMBID = "recording_mbid"
        case spotifyTrackIDs = "spotify_track_ids"
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        recordingMBID = try values.decode(String.self, forKey: .recordingMBID)
        spotifyTrackIDs = try values.decodeIfPresent([String].self, forKey: .spotifyTrackIDs) ?? []
    }
}

struct MusicBrainzISRC: Decodable {
    let recordings: [Recording]
    struct Recording: Decodable {
        let id: String
        let credits: [Credit]
        enum CodingKeys: String, CodingKey {
            case id
            case credits = "artist-credit"
        }
    }
    struct Credit: Decodable { let artist: MetaBrainzArtist }
}
struct MusicBrainzArtists: Decodable { let artists: [MetaBrainzArtist] }
struct MusicBrainzGenres: Decodable {
    let genres: [Genre]?
    struct Genre: Decodable {
        let name: String
        let count: Int
    }
}

/// Only public metadata, scoped to the Mac account cache by the application adapter.
public protocol MetaBrainzCache: Sendable {
    func readMetaBrainz(_ key: String) async throws -> Data?
    func writeMetaBrainz(_ key: String, data: Data, ttl: TimeInterval) async throws
}
