import Foundation

struct TrackPreference: Codable, Equatable {
    var disabled = false
    var language = ""
    var title = ""
    var externalFolder: String?
    var fileExtension: String?
    var externalName: String?

    init(track: MediaTrack) {
        language = track.language.lowercased()
        title = TrackFileMatcher.titleSignature(track.title)
        externalFolder =
            track.externalURL?.standardizedFileURL.resolvingSymlinksInPath()
            .deletingLastPathComponent().path
        fileExtension = track.externalURL?.pathExtension.lowercased()
        externalName = track.externalURL.map(TrackFileMatcher.preferenceSignature)
        if let url = track.externalURL,
            [url.lastPathComponent, url.deletingPathExtension().lastPathComponent].contains(
                track.title)
        {
            title = ""
        }
    }

    init(disabled: Bool) { self.disabled = disabled }

    func matches(_ track: MediaTrack) -> Bool {
        guard !disabled else { return false }
        if let externalFolder {
            return track.externalURL.map { VideoFiles.key($0.deletingLastPathComponent()) }
                == VideoFiles.key(URL(fileURLWithPath: externalFolder))
                && track.externalURL?.pathExtension.lowercased() == fileExtension
                && (language.isEmpty || track.language.lowercased() == language)
                && (title.isEmpty || TrackFileMatcher.titleSignature(track.title) == title)
        }
        return track.externalURL == nil && track.language.lowercased() == language
            && TrackFileMatcher.titleSignature(track.title) == title
    }

    func matches(_ file: TrackFile) -> Bool {
        guard let externalFolder else { return false }
        return file.matchesVideo
            && VideoFiles.key(file.url.deletingLastPathComponent())
                == VideoFiles.key(URL(fileURLWithPath: externalFolder))
            && file.url.pathExtension.lowercased() == fileExtension
            && (externalName == nil
                || TrackFileMatcher.preferenceSignature(file.url) == externalName)
    }
}

struct TrackFolderSettings: Codable, Equatable {
    var root: URL
    var recursive = true
    var remember = true
    var audio: TrackPreference?
    var subtitle: TrackPreference?

    subscript(kind: MediaTrackKind) -> TrackPreference? {
        get { kind == .audio ? audio : subtitle }
        set { if kind == .audio { audio = newValue } else { subtitle = newValue } }
    }
}

@MainActor
final class TrackPreferences {
    private let defaults: UserDefaults
    private let key = "app.kinrox.player.track-preferences"
    private var folders: [String: TrackFolderSettings]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folders =
            defaults.data(forKey: key).flatMap {
                try? JSONDecoder().decode([String: TrackFolderSettings].self, from: $0)
            } ?? [:]
    }

    func settings(for video: URL) -> TrackFolderSettings {
        let folder = video.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        // Keep preferences written through a symlink by earlier versions readable.
        var settings =
            folders[folder.path]
            ?? folders[video.deletingLastPathComponent().standardizedFileURL.path]
            ?? TrackFolderSettings(root: folder)
        settings.root = settings.root.standardizedFileURL.resolvingSymlinksInPath()
        return settings
    }

    func save(_ settings: TrackFolderSettings, for video: URL) {
        var settings = settings
        settings.root = settings.root.standardizedFileURL.resolvingSymlinksInPath()
        let folder = video.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        folders[folder.path] = settings
        if let data = try? JSONEncoder().encode(folders) { defaults.set(data, forKey: key) }
    }
}
