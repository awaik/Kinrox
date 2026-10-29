import Foundation

/// Conservative episode matching. Discovery never drops an unmatched file.
enum TrackFileMatcher {
    static func matches(_ file: URL, video: URL) -> Bool {
        let lhs = stem(file)
        let rhs = stem(video)
        if let a = season(file), let b = season(video), a != b { return false }
        if lhs == rhs || lhs.hasPrefix(rhs + " ") { return true }
        guard let a = episode(lhs), let b = episode(rhs), a.number == b.number else { return false }
        if let x = a.season, let y = b.season, x != y { return false }
        // Short filenames such as 01.ass are meaningful within the selected series folder.
        return a.prefix.isEmpty || b.prefix.isEmpty || a.prefix == b.prefix
    }

    static func stem(_ url: URL) -> String {
        normalized(url.deletingPathExtension().lastPathComponent)
    }

    static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"[._\-\s]+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Episode {
        let number: Int
        let season: Int?
        let prefix: String
        let range: Range<String.Index>
    }

    /// Retains language/release labels while ignoring the changing episode number.
    static func preferenceSignature(_ url: URL) -> String {
        signature(url.deletingPathExtension().lastPathComponent, allowingBareNumber: true)
    }

    static func titleSignature(_ value: String) -> String {
        // Metadata numbers may identify studios or channel layouts, not episodes.
        signature(value, allowingBareNumber: false)
    }

    private static func signature(_ value: String, allowingBareNumber: Bool) -> String {
        let name = normalized(
            value.replacingOccurrences(of: "[", with: " ").replacingOccurrences(of: "]", with: " "))
        guard let episode = episode(name, allowingBareNumber: allowingBareNumber) else {
            return name
        }
        return normalized(name.replacingCharacters(in: episode.range, with: " {episode} "))
    }

    static func episode(_ name: String, allowingBareNumber: Bool = true) -> Episode? {
        let patterns = [
            #"(?i)\bs(\d{1,2})\s*e(\d{1,3})\b"#,
            #"(?i)\b(\d{1,2})x(\d{1,3})\b"#,
            #"(?i)\b(?:episode|ep|e)\s*(\d{1,3})\b"#,
            #"(?:^|\s)(\d{1,3})(?=\s|$)"#,
        ]
        for (index, pattern) in patterns.enumerated() {
            if index == 3, !allowingBareNumber { continue }
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(
                    in: name, range: NSRange(name.startIndex..., in: name)),
                let range = Range(match.range(at: index < 2 ? 2 : 1), in: name),
                let number = Int(name[range]), number > 0,
                let full = Range(match.range, in: name)
            else { continue }
            let season =
                index < 2
                ? Range(match.range(at: 1), in: name).flatMap { Int(name[$0]) } : nil
            return Episode(
                number: number, season: season,
                prefix: String(name[..<full.lowerBound]).trimmingCharacters(in: .whitespaces),
                range: full)
        }
        return nil
    }

    private static func season(_ url: URL) -> Int? {
        if let value = episode(stem(url))?.season { return value }
        for part in url.deletingLastPathComponent().pathComponents.reversed() {
            let name = normalized(part)
            guard
                let regex = try? NSRegularExpression(pattern: #"^(?:season|s|сезон)\s*(\d{1,2})$"#),
                let match = regex.firstMatch(
                    in: name, range: NSRange(name.startIndex..., in: name)),
                let range = Range(match.range(at: 1), in: name)
            else { continue }
            return Int(name[range])
        }
        return nil
    }
}
