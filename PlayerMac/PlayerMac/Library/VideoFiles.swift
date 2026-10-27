import Foundation
import UniformTypeIdentifiers

/// Video file identification for open dialog, drag and drop, and playlist.
enum VideoFiles {
    /// Unified local file key for playlist, recents, and UI highlighting.
    static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static let extensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mts", "mpg", "mpeg", "wmv",
        "flv", "ogv", "3gp",
    ]

    static var contentTypes: [UTType] {
        [.movie] + extensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }

    static func isVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        // System types like .mts without explicit extension in list also match.
        return UTType(filenameExtension: ext)?.conforms(to: .movie) ?? false
    }
}
