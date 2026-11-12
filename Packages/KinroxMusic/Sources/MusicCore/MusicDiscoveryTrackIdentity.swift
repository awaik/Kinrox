import Foundation

/// One pass owns this cache; no track metadata survives a ranking operation.
struct DiscoveryIdentityIndex {
    private struct Entry {
        let title: String
        let artists: [MusicArtist]
        let isrc: String?
        let identity: TrackIdentity
    }
    private var tracks: [String: Entry] = [:]
    private var names: [String: String] = [:]
    private var strippedSuffixes: [String: String] = [:]

    mutating func normalized(_ name: String) -> String {
        if let cached = names[name] { return cached }
        let value = MusicDiscoveryIdentity.normalized(name)
        names[name] = value
        return value
    }

    mutating func identity(_ track: MusicTrack) -> TrackIdentity {
        // Album tracks and hydrated tracks can share an ID but carry different identity data.
        if let cached = tracks[track.id], cached.title == track.title,
            cached.artists == track.artists, cached.isrc == track.isrc
        {
            return cached.identity
        }
        let title: String
        if let start = MusicDiscoveryIdentity.qualifierStart(in: track.title) {
            let suffix = String(track.title[start...])
            let stripped =
                strippedSuffixes[suffix]
                ?? MusicDiscoveryIdentity.strippingTitleQualifiers(suffix)
            strippedSuffixes[suffix] = stripped
            title = MusicDiscoveryIdentity.normalized(String(track.title[..<start]) + stripped)
        } else {
            title = MusicDiscoveryIdentity.normalized(track.title)
        }
        let value = TrackIdentity(
            track, artistNames: track.artists.map { normalized($0.name) }, baseTitle: title)
        tracks[track.id] = Entry(
            title: track.title, artists: track.artists, isrc: track.isrc, identity: value)
        return value
    }
}

struct TrackIdentity: Sendable {
    let id: String
    let isrc: String?
    let baseTitle: String
    let key: String
    let primaryArtistKey: String
    let artistIDs: [String]
    let artistNormNames: [String]
    let isVarious: Bool
    let stableHash: UInt64
    let recordingTokens: [DiscoveryRecordingToken]

    init(_ track: MusicTrack, artistNames: [String]? = nil, baseTitle: String? = nil) {
        id = track.id
        isrc = MusicDiscoveryIdentity.isrc(track)
        self.baseTitle = baseTitle ?? MusicDiscoveryIdentity.baseTitle(track.title)
        // Empty credits intentionally retain the established sameRecording/sharesArtist semantics.
        artistIDs = track.artists.map(\.id)
        artistNormNames =
            artistNames ?? track.artists.map { MusicDiscoveryIdentity.normalized($0.name) }
        primaryArtistKey = artistNormNames.first ?? MusicDiscoveryIdentity.normalized(track.id)
        key = (artistNormNames.first ?? "") + "|" + self.baseTitle
        isVarious =
            track.artists.first?.id == "0LyfQWJT6nXafLPZqxe9Of"
            || artistNormNames.first == "various artists"
        stableHash = MusicDiscoveryIdentity.stableHash(track.id)
        var tokens: [DiscoveryRecordingToken] = [.id(id), .key(key)]
        if let isrc { tokens.append(.isrc(isrc)) }
        let title = self.baseTitle
        tokens += artistIDs.map { .artistID($0, title) }
        tokens += artistNormNames.map { .artistName($0, title) }
        recordingTokens = tokens
    }

    func sharesArtist(ids: Set<String>, names: Set<String>) -> Bool {
        artistIDs.contains(where: ids.contains) || artistNormNames.contains(where: names.contains)
    }
}

/// Namespace and components preserve token equality without allocating concatenated
/// artist/title strings for every credit. These values never leave a ranking pass.
enum DiscoveryRecordingToken: Hashable, Sendable {
    case id(String)
    case isrc(String)
    case key(String)
    case artistID(String, String)
    case artistName(String, String)
}
