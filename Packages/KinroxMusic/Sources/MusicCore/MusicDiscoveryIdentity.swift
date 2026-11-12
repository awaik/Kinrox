import Foundation

public enum MusicDiscoveryIdentity {
    private static let titlePatterns = [
        #"\[[^\]]*\]"#,
        #"(?i)\([^)]*\b(remix|edit|mix|version|remaster(?:ed)?|live|instrumental|feat\.?|ft\.?|with)\b[^)]*\)"#,
        #"(?i)\s+[-–—]\s+.*\b(remix|edit|mix|version|remaster(?:ed)?|live|instrumental)\b.*$"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    private static let remixerPattern = try! NSRegularExpression(
        pattern: #"(?i)(?:\(|\[|\s[-–—]\s)([^()\[\]]+?)\s+(?:remix|edit|mix)(?:\)|\]|$)"#)
    private static let qualifiers: Set<String> = [
        "original", "radio", "extended", "club", "dub", "vocal", "instrumental",
        "acoustic", "album", "single", "continuous", "dj", "vip", "short", "main",
        "festival", "live", "remaster", "remastered", "version", "mix", "edit", "remix",
    ]

    public static func normalized(_ value: String) -> String {
        // ASCII needs neither Foundation folding nor Unicode classification.
        if value.utf8.allSatisfy({ $0 < 128 }) {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(value.utf8.count)
            var separator = false
            for byte in value.utf8 {
                let folded = byte >= 65 && byte <= 90 ? byte + 32 : byte
                if (folded >= 97 && folded <= 122) || (folded >= 48 && folded <= 57) {
                    if separator && !bytes.isEmpty { bytes.append(32) }
                    bytes.append(folded)
                    separator = false
                } else {
                    separator = true
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        let folded = value.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        var result = String.UnicodeScalarView()
        var separator = false
        for scalar in folded.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter,
                .otherLetter, .nonspacingMark, .spacingMark, .enclosingMark,
                .decimalNumber, .letterNumber, .otherNumber:
                if separator && !result.isEmpty { result.append(" ") }
                result.append(scalar)
                separator = false
            default: separator = true
            }
        }
        return String(result)
    }

    public static func baseTitle(_ title: String) -> String {
        normalized(strippingTitleQualifiers(title))
    }

    /// No qualifier expression can start before this boundary. Keep preceding whitespace
    /// because the dash expression requires it; the prefix remains byte-for-byte unchanged.
    static func qualifierStart(in title: String) -> String.Index? {
        let scalars = title.unicodeScalars
        guard
            var start = scalars.firstIndex(where: {
                switch $0.value {
                case 40, 91, 45, 0x2013, 0x2014: true
                default: false
                }
            })
        else { return nil }
        while start > scalars.startIndex {
            let previous = scalars.index(before: start)
            guard scalars[previous].properties.isWhitespace else { break }
            start = previous
        }
        return start
    }

    static func strippingTitleQualifiers(_ title: String) -> String {
        guard title.utf8.contains(where: { $0 == 40 || $0 == 91 || $0 == 45 || $0 == 226 }) else {
            return title
        }
        var value = title
        for (index, pattern) in titlePatterns.enumerated() {
            let applies: Bool
            switch index {
            case 0: applies = value.utf8.contains(91)
            case 1: applies = value.utf8.contains(40)
            default: applies = value.utf8.contains { $0 == 45 || $0 == 226 }
            }
            if applies {
                value = pattern.stringByReplacingMatches(
                    in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
            }
        }
        return value
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
        lhs.id == rhs.id || (isrc(lhs) != nil && isrc(lhs) == isrc(rhs))
            || key(lhs) == key(rhs)
            || (baseTitle(lhs.title) == baseTitle(rhs.title) && sharesArtist(lhs, rhs))
    }

    public static func isVariousArtists(_ artist: MusicArtist) -> Bool {
        artist.id == "0LyfQWJT6nXafLPZqxe9Of" || normalized(artist.name) == "various artists"
    }

    public static func remixers(in title: String) -> [String] {
        let lower = title.lowercased()
        guard lower.contains("mix") || lower.contains("edit")
        else { return [] }
        return remixerPattern.matches(in: title, range: NSRange(title.startIndex..., in: title))
            .compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: title) else { return nil }
                return String(title[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { candidate in
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
