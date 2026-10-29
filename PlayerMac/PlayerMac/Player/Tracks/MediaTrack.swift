import Foundation

enum MediaTrackKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case audio
    case subtitle = "sub"

    var id: String { rawValue }
    var label: String { self == .audio ? L10n.text("Audio") : L10n.text("Subtitles") }
    var property: String { self == .audio ? "aid" : "sid" }
}

/// A value copy of libmpv metadata. Track numbers are only valid for the current file.
struct MediaTrack: Equatable, Sendable, Identifiable {
    let number: Int64
    let kind: MediaTrackKind
    var title = ""
    var language = ""
    var codec = ""
    var channels = 0
    var isDefault = false
    var isForced = false
    var isSelected = false
    var externalURL: URL?

    var id: String { "\(kind.rawValue):\(number)" }
    var displayTitle: String {
        let languageName =
            language.isEmpty || language == "und"
            ? nil : Locale.current.localizedString(forLanguageCode: language) ?? language
        let name = title.isEmpty ? externalURL?.deletingPathExtension().lastPathComponent : title
        let parts = [languageName, name].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty
            ? L10n.format("Track %@", String(number)) : parts.joined(separator: " · ")
    }

    func detail(relativeTo root: URL?) -> String {
        var parts = [
            externalURL.map { TrackFile.relativePath($0, root: root) } ?? L10n.text("Embedded")
        ]
        if !codec.isEmpty { parts.append(codec.uppercased()) }
        if channels > 0 { parts.append(L10n.format("%@ channels", String(channels))) }
        if isForced { parts.append(L10n.text("Forced")) }
        if isDefault { parts.append(L10n.text("Default")) }
        return parts.joined(separator: " · ")
    }
}

struct TrackFile: Equatable, Sendable, Identifiable {
    let url: URL
    let kind: MediaTrackKind
    let relativePath: String
    let matchesVideo: Bool

    var id: String { url.path }
    var folder: String { (relativePath as NSString).deletingLastPathComponent }
    var title: String { url.deletingPathExtension().lastPathComponent }

    static func relativePath(_ url: URL, root: URL?) -> String {
        guard let root else { return url.lastPathComponent }
        let rootPath = VideoFiles.key(root)
        let prefix = rootPath == "/" ? rootPath : rootPath + "/"
        let path = VideoFiles.key(url)
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }
}
