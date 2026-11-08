import Foundation
import MusicCore
import SQLite3
import Testing

@testable import Kinrox

struct SpotifyCacheTests {
    func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kinrox-cache-test-\(UUID())")
    }
    func value(date: Date) -> SpotifyCachedLibrary {
        var result = SpotifyCachedLibrary(library: MusicDemo.library, catalog: MusicDemo.catalog)
        for key in ["albums", "liked", "artists", "playlists"]
            + MusicDemo.catalog.albums.map({ "album:" + $0.id })
        {
            result.resources[key] = .init(fetchedAt: date, expiresAt: date.addingTimeInterval(300))
        }
        for playlist in result.library.playlists {
            result.resources["playlist:" + playlist.id] = .init(
                snapshotID: playlist.snapshotID,
                fetchedAt: date, expiresAt: date.addingTimeInterval(300))
        }
        return result
    }
    @Test func restoresCompleteResourcesAndIsolatesAccountNamespaces() async throws {
        let root = root()
        let date = Date()
        let first = SpotifyCacheStore(
            clientID: "client", userID: MusicDemo.library.userID, displayName: "Test", root: root)
        try await first.save(value(date: date), revision: 1)
        let restarted = SpotifyCacheStore(
            clientID: "client", userID: MusicDemo.library.userID, displayName: "Test", root: root)
        let cached = try await restarted.restore()
        #expect(cached.library == MusicDemo.library)
        #expect(cached.catalog.tracks.count == MusicDemo.catalog.tracks.count)
        let other = SpotifyCacheStore(
            clientID: "another", userID: MusicDemo.library.userID, displayName: "Test", root: root)
        #expect(try await other.restore().catalog.tracks.isEmpty)
        #expect(first.directory != other.directory)
        // Older publications cannot replace a newer commit.
        try await restarted.save(
            .init(library: LibrarySnapshot(userID: MusicDemo.library.userID)), revision: 9)
        try await restarted.save(value(date: date), revision: 8)
        #expect(try await restarted.restore().catalog.tracks.isEmpty)
    }
    @Test func newSessionCanCommitLowerRevisionAndRetiredWriterCannotOverwriteIt() async throws {
        let cache = SpotifyCacheStore(
            clientID: "client", userID: MusicDemo.library.userID, displayName: "Test", root: root())
        let old = UUID()
        let current = UUID()
        await cache.activate(old)
        try await cache.save(value(date: Date()), revision: 100, session: old)
        await cache.activate(current)
        try await cache.save(
            .init(library: LibrarySnapshot(userID: MusicDemo.library.userID)), revision: 1,
            session: current)
        try await cache.save(value(date: Date()), revision: 101, session: old)
        #expect(try await cache.restore().catalog.tracks.isEmpty)
    }

    @Test func hardExpiryEvictsWholeResourcesAndDisconnectRemovesSidecars() async throws {
        let root = root()
        let date = Date(timeIntervalSince1970: 1_000_000)
        let cache = SpotifyCacheStore(
            clientID: "client", userID: MusicDemo.library.userID, displayName: "Test", root: root,
            now: { date })
        try await cache.save(value(date: date), revision: 1)
        let expired = SpotifyCacheStore(
            clientID: "client", userID: MusicDemo.library.userID, displayName: "Test", root: root,
            now: { date.addingTimeInterval(SpotifyCacheStore.retention + 1) })
        let snapshot = try await expired.restore()
        #expect(snapshot.catalog.tracks.isEmpty && snapshot.library.playlists.isEmpty)
        for suffix in ["-wal", "-shm", "-journal"] {
            try Data().write(to: cache.directory.appendingPathComponent("library.sqlite" + suffix))
        }
        try await cache.destroyAccountCache()
        #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
        await #expect(throws: CancellationError.self) { _ = try await cache.restore() }
    }
    @Test(arguments: [false, true]) func corruptAndFutureSchemasRecover(future: Bool) async throws {
        let cache = SpotifyCacheStore(
            clientID: "client", userID: "user", displayName: "Test", root: root())
        try FileManager.default.createDirectory(
            at: cache.directory, withIntermediateDirectories: true)
        let file = cache.directory.appendingPathComponent("library.sqlite")
        if future {
            let db = try SpotifyCacheDatabase(url: file)
            try db.execute("PRAGMA user_version = 999")
            db.close()
        } else {
            try Data("broken SQLite".utf8).write(to: file)
        }
        #expect(try await cache.restore().library.userID == "user")
        #expect(try await cache.restore().catalog.tracks.isEmpty)
    }

    @Test func enablesMmapWalAndStreamsIncrementalDigestWrites() async throws {
        let root = root()
        let date = Date(timeIntervalSince1970: 2_000_000)
        let cache = SpotifyCacheStore(
            clientID: "client", userID: MusicDemo.library.userID, displayName: "Test", root: root,
            now: { date })
        var initial = value(date: date)
        try await cache.save(initial, revision: 1)

        let previewed = try await cache.preview()
        #expect(!previewed.catalog.albums.isEmpty)
        #expect(!previewed.catalog.tracks.isEmpty)

        // Mutate a single track title and verify incremental digest update persists it cleanly.
        var editedTrack = try #require(initial.catalog.tracks.first)
        editedTrack = MusicTrack(
            id: editedTrack.id, uri: editedTrack.uri, title: "Updated Title",
            artists: editedTrack.artists, albumID: editedTrack.albumID,
            albumTitle: editedTrack.albumTitle, duration: editedTrack.duration)
        initial.catalog.merge(tracks: [editedTrack])
        try await cache.save(initial, revision: 2)

        let restored = try await cache.restore()
        #expect(restored.catalog.track(id: editedTrack.id)?.title == "Updated Title")

        let db = try SpotifyCacheDatabase(
            url: cache.directory.appendingPathComponent("library.sqlite"))
        defer { db.close() }
        #expect(try db.scalar("PRAGMA journal_mode")?.lowercased() == "wal")
        #expect((Int(try db.scalar("PRAGMA mmap_size") ?? "0") ?? 0) >= 67_108_864)
    }
}
