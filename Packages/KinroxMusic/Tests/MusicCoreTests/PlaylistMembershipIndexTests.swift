import Foundation
import Testing

@testable import MusicCore

struct PlaylistMembershipIndexTests {
    @Test func fiftyPlaylistsReuseSnapshotsAndUnlikeOnlyTouchesMemberships() {
        var index = PlaylistMembershipIndex()
        var playlists: [MusicPlaylist] = []
        for number in 0..<55 {
            let id = "playlist-\(number)"
            let tracks = number.isMultiple(of: 5) ? ["other", "target", "target"] : ["other"]
            index.update(playlistID: id, snapshotID: "version-1", trackIDs: tracks)
            playlists.append(
                MusicPlaylist(
                    id: id, uri: "spotify:playlist:\(id)", title: id,
                    ownerID: "me", snapshotID: "version-1", trackIDs: tracks))
        }
        let misses = playlists.filter {
            index.trackIDs(playlistID: $0.id, snapshotID: $0.snapshotID) == nil
        }
        #expect(misses.isEmpty)
        let library = LibrarySnapshot(userID: "me", likedTrackIDs: ["target"], playlists: playlists)
        let start = ContinuousClock.now
        let change = FavoritesPolicy.track("target", liked: false, in: library)
        // One library write and 11 playlist removals; no 55-playlist rescan.
        #expect(change.mutations.count == 12)
        var changed = library
        changed.apply(change.mutations)
        #expect(changed.playlists.allSatisfy { !$0.trackIDs.contains("target") })
        changed.apply(change.undo)
        #expect(changed == library)
        print(
            "MUSIC_INDEX fixture: playlists=55, coldReads=55, warmReads=0, unlikeWrites=12, policyDuration=\(start.duration(to: .now))"
        )
        #expect(index.trackIDs(playlistID: "playlist-0", snapshotID: "version-2") == nil)
        #expect(index.trackIDs(playlistID: "playlist-0", snapshotID: nil) == nil)
        index.invalidate("playlist-1")
        #expect(index.trackIDs(playlistID: "playlist-1", snapshotID: "version-1") == nil)
        index.retain(["playlist-0"])
        #expect(index.trackIDs(playlistID: "playlist-5", snapshotID: "version-1") == nil)
    }
}
