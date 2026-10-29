import Foundation
import Testing

@testable import Kinrox

/// Temporary directory removed at test end.
private struct TempFolder {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kinrox-tests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ name: String) throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data("x".utf8).write(to: file)
        return file
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

@Suite("Folder playlist")
struct FolderPlaylistTests {
    @Test("A video published after opening updates navigation without playback commands")
    @MainActor
    func discoversPublishedEpisode() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let first = try folder.file("Episode 1.mkv")
        let engine = FakePlayerEngine()
        let recents = RecentFilesStore(fileURL: folder.url.appendingPathComponent("recent.json")) {
            _ in
        }
        let model = PlayerViewModel(engine: engine, recents: recents)
        model.open(url: first)
        model.receive(.started)
        model.receive(.loaded)
        model.receive(.property(.position, .number(42)))
        model.receive(.property(.paused, .flag(true)))
        for _ in 0..<200 where model.playlist == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.playlist?.count == 1)
        #expect(!model.canNext)
        let commands = engine.commands
        let recentItems = recents.items
        let second = try folder.file("Episode 2.mkv")
        for _ in 0..<200 where !model.canNext {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.canNext)
        #expect(model.playlist?.next.map(VideoFiles.key) == VideoFiles.key(second))
        #expect(model.playlistCaption == "1 of 2 · \(folder.url.lastPathComponent)")
        #expect(model.currentURL == first && model.position == 42 && model.paused)
        #expect(engine.commands == commands)
        #expect(recents.items == recentItems)
        await model.shutdown()
    }

    @Test("Symlink transition preserves prepared playlist without rescan")
    @MainActor
    func symlinkPlaylistSwitch() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let first = try folder.file("1.mkv")
        let second = try folder.file("2.mkv")
        let alias = folder.url.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder.url)
        let linked = alias.appendingPathComponent("2.mkv")
        let model = PlayerViewModel(engine: FakePlayerEngine()) { url in
            FolderPlaylist(items: [first, second], current: url)
        }
        model.open(url: first)
        try await waitForFolder { model.playlist != nil }
        #expect(model.playlist?.index == 0)
        model.open(url: linked)
        #expect(model.playlist?.index == 1)
        #expect(model.canPrevious && !model.canNext)
        await model.shutdown()
    }

    @Test("Only videos, natural Finder naming, hidden files skipped")
    func scanFiltersAndSorts() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        for name in [
            "Episode 10.mkv", "Episode 2.mp4", "Episode 1.MKV", "notes.txt", ".hidden.mkv",
        ] {
            try folder.file(name)
        }
        try FileManager.default.createDirectory(
            at: folder.url.appendingPathComponent("Folder.mkv"), withIntermediateDirectories: true)
        let current = folder.url.appendingPathComponent("Episode 2.mp4")
        let playlist = FolderPlaylist.scan(for: current)
        #expect(
            playlist.items.map(\.lastPathComponent) == [
                "Episode 1.MKV", "Episode 2.mp4", "Episode 10.mkv",
            ])
        #expect(playlist.index == 1)
        #expect(playlist.previous?.lastPathComponent == "Episode 1.MKV")
        #expect(playlist.next?.lastPathComponent == "Episode 10.mkv")
    }

    @Test("File with unknown extension remains current, playlist edges")
    func unknownExtension() {
        let folder = URL(fileURLWithPath: "/tmp/f")
        let items = ["a.mkv", "c.mkv"].map { folder.appendingPathComponent($0) }
        let playlist = FolderPlaylist(items: items, current: folder.appendingPathComponent("b.xyz"))
        #expect(playlist.items.map(\.lastPathComponent) == ["a.mkv", "b.xyz", "c.mkv"])
        #expect(playlist.index == 1)
        let first = FolderPlaylist(items: items, current: items[0])
        #expect(!first.hasPrevious && first.hasNext)
        #expect(first.folderName == "f")
    }
}

@Suite("Recent files")
@MainActor
struct RecentFilesStoreTests {
    @Test("Opening via symlink and bookmark preserves single entry and duration")
    func symlinkIdentity() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let file = try folder.file("Movie.mkv")
        let alias = folder.url.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder.url)
        let linkedFile = alias.appendingPathComponent("Movie.mkv")
        let store = RecentFilesStore(fileURL: folder.url.appendingPathComponent("recent.json"))
        store.noteOpened(linkedFile)
        let id = try #require(store.items.first?.id)
        store.refreshAvailability()
        store.noteOpened(file)
        store.noteOpened(linkedFile)
        store.updateDuration(42, for: file)
        #expect(store.items.count == 1)
        #expect(store.items.first?.id == id)
        #expect(store.items.first?.duration == 42)
    }

    @Test("Failed load does not record recents and clears current URL")
    func recentsWaitForLoad() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let file = try folder.file("Movie.mkv")
        var systemRecents: [URL] = []
        let store = RecentFilesStore(fileURL: folder.url.appendingPathComponent("recent.json")) {
            systemRecents.append($0)
        }
        let model = PlayerViewModel(engine: FakePlayerEngine(), recents: store)
        model.open(url: file)
        #expect(store.items.isEmpty)
        #expect(systemRecents.isEmpty)
        model.receive(.started)
        model.receive(.ended(error: "Corrupted file"))
        #expect(store.items.isEmpty)
        #expect(model.currentURL == nil)
        #expect(systemRecents.isEmpty)
        model.open(url: file)
        model.receive(.started)
        model.receive(.property(.duration, .number(42)))
        model.receive(.loaded)
        #expect(store.items.count == 1)
        #expect(store.items.first?.duration == 42)
        #expect(systemRecents == [file])
        await model.shutdown()
    }

    @Test("Neighbor files and auto-advance update both lists after load")
    func playlistUpdatesSystemRecents() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let files = try (1...3).map { try folder.file("\($0).mkv") }
        var systemRecents: [URL] = []
        let store = RecentFilesStore(fileURL: folder.url.appendingPathComponent("recent.json")) {
            systemRecents.append($0)
        }
        let model = PlayerViewModel(engine: FakePlayerEngine(), recents: store) { url in
            FolderPlaylist(items: files, current: url)
        }
        func finishLoad() {
            model.receive(.ended(error: nil))
            model.receive(.started)
            model.receive(.loaded)
        }
        model.open(url: files[0])
        finishLoad()
        try await waitForFolder { model.playlist != nil }
        model.next()
        #expect(systemRecents == [files[0]])
        finishLoad()
        model.previous()
        finishLoad()
        model.receive(.property(.endReached, .flag(true)))
        finishLoad()
        #expect(systemRecents == [files[0], files[1], files[0], files[1]])
        #expect(store.items.map(\.path) == [VideoFiles.key(files[1]), VideoFiles.key(files[0])])
        await model.shutdown()
    }

    @Test("Newest on top, no duplicates, max 20, survive restart")
    func orderingLimitAndPersistence() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let storeURL = folder.url.appendingPathComponent("recent.json")
        let store = RecentFilesStore(fileURL: storeURL)
        let files = try (0..<22).map { try folder.file("Movie \($0).mkv") }
        for (index, file) in files.enumerated() {
            store.noteOpened(file, at: Date(timeIntervalSince1970: Double(index)))
        }
        store.noteOpened(files[5], at: Date(timeIntervalSince1970: 100))
        #expect(store.items.count == RecentFilesStore.limit)
        #expect(store.items.first?.title == "Movie 5.mkv")
        #expect(Set(store.items.map(\.path)).count == store.items.count)
        store.updateDuration(5400, for: files[5])
        let reloaded = RecentFilesStore(fileURL: storeURL)
        #expect(reloaded.items == store.items)
        #expect(reloaded.items.first?.duration == 5400)
    }

    @Test("Bookmark finds renamed file; deleted is marked unavailable")
    func bookmarkAndAvailability() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let store = RecentFilesStore(fileURL: folder.url.appendingPathComponent("recent.json"))
        let moved = try folder.file("Old Name.mkv")
        let deleted = try folder.file("Deleted.mkv")
        store.noteOpened(moved)
        store.noteOpened(deleted)
        let originalItem = try #require(store.items.first { $0.title == "Old Name.mkv" })
        let renamed = folder.url.appendingPathComponent("New Name.mkv")
        try FileManager.default.moveItem(at: moved, to: renamed)
        try FileManager.default.removeItem(at: deleted)
        #expect(store.resolve(originalItem)?.lastPathComponent == "New Name.mkv")
        store.refreshAvailability()
        let movedItem = try #require(store.items.first { $0.title.contains("Name") })
        #expect(store.resolve(movedItem)?.lastPathComponent == "New Name.mkv")
        let deletedItem = try #require(store.items.first { $0.title == "Deleted.mkv" })
        #expect(store.unavailable == [deletedItem.id])
        #expect(store.resolve(deletedItem) == nil)
        store.remove(deletedItem.id)
        #expect(store.items.count == 1)
        store.clear()
        #expect(store.items.isEmpty)
    }

    @Test("Corrupted recents file does not impede launch")
    func corruptedFile() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let storeURL = folder.url.appendingPathComponent("recent.json")
        try Data("{not json".utf8).write(to: storeURL)
        #expect(RecentFilesStore(fileURL: storeURL).items.isEmpty)
    }

    @Test("Card caption: open day and extension")
    func subtitle() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let item = RecentItem(
            id: UUID(), title: "Movie.mkv", path: "/tmp/Movie.mkv",
            openedAt: now.addingTimeInterval(-86_400), duration: nil, bookmark: nil)
        #expect(item.subtitle(available: true, now: now) == "Yesterday · MKV")
        #expect(item.subtitle(available: false, now: now) == "File not found")
    }
}

@Suite("Time format")
struct TimeFormatTests {
    @Test("Minutes, hours, and remaining time")
    func formats() {
        #expect(TimeFormat.string(245) == "4:05")
        #expect(TimeFormat.string(2535) == "42:15")
        #expect(TimeFormat.string(7083) == "1:58:03")
        #expect(TimeFormat.elapsed(245, duration: 7083) == "0:04:05")
        #expect(TimeFormat.remaining(position: 2535, duration: 7083) == "−1:15:48")
        #expect(TimeFormat.string(.nan) == "0:00")
        #expect(TimeFormat.string(-4) == "0:00")
    }
}
