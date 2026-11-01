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
}
