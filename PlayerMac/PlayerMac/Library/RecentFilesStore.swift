import Foundation
import Observation
import os

/// Recent file entry. Remote receives only id, title, and duration.
struct RecentItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var path: String
    var openedAt: Date
    var duration: Double?
    var bookmark: Data?
}

/// Up to 20 recent files in `~/Library/Application Support/Kinrox/recent.json`.
/// App Sandbox disabled in v1, bookmark without security scope.
@MainActor @Observable
final class RecentFilesStore {
    static let limit = 20

    private(set) var items: [RecentItem] = [] { didSet { notifyChanges() } }
    /// Entries whose files were not found during last check.
    private(set) var unavailable: Set<UUID> = [] { didSet { notifyChanges() } }
    @ObservationIgnored private var observers: [UUID: () -> Void] = [:]

    func observeChanges(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    private func notifyChanges() {
        for observer in Array(observers.values) { observer() }
    }
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let onOpened: (URL) -> Void
    @ObservationIgnored private let logger = Logger(
        subsystem: "app.kinrox.player", category: "recent")

    static var defaultURL: URL {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return support.appendingPathComponent("Kinrox/recent.json")
    }

    init(fileURL: URL = RecentFilesStore.defaultURL, onOpened: @escaping (URL) -> Void = { _ in }) {
        self.fileURL = fileURL
        self.onOpened = onOpened
        load()
        refreshAvailability()
    }

    func noteOpened(_ url: URL, at date: Date = Date()) {
        let path = VideoFiles.key(url)
        var item =
            items.first(where: { VideoFiles.key(URL(fileURLWithPath: $0.path)) == path })
            ?? RecentItem(
                id: UUID(), title: url.lastPathComponent, path: path, openedAt: date,
                duration: nil, bookmark: nil)
        item.title = url.lastPathComponent
        item.path = path
        item.openedAt = date
        item.bookmark = try? url.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        items.removeAll {
            $0.id == item.id || VideoFiles.key(URL(fileURLWithPath: $0.path)) == path
        }
        items.insert(item, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        unavailable.remove(item.id)
        save()
        onOpened(url)
    }

    func updateDuration(_ duration: Double, for url: URL) {
        let path = VideoFiles.key(url)
        guard duration.isFinite, duration > 0,
            let index = items.firstIndex(where: {
                VideoFiles.key(URL(fileURLWithPath: $0.path)) == path
            }),
            items[index].duration != duration
        else { return }
        items[index].duration = duration
        save()
    }

    /// Current file location: bookmark survives rename and move within volume.
    func resolve(_ item: RecentItem) -> URL? {
        if let data = item.bookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil,
                bookmarkDataIsStale: &stale),
                FileManager.default.fileExists(atPath: url.path)
            {
                if stale || VideoFiles.key(url) != item.path { refresh(item.id, to: url) }
                return url
            }
        }
        let url = URL(fileURLWithPath: item.path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func refreshAvailability() {
        let updated = Set(items.filter { resolve($0) == nil }.map(\.id))
        if unavailable != updated { unavailable = updated }
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        unavailable.remove(id)
        save()
    }

    func clear() {
        items = []
        unavailable = []
        save()
    }

    private func refresh(_ id: UUID, to url: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].path = VideoFiles.key(url)
        items[index].title = url.lastPathComponent
        items[index].bookmark = try? url.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            items = Array(try decoder.decode([RecentItem].self, from: data).prefix(Self.limit))
        } catch {
            // Corrupted file does not block startup: list restarts cleanly.
            logger.error("Failed to read recents: \(error.localizedDescription)")
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(items).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save recents: \(error.localizedDescription)")
        }
    }
}
