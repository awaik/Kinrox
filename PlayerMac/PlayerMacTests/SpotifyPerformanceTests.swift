import Foundation
import MusicCore
import SpotifyWebAPI
import Testing

@testable import Kinrox

struct SpotifyPerformanceTests {
    static func fixture(trackCount: Int) -> SpotifyCachedLibrary {
        let artists = (0..<100).map {
            MusicArtist(id: "ar\($0)", uri: "spotify:artist:ar\($0)", name: "Artist \($0)")
        }
        let tracks = (0..<trackCount).map { n in
            MusicTrack(
                id: "t\(n)", uri: "spotify:track:t\(n)", title: "Track \(n)",
                artists: [artists[n % 100]], albumID: "a\(n / 10)", albumTitle: "Album \(n / 10)",
                duration: 180)
        }
        let albums = (0..<trackCount / 10).map { n in
            MusicAlbum(
                id: "a\(n)", uri: "spotify:album:a\(n)", title: "Album \(n)",
                artists: [artists[n % 100]], year: "2026",
                trackIDs: (n * 10..<n * 10 + 10).map { "t\($0)" })
        }
        let playlists = (0..<min(100, trackCount / 10)).map { n in
            MusicPlaylist(
                id: "p\(n)", uri: "spotify:playlist:p\(n)", title: "Playlist", ownerID: "owner",
                snapshotID: "v1", trackIDs: Array(tracks.dropFirst(n * 10).prefix(100)).map(\.id))
        }
        var result = SpotifyCachedLibrary(
            library: LibrarySnapshot(
                userID: "owner", likedTrackIDs: Set(tracks.map(\.id)),
                savedAlbumIDs: Set(albums.map(\.id)), playlists: playlists),
            catalog: MusicCatalog(tracks: tracks, albums: albums, artists: artists))
        let date = Date()
        for key in ["liked", "albums", "artists", "playlists"] + albums.map({ "album:" + $0.id })
            + playlists.map({ "playlist:" + $0.id })
        {
            result.resources[key] = .init(
                snapshotID: key.hasPrefix("playlist:") ? "v1" : nil,
                fetchedAt: date, expiresAt: date.addingTimeInterval(300))
        }
        return result
    }
    @MainActor @Test(arguments: [100, 10000]) func warmCachePublicationMetrics(trackCount: Int)
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinrox-performance-\(UUID())")
        let cache = SpotifyCacheStore(
            clientID: "test", userID: "owner", displayName: "Test", root: root)
        let fixture = Self.fixture(trackCount: trackCount)
        try await cache.save(fixture, revision: 1)
        var milliseconds: [Double] = []
        var hydration: [Double] = []
        let probe = CacheTokenProbe()
        let client = SpotifyClient { _ in try await probe.token() }
        for _ in 0..<20 {
            let cache = SpotifyCacheStore(
                clientID: "test", userID: "owner", displayName: "Test", root: root)
            let store = SpotifyLibraryStore(client: client, cache: cache, connected: false)
            let model = MusicViewModel(store: DisconnectedMusicLibraryStore())
            model.replaceStore(store)
            let publish = store.onChange
            let start = ContinuousClock.now
            var firstPublication: Duration?
            store.onChange = {
                publish?()
                if firstPublication == nil {
                    firstPublication = start.duration(to: .now)
                    #expect(model.catalog.albums.count == trackCount / 10)
                    #expect(model.contents.tracks.count == 10)
                }
            }
            await store.restore()
            let duration = try #require(firstPublication).components
            milliseconds.append(
                Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
            let completed = start.duration(to: .now).components
            hydration.append(
                Double(completed.seconds) * 1000 + Double(completed.attoseconds) / 1e15)
            #expect(model.catalog.tracks.count == trackCount)
            #expect(model.library == fixture.library)
            #expect(model.queue.current == nil && model.paused)
            store.retire()
        }
        #expect(await probe.reads == 0)
        await client.close()
        print("METRIC first-publication-\(trackCount)-p95-ms=\(milliseconds.sorted()[18])")
        print("METRIC complete-hydration-\(trackCount)-p95-ms=\(hydration.sorted()[18])")
    }
}

private actor CacheTokenProbe {
    var reads = 0
    func token() throws -> String {
        reads += 1
        throw SpotifyError.authentication
    }
}
