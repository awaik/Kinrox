import Darwin
import Foundation
import Testing

@testable import Kinrox

@Suite("Live playlist filesystem", .timeLimit(.minutes(1)))
@MainActor
struct LivePlaylistFilesystemTests {
    @Test(
        "Temporary download suffixes are excluded until publication",
        arguments: ["part", "crdownload", "!qB"])
    func temporarySuffix(_ suffix: String) throws {
        let folder = try LivePlaylistFolder()
        defer { folder.remove() }
        let first = try folder.file("Episode 1.mkv")
        let temporary = try folder.file("Episode 2.mkv.\(suffix)")
        try folder.file("Episode 10.mp4")
        try folder.file(".hidden.mkv")
        try FileManager.default.createDirectory(
            at: folder.url.appendingPathComponent("nested.mkv"), withIntermediateDirectories: true)
        #expect(
            try FolderPlaylist.scanItems(in: folder.url).map(\.lastPathComponent) == [
                "Episode 1.mkv", "Episode 10.mp4",
            ])
        let final = folder.url.appendingPathComponent("Episode 2.mkv")
        try FileManager.default.moveItem(at: temporary, to: final)
        #expect(
            FolderPlaylist.scan(for: first).items.map(\.lastPathComponent) == [
                "Episode 1.mkv", "Episode 2.mkv", "Episode 10.mp4",
            ])
    }

    @Test("Natural-order ties have a deterministic path ordering")
    func orderingTies() {
        let left = URL(fileURLWithPath: "/a/Episode 1.mkv")
        let right = URL(fileURLWithPath: "/b/Episode 1.mkv")
        #expect(FolderPlaylist.finderOrder(left, right))
        #expect(!FolderPlaylist.finderOrder(right, left))
        #expect(!FolderPlaylist.finderOrder(left, left))
    }

    @Test("Live deletion retains the playing anchor and removes vanished neighbors")
    func deletionAndAlias() async throws {
        let folder = try LivePlaylistFolder()
        defer { folder.remove() }
        let first = try folder.file("1.mkv")
        let second = try folder.file("2.mkv")
        let third = try folder.file("10.mkv")
        let alias = folder.url.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder.url)
        let driver = FolderTestDriver()
        var dependencies = FolderMonitor.Dependencies()
        dependencies.watch = driver.dependencies.watch
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine, folderDependencies: dependencies)
        model.open(url: first)
        try await waitForRemote { model.playlist?.count == 3 }
        model.open(url: alias.appendingPathComponent("2.mkv"))
        #expect(model.playlist?.index == 1)
        #expect(driver.watches.count == 1)
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: second)
        driver.send()
        try await waitForRemote { model.playlist?.count == 2 }
        #expect(model.playlist?.current.lastPathComponent == "2.mkv")
        #expect(model.playlist?.next.map(VideoFiles.key) == VideoFiles.key(third))
        #expect(!model.canPrevious)
        #expect(engine.openedURLs.count == 2)
        await model.shutdown()
    }

    @Test("Replacing a directory reattaches the real vnode watcher")
    func replacedDirectory() async throws {
        let root = try LivePlaylistFolder()
        defer { root.remove() }
        let folder = root.url.appendingPathComponent("Series", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("1.mkv")
        try Data().write(to: first)
        let model = PlayerViewModel(engine: FakePlayerEngine())
        model.open(url: first)
        try await waitForRemote { model.playlist?.count == 1 }
        try FileManager.default.moveItem(at: folder, to: root.url.appendingPathComponent("Old"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("2.mkv"))
        try await waitForRemote { model.canNext }
        // An event on the replacement proves that the new descriptor is attached.
        try Data().write(to: folder.appendingPathComponent("3.mkv"))
        try await waitForRemote { model.playlist?.count == 3 }
        #expect(model.currentURL == first)
        await model.shutdown()
    }

    private func descriptors(for folder: URL) -> Set<Int32> {
        Set(
            (0..<1024).compactMap { descriptor in
                var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                guard fcntl(Int32(descriptor), F_GETPATH, &bytes) == 0 else { return nil }
                let path = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let url = URL(fileURLWithPath: String(decoding: path, as: UTF8.self))
                return VideoFiles.key(url) == VideoFiles.key(folder)
                    ? Int32(descriptor) : nil
            })
    }

    @Test("Stopping a live monitor closes the watched directory descriptor")
    func descriptorCleanup() async throws {
        let folder = try LivePlaylistFolder()
        defer { folder.remove() }
        let before = descriptors(for: folder.url)
        let monitor = FolderMonitor(folder: folder.url) { _ in }
        let opened = descriptors(for: folder.url).subtracting(before)
        try #require(opened.count == 1)
        monitor.stop()
        try await waitForRemote { descriptors(for: folder.url).intersection(opened).isEmpty }
    }

    @Test("Unavailable directory ends the watch stream and scan throws")
    func missingDirectory() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        var iterator = FolderMonitor.watch(folder).makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(throws: (any Error).self) { try FolderPlaylist.scanItems(in: folder) }
    }
}
