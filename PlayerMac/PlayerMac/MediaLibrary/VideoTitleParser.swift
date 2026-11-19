import Foundation

enum VideoTitleParser {
    static func parse(_ url: URL, root: URL? = nil) -> VideoTitle {
        let episodePattern =
            /(?i)(?:s(\d{1,2})[ ._-]*e(\d{1,3})((?:[ ._-]*e\d{1,3})*)|(\d{1,2})x(\d{1,3}))/
        let seasonFolder = /(?i)^season[ ._-]*(\d{1,2})$/
        let shortEpisode = /(?i)^(?:episode|e)[ ._-]*(\d{1,3})(?:[ ._-]|$)/
        let yearPattern = /(?:^|[ ._(-])((?:19|20)\d{2})(?=[ ._)\-]|$)/
        let personalPattern = /(?i)^(?:IMG_|DSC_|MVI_|Screen[ ._-]Recording)/
        let name = url.deletingPathExtension().lastPathComponent
        var result = VideoTitle(title: clean(name))
        result.isPersonal = name.prefixMatch(of: personalPattern) != nil
        let folder = url.deletingLastPathComponent()
        let seasonMatch = folder.lastPathComponent.wholeMatch(of: seasonFolder)
        let seriesFolder = seasonMatch == nil ? folder : folder.deletingLastPathComponent()
        if let match = name.firstMatch(of: episodePattern) {
            result.season = (match.1 ?? match.4).flatMap { Int($0) }
            result.episodes = [match.2 ?? match.5].compactMap { $0.flatMap { Int($0) } }
            if let extra = match.3 {
                result.episodes.append(
                    contentsOf: extra.matches(of: /(?i)e(\d{1,3})/).compactMap { Int($0.1) })
            }
            let prefix = clean(String(name[..<match.range.lowerBound]))
            result.title =
                prefix.isEmpty && (seasonMatch != nil || root != seriesFolder)
                ? clean(seriesFolder.lastPathComponent) : prefix
            let suffix = String(name[match.range.upperBound...])
            result.episodeTitle = titleWithoutRelease(suffix).nilIfEmpty
        } else if let seasonMatch, let episode = name.prefixMatch(of: shortEpisode) {
            result.season = Int(seasonMatch.1)
            result.episodes = [Int(episode.1)].compactMap { $0 }
            result.title = clean(seriesFolder.lastPathComponent)
            result.episodeTitle =
                titleWithoutRelease(String(name[episode.range.upperBound...])).nilIfEmpty
        } else {
            result.title = titleWithoutRelease(name)
        }
        if result.title.isEmpty { result.title = clean(name) }
        let yearSource = result.season == nil ? name : result.title
        if let year = yearSource.matches(of: yearPattern).last(where: { match in
            match.range.lowerBound != yearSource.startIndex
                && !clean(String(yearSource[..<match.range.lowerBound])).isEmpty
        }), let number = Int(year.1) {
            let rawPrefix = String(yearSource[..<year.range.lowerBound])
            let prefix = result.season == nil ? titleWithoutRelease(rawPrefix) : clean(rawPrefix)
            if !prefix.isEmpty {
                result.year = number
                result.title = prefix
            }
        }
        let tags = " " + name.lowercased() + " "
        let words = Set(
            tags.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if !words.isDisjoint(with: ["2160p", "4k"]) {
            result.resolution = "4K"
        } else {
            result.resolution = ["1080p", "720p", "480p"].first(where: words.contains)
        }
        if words.contains("dv") || Self.clean(tags).contains("dolby vision") {
            result.hdr = "Dolby Vision"
        } else if !words.isDisjoint(with: ["hdr", "hdr10"]) {
            result.hdr = "HDR"
        }
        if words.contains("av1") {
            result.codec = "AV1"
        } else if !words.isDisjoint(with: ["hevc", "x265", "h265"]) {
            result.codec = "HEVC"
        } else if !words.isDisjoint(with: ["x264", "h264"]) {
            result.codec = "H.264"
        }
        return result
    }

    private static func titleWithoutRelease(_ name: String) -> String {
        let releasePattern =
            /(?i)(?:^|[ ._-])(?:2160p|4k|1080p|720p|480p|hdr10\+?|hdr|dv|dolby[ ._-]*vision|hevc|x265|h265|x264|h264|av1|bluray|webrip|web[ ._-]*dl|bdrip|remux)(?=[ ._\-]|$)/
        if let match = name.firstMatch(of: releasePattern) {
            return clean(String(name[..<match.range.lowerBound]))
        }
        return clean(name)
    }

    private static func clean(_ name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace || "._-()[]".contains($0) }).joined(
            separator: " ")
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
