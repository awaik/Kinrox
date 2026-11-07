import Testing

@testable import MusicCore

struct BrowserSelectionTests {
    let catalog = MusicDemo.catalog
    let library = MusicDemo.library

    @Test func selectionResetsToTheRightAndAlbumKeepsTrackOrder() throws {
        var selection = BrowserSelection(source: .liked, albumID: "evening", trackID: "evening-2")
        selection.select(source: .albums)
        #expect(selection.albumID == nil && selection.trackID == nil)
        selection.select(albumID: "evening")
        let contents = selection.contents(catalog: catalog, library: library, queue: MusicQueue())
        #expect(contents.tracks.map(\.id) == catalog.albums.first { $0.id == "evening" }?.trackIDs)
        #expect(contents.albums.count == library.savedAlbumIDs.count)
    }

    @Test func likedPlaylistArtistAndSearchContents() {
        func contents(_ source: MusicSource) -> BrowserContents {
            BrowserSelection(source: source).contents(
                catalog: catalog, library: library, queue: MusicQueue())
        }
        #expect(Set(contents(.liked).tracks.map(\.id)) == library.likedTrackIDs)
        #expect(contents(.playlist("evening")).tracks.map(\.id) == library.playlists[0].trackIDs)
        #expect(contents(.artist("amber")).tracks.contains { $0.id == "evening-4" })
        #expect(contents(.search("lune")).tracks.contains { $0.id == "evening-2" })
        #expect(contents(.search("quiet evening")).tracks.count == 12)
        #expect(contents(.search("missing result")).tracks.isEmpty)
        #expect(contents(.search(" ")).tracks.isEmpty)
    }

    @Test func queueDuplicatesAndOrderArePreserved() {
        var queue = MusicQueue()
        queue.start(Array(catalog.tracks.prefix(3)))
        queue.add(catalog.tracks[1])
        let contents = BrowserSelection(source: .queue).contents(
            catalog: catalog, library: library, queue: queue)
        #expect(contents.tracks == queue.items.map(\.track))
    }

    @Test func similarSourceBuildsDiscoverySnapshotAndRespectsHideLiked() {
        let contents = BrowserSelection(source: .similar).contents(
            catalog: catalog, library: library, queue: MusicQueue())
        #expect(!contents.tracks.isEmpty)
        let snapshot = MusicDiscoveryEngine.build(
            seedTitle: catalog.tracks.first?.title ?? "",
            seedTrackIDs: catalog.tracks.first.map { [$0.id] } ?? [],
            mode: .sameSpirit, hideLiked: true,
            catalog: catalog, library: library)
        #expect(snapshot.items.allSatisfy { !library.likedTrackIDs.contains($0.track.id) })
        #expect(!snapshot.mixes.isEmpty)
    }

    @Test func freshAndUndergroundOnlyLabelConfirmedTracks() {
        let confirmedFresh = MusicTrack(
            id: "fresh-confirmed", uri: "spotify:track:fresh-confirmed", title: "Fresh Cut",
            artists: [MusicArtist(id: "a1", uri: "spotify:artist:a1", name: "Artist")],
            albumID: "alb-fresh", albumTitle: "Fresh Album", duration: 200)
        let unconfirmedCached = MusicTrack(
            id: "old-cached", uri: "spotify:track:old-cached", title: "Old Track",
            artists: [MusicArtist(id: "a1", uri: "spotify:artist:a1", name: "Artist")],
            albumID: "alb-old", albumTitle: "Old Album", duration: 200)
        let customCatalog = MusicCatalog(
            tracks: [unconfirmedCached], albums: [], artists: confirmedFresh.artists)
        let snapshot = MusicDiscoveryEngine.build(
            seedTitle: "Seed",
            mode: .fresh,
            catalog: customCatalog,
            library: LibrarySnapshot(userID: "owner"),
            freshTracks: [confirmedFresh])
        let freshItem = snapshot.items.first { $0.track.id == "fresh-confirmed" }
        let cachedItem = snapshot.items.first { $0.track.id == "old-cached" }
        #expect(freshItem?.reasonKind == .freshRelease)
        #expect(cachedItem?.reasonKind != .freshRelease)
        #expect(cachedItem?.reasonKind != .underground)
    }
}
