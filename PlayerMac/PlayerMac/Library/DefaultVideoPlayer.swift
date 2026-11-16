import AppKit
import Observation
import UniformTypeIdentifiers

/// System default-app lookups, separated so tests never change the Mac's real defaults.
@MainActor
protocol DefaultAppRegistry {
    func defaultApplication(for type: UTType) -> URL?
    func setDefaultApplication(_ application: URL, for type: UTType) async throws
}

struct WorkspaceDefaultAppRegistry: DefaultAppRegistry {
    func defaultApplication(for type: UTType) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: type)
    }

    func setDefaultApplication(_ application: URL, for type: UTType) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: application, toOpen: type)
    }
}

/// Figma 312:454. Makes Kinrox the system-wide default app for the v1 video types.
/// A system-wide default avoids per-file "Open with" bindings, which macOS refuses for
/// quarantined files ("Apple could not verify … is free of malware").
@MainActor
@Observable
final class DefaultVideoPlayer {
    struct Format: Equatable {
        let label: String
        let type: UTType
    }

    /// The document types listed for v1 in AGENTS.md 2.1. Labels are not translated.
    static let formats = makeFormats()

    static func makeFormats(
        resolve: (String) -> UTType? = { UTType(filenameExtension: $0, conformingTo: .movie) }
    ) -> [Format] {
        [
            ("MOV", "mov"), ("MP4", "mp4"), ("M4V", "m4v"), ("MKV", "mkv"), ("WebM", "webm"),
            ("AVI", "avi"), ("TS", "ts"),
        ].compactMap { label, fileExtension in
            var type = resolve(fileExtension)
            if type == nil || type?.isDynamic == true {
                // Match our imported declarations even before LaunchServices indexes them.
                switch fileExtension {
                case "mkv": type = UTType(importedAs: "org.matroska.mkv", conformingTo: .movie)
                case "webm": type = UTType(importedAs: "org.webmproject.webm", conformingTo: .movie)
                default: break
                }
            }
            return type.map { Format(label: label, type: $0) }
        }
    }

    /// Labels of formats that currently open in another app.
    private(set) var otherFormats: [String]
    private(set) var isChanging = false
    private(set) var failed = false

    var isDefault: Bool { otherFormats.isEmpty }

    private let registry: any DefaultAppRegistry
    private let application: URL
    private let bundleIdentifier: String?
    private let formats: [Format]

    init(
        registry: any DefaultAppRegistry = WorkspaceDefaultAppRegistry(),
        application: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        formats: [Format] = DefaultVideoPlayer.formats
    ) {
        self.registry = registry
        self.application = application
        self.bundleIdentifier = bundleIdentifier
        self.formats = formats
        otherFormats = formats.map(\.label)
        refresh()
    }

    func refresh() {
        otherFormats = pending().map(\.label)
        if isDefault { failed = false }
    }

    /// Changes only formats that open elsewhere. A cancelled system confirmation stops
    /// the remaining requests without reporting a failure.
    func makeDefault() async {
        guard !isChanging else { return }
        isChanging = true
        failed = false
        defer {
            refresh()
            isChanging = false
        }
        for format in pending() {
            do {
                try await registry.setDefaultApplication(application, for: format.type)
            } catch {
                if !Self.isCancellation(error) { failed = true }
                return
            }
        }
    }

    private func pending() -> [Format] {
        formats.filter { format in
            guard let bundleIdentifier,
                let handler = registry.defaultApplication(for: format.type)
            else { return true }
            // Compare identities, not paths: a development build is the same app.
            return Bundle(url: handler)?.bundleIdentifier != bundleIdentifier
        }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError {
                return true
            }
            if error.domain == NSOSStatusErrorDomain && error.code == Int(userCanceledErr) {
                return true
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
