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
        let stripped = MusicTrack(
            id: track.id, uri: track.uri, title: track.title, artists: track.artists,
            albumID: track.albumID, albumTitle: track.albumTitle, duration: track.duration,
            playlistAddedAt: ["extra": Date(timeIntervalSince1970: 1_793_000_000)])
        catalog.merge(tracks: [stripped])
        #expect(catalog.track(id: track.id)?.addedAt == track.addedAt)
        #expect(
            catalog.track(id: track.id)?.addedDate(for: "extra")
                == Date(timeIntervalSince1970: 1_793_000_000))
        #expect(catalog.track(id: track.id)?.addedDate(for: "unknown-playlist") == nil)
    }

    @Test func mergeInternsArtistArrayAndAlbumStringBuffersAcrossTracks() {
        let artistA = MusicArtist(
            id: String("4Z8W4fKeB5YxbusRsdQVPb".utf8),
            uri: String("spotify:artist:4Z8W4fKeB5YxbusRsdQVPb".utf8),
            name: String("Long Canonical Artist Name Beyond SmallString".utf8))
        let artistB = MusicArtist(
            id: String("4Z8W4fKeB5YxbusRsdQVPb".utf8),
            uri: String("spotify:artist:4Z8W4fKeB5YxbusRsdQVPb".utf8),
            name: String("Long Canonical Artist Name Beyond SmallString".utf8))
        let albumTitleA = String("Long Canonical Album Title Beyond Inline Buffer".utf8)
        let albumTitleB = String("Long Canonical Album Title Beyond Inline Buffer".utf8)
        let album = MusicAlbum(
            id: String("6dVIqQ8qmQ5GBnJ9shOYGE".utf8),
            uri: String("spotify:album:6dVIqQ8qmQ5GBnJ9shOYGE".utf8),
            title: albumTitleA,
            artists: [artistA],
            year: "2026",
            trackIDs: ["t1", "t2"])
        let track1 = MusicTrack(
            id: "t1", uri: "spotify:track:t1", title: "T1",
            artists: [artistA], albumID: String("6dVIqQ8qmQ5GBnJ9shOYGE".utf8),
            albumTitle: albumTitleA, duration: 100)
        let track2 = MusicTrack(
            id: "t2", uri: "spotify:track:t2", title: "T2",
            artists: [artistB], albumID: String("6dVIqQ8qmQ5GBnJ9shOYGE".utf8),
            albumTitle: albumTitleB, duration: 120)
        let catalog = MusicCatalog(tracks: [track1, track2], albums: [album], artists: [artistA])
        let ptr1 = catalog.tracks[0].artists.withUnsafeBufferPointer(\.baseAddress)
        let ptr2 = catalog.tracks[1].artists.withUnsafeBufferPointer(\.baseAddress)
        let ptrAlbum = catalog.albums[0].artists.withUnsafeBufferPointer(\.baseAddress)
        #expect(ptr1 != nil && ptr1 == ptr2 && ptr1 == ptrAlbum)
        var t1TitleCopy = catalog.tracks[0].albumTitle
        var t2TitleCopy = catalog.tracks[1].albumTitle
        var albumTitleCopy = catalog.albums[0].title
        let titlePtr1 = t1TitleCopy.withUTF8(\.baseAddress)
        let titlePtr2 = t2TitleCopy.withUTF8(\.baseAddress)
        let titlePtrAlbum = albumTitleCopy.withUTF8(\.baseAddress)
        #expect(titlePtr1 != nil && titlePtr1 == titlePtr2 && titlePtr1 == titlePtrAlbum)
    }

    @Test func mergePreservesUpdatedAlbumIDWhenNewAlbumIsNotInCatalog() {
        let artist = MusicArtist(id: "ar1", uri: "spotify:artist:ar1", name: "Artist")
        let initial = MusicTrack(
            id: "t1", uri: "spotify:track:t1", title: "Track",
            artists: [artist], albumID: "album-old", albumTitle: "Old Album", duration: 180)
        var catalog = MusicCatalog(tracks: [initial])
        let updated = MusicTrack(
            id: "t1", uri: "spotify:track:t1", title: "Track",
            artists: [artist], albumID: "album-new", albumTitle: "New Album", duration: 180)
        catalog.merge(tracks: [updated])
        #expect(catalog.track(id: "t1")?.albumID == "album-new")
        #expect(catalog.track(id: "t1")?.albumTitle == "New Album")
    }
}
