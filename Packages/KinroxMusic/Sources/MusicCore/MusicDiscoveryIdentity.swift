import Foundation

public enum MusicDiscoveryIdentity {
    public static func normalized(_ value: String) -> String {
        value.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    public static func baseTitle(_ title: String) -> String {
        var value = title
        for pattern in [
            #"\[[^\]]*\]"#,
            #"(?i)\([^)]*\b(remix|edit|mix|version|remaster(?:ed)?|live|instrumental|feat\.?|ft\.?|with)\b[^)]*\)"#,
            #"(?i)\s+[-–—]\s+.*\b(remix|edit|mix|version|remaster(?:ed)?|live|instrumental)\b.*$"#,
        ] {
            value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return normalized(value)
    }

    public static func key(_ track: MusicTrack) -> String {
        normalized(track.artists.first?.name ?? "") + "|" + baseTitle(track.title)
    }

    public static func keys(_ track: MusicTrack) -> Set<String> {
        var keys: Set<String> = ["title:" + key(track)]
        for artist in track.artists {
            keys.insert("title:" + normalized(artist.name) + "|" + baseTitle(track.title))
        }
        if let isrc = isrc(track) { keys.insert("isrc:" + isrc) }
        return keys
    }

    public static func isrc(_ track: MusicTrack) -> String? {
        guard let value = track.isrc?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        return value.uppercased()
    }

    public static func sharesArtist(_ lhs: MusicTrack, _ rhs: MusicTrack) -> Bool {
        !Set(lhs.artists.map(\.id)).isDisjoint(with: rhs.artists.map(\.id))
            || !Set(lhs.artists.map { normalized($0.name) }).isDisjoint(
                with: rhs.artists.map { normalized($0.name) })
    }

    public static func sameRecording(_ lhs: MusicTrack, _ rhs: MusicTrack) -> Bool {
        Recording(lhs).isSame(as: Recording(rhs))
    }

    /// A track's recording keys, computed once: `baseTitle` runs three regular expressions,
    /// so comparing many pairs must not recompute them for every pair.
    public struct Recording: Sendable {
        let id: String
        let isrc: String?
        let key: String
        let baseTitle: String
        let artistIDs: Set<String>
        let artistNames: Set<String>

        public init(_ track: MusicTrack) {
            id = track.id
            isrc = MusicDiscoveryIdentity.isrc(track)
            baseTitle = MusicDiscoveryIdentity.baseTitle(track.title)
            artistNames = Set(track.artists.map { MusicDiscoveryIdentity.normalized($0.name) })
            artistIDs = Set(track.artists.map(\.id))
            key =
                MusicDiscoveryIdentity.normalized(track.artists.first?.name ?? "") + "|" + baseTitle
        }

        public func isSame(as other: Recording) -> Bool {
            id == other.id || (isrc != nil && isrc == other.isrc) || key == other.key
                || (baseTitle == other.baseTitle
                    && (!artistIDs.isDisjoint(with: other.artistIDs)
                        || !artistNames.isDisjoint(with: other.artistNames)))
        }
    }

    public static func isVariousArtists(_ artist: MusicArtist) -> Bool {
        artist.id == "0LyfQWJT6nXafLPZqxe9Of" || normalized(artist.name) == "various artists"
    }

    public static func remixers(in title: String) -> [String] {
        let pattern = #"(?i)(?:\(|\[|\s[-–—]\s)([^()\[\]]+?)\s+(?:remix|edit|mix)(?:\)|\]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = title as NSString
        return regex.matches(in: title, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { candidate in
            let qualifiers: Set<String> = [
                "original", "radio", "extended", "club", "dub", "vocal", "instrumental",
                "acoustic", "album", "single", "continuous", "dj", "vip", "short", "main",
                "festival", "live", "remaster", "remastered", "version", "mix", "edit", "remix",
            ]
            return normalized(candidate).split(separator: " ").contains {
                !qualifiers.contains(String($0)) && Int($0) == nil
            }
        }
    }

    public static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) {
            ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3
        }
    }
}
