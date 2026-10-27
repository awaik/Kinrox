import Foundation

/// Playlist of folder video files sorted naturally like Finder ("2" before "10").
/// Owner decision.
struct FolderPlaylist: Equatable, Sendable {
    let items: [URL]
    let index: Int

    var current: URL { items[index] }
    var count: Int { items.count }
    var hasNext: Bool { index + 1 < items.count }
    var hasPrevious: Bool { index > 0 }
    var next: URL? { hasNext ? items[index + 1] : nil }
    var previous: URL? { hasPrevious ? items[index - 1] : nil }
    var folderName: String { current.deletingLastPathComponent().lastPathComponent }

    init(items: [URL], current: URL) {
        let key = VideoFiles.key(current)
        if let found = items.firstIndex(where: { VideoFiles.key($0) == key }) {
            self.items = items
            index = found
        } else {
            // File with non-standard extension still remains current.
            var all = items + [current]
            all.sort(by: Self.finderOrder)
            self.items = all
            index = all.firstIndex(where: { VideoFiles.key($0) == key }) ?? 0
        }
    }

    /// Reads folder synchronously: invoke off main thread.
    static func scan(for url: URL) -> FolderPlaylist {
        let folder = url.deletingLastPathComponent()
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let videos = contents.filter { item in
            let regular = (try? item.resourceValues(forKeys: Set(keys)).isRegularFile) ?? false
            return regular && VideoFiles.isVideo(item)
        }
        return FolderPlaylist(items: videos.sorted(by: finderOrder), current: url)
    }

    static func finderOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    func index(of url: URL) -> Int? {
        let key = VideoFiles.key(url)
        return items.firstIndex { VideoFiles.key($0) == key }
    }
}
