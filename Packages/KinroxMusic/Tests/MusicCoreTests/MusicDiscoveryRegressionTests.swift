import Foundation
import Testing

@testable import MusicCore

struct MusicDiscoveryRegressionTests {
    func track(_ id: String, title: String, artist: String = "other") -> MusicTrack {
        MusicTrack(
            id: id, uri: "spotify:track:\(id)", title: title,
            artists: [MusicArtist(id: artist, uri: "spotify:artist:\(artist)", name: artist)],
            albumID: "album", albumTitle: "Album", duration: 200)
    }

    @Test func unrelatedCatalogHasNoInventedSignalGenreOrMix() {
        let seed = track("seed", title: "Seed", artist: "seedArtist")
        let unrelated = track("unrelated", title: "Unrelated")
        let result = MusicDiscoveryEngine.build(
            seedTrackIDs: [seed.id], hideLiked: false,
            catalog: MusicCatalog(tracks: [seed, unrelated]), library: LibrarySnapshot(userID: "u"))
        #expect(result.items.isEmpty)
        #expect(result.genres.isEmpty)
        #expect(result.mixes.isEmpty)
    }

    @Test func seedRemixIsExcludedAndOneArtistCannotFillFirstThirty() {
        let seed = track("seed", title: "Refu", artist: "Christian Löffler")
        let remix = track(
            "remix", title: "Refu (Dominik Eulberg Remix)", artist: "Christian Löffler")
        let candidates = (0..<16).flatMap { artist in
            (0..<4).map {
                track("\(artist)-\($0)", title: "Song \($0)", artist: "other\(artist)")
            }
        }
        let start = ContinuousClock.now
        let result = MusicDiscoveryEngine.build(
            seedTrackIDs: [seed.id], hideLiked: false,
            catalog: MusicCatalog(tracks: [seed]), library: LibrarySnapshot(userID: "u"),
            freshTracks: candidates + [remix])
        #expect(start.duration(to: .now) < .milliseconds(15))
        #expect(!result.tracks.contains { $0.id == remix.id })
        let groups = Dictionary(grouping: result.tracks.prefix(30), by: { $0.artists.first?.id })
        #expect(result.tracks.count == 64)
        #expect(groups.values.allSatisfy { $0.count <= 2 })
    }
}
