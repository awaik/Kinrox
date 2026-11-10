import Foundation
import MusicCore
import Testing

@testable import SpotifyWebAPI

struct DiscoveryMetadataTests {
    @Test func isrcAndFullReleaseDateSurviveSimplifiedAlbumTracksAndOldCache() throws {
        let full =
            #"{"id":"track","uri":"spotify:track:track","name":"Song","duration_ms":200000,"artists":[],"external_ids":{"isrc":"AB123"},"album":{"id":"album","uri":"spotify:album:album","name":"Album","artists":[],"release_date":"2026-11-01"}}"#
        let response = try JSONDecoder().decode(SpotifyTrack.self, from: Data(full.utf8))
        let track = try #require(response.model())
        #expect(track.isrc == "AB123")
        #expect(track.releaseDate == "2026-11-01")
        #expect(response.album?.model().releaseDate == "2026-11-01")
        let oldAlbum = MusicAlbum(
            id: "album", uri: "spotify:album:album", title: "Album", artists: [], year: "2026",
            trackIDs: ["track"])
        var catalog = MusicCatalog(tracks: [track], albums: [oldAlbum])
        catalog.merge(albums: [try #require(response.album?.model())])
        #expect(catalog.album(id: "album")?.trackIDs == ["track"])
        #expect(catalog.album(id: "album")?.releaseDate == "2026-11-01")
        let simplified =
            #"{"id":"track","uri":"spotify:track:track","name":"Song","duration_ms":200000,"artists":[]}"#
        let item = try JSONDecoder().decode(SpotifyTrack.self, from: Data(simplified.utf8))
        catalog.merge(tracks: [try #require(item.model(album: response.album))])
        #expect(catalog.track(id: "track")?.isrc == "AB123")
        #expect(catalog.track(id: "track")?.releaseDate == "2026-11-01")
        let old =
            #"{"id":"old","uri":"old","title":"Old","artists":[],"albumID":"album","albumTitle":"Album","duration":200}"#
        #expect(try JSONDecoder().decode(MusicTrack.self, from: Data(old.utf8)).isrc == nil)
    }
}
