import Foundation
import Testing

@testable import MusicCore

struct MusicCatalogTests {
    @Test func indicesSurviveMergeAndCodableWithoutChangingOccurrenceOrder() throws {
        let track = MusicDemo.catalog.tracks[0]
        let album = MusicAlbum(
            id: "a", uri: "demo:a", title: "Album", artists: track.artists,
            year: "2026", trackIDs: [track.id, "missing", track.id])
        var catalog = MusicCatalog(tracks: [track, track], albums: [album])
        #expect(catalog.tracks.count == 1)
        #expect(catalog.tracks(in: album) == [track, track])
        catalog.merge(albums: [
            MusicAlbum(
                id: "a", uri: "demo:a", title: "Summary", artists: [], year: "", trackIDs: [])
        ])
        #expect(catalog.album(id: "a") == album)
        let data = try JSONEncoder().encode(catalog)
        #expect(!String(decoding: data, as: UTF8.self).contains("Indices"))
        let restored = try JSONDecoder().decode(MusicCatalog.self, from: data)
        #expect(restored.track(id: track.id) == track)
        #expect(restored.artist(id: track.artists[0].id) == track.artists[0])
        #expect(restored == catalog)
    }
}
