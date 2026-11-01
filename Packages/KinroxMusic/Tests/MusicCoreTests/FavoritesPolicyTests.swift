import Testing

@testable import MusicCore

struct FavoritesPolicyTests {
    @Test func likeOnlyLikesTrackAndOpensOptions() {
        let original = MusicDemo.library
        let change = FavoritesPolicy.track("evening-1", liked: true, in: original)
        var library = original
        library.apply(change.mutations)
        #expect(change.opensLikeOptions)
        #expect(library.likedTrackIDs.contains("evening-1"))
        #expect(library.savedAlbumIDs == original.savedAlbumIDs)
        #expect(library.followedArtistIDs == original.followedArtistIDs)
        #expect(library.playlists == original.playlists)
        library.apply(change.undo)
        #expect(library == original)
    }

    @Test func unlikeRemovesEveryEditableOccurrenceButNeverUnfollows() {
        var original = MusicDemo.library
        original.playlists[0].trackIDs = ["neon-0", "evening-2", "cats-0", "evening-2"]
        original.playlists[1].trackIDs = ["evening-2", "evening-2"]
        original.playlists.append(
            MusicPlaylist(
                id: "foreign", uri: "foreign", title: "Other owner", ownerID: "other",
                trackIDs: ["evening-2"]))
        let change = FavoritesPolicy.track("evening-2", liked: false, in: original)
        var library = original
        library.apply(change.mutations)
        #expect(!change.opensLikeOptions)
        #expect(!library.likedTrackIDs.contains("evening-2"))
        #expect(library.editablePlaylists.allSatisfy { !$0.trackIDs.contains("evening-2") })
        #expect(library.playlists.last == original.playlists.last)
        #expect(library.followedArtistIDs == original.followedArtistIDs)
        #expect(library.savedAlbumIDs == original.savedAlbumIDs)
        library.apply(change.undo)
        #expect(library == original)
    }

    @Test func albumAndArtistChangesAreIndependentAndUndoable() {
        let original = MusicDemo.library
        for change in [
            FavoritesPolicy.album("evening", saved: false, in: original),
            FavoritesPolicy.artist("north", followed: false, in: original),
            FavoritesPolicy.album("new", saved: true, in: original),
            FavoritesPolicy.artist("new", followed: true, in: original),
        ] {
            var library = original
            library.apply(change.mutations)
            #expect(library.likedTrackIDs == original.likedTrackIDs)
            #expect(library.playlists == original.playlists)
            #expect(!change.opensLikeOptions)
            library.apply(change.undo)
            #expect(library == original)
        }
    }

    @Test func checkboxAppliesImmediatelyAndPreservesOtherState() {
        let original = MusicDemo.library
        var library = original
        let change = FavoritesPolicy.membership(
            trackID: "evening-1", playlistID: "road", included: true, in: library)
        library.apply(change.mutations)
        #expect(library.playlists[1].trackIDs.last == "evening-1")
        #expect(library.likedTrackIDs == original.likedTrackIDs)
        #expect(library.followedArtistIDs == original.followedArtistIDs)
        library.apply(change.undo)
        #expect(library == original)
        #expect(
            FavoritesPolicy.membership(
                trackID: "evening-1", playlistID: "missing", included: true, in: library
            ).mutations.isEmpty)
    }

    @Test func untrustedMutationsCannotEditOtherPeoplesPlaylists() {
        var library = LibrarySnapshot(
            userID: "me",
            playlists: [
                MusicPlaylist(
                    id: "other", uri: "other", title: "Other", ownerID: "them", trackIDs: ["a"])
            ])
        let original = library
        #expect(
            FavoritesPolicy.membership(
                trackID: "a", playlistID: "other", included: false, in: library
            ).mutations.isEmpty)
        library.apply([
            .playlistRemove(playlistID: "other", trackID: "a"),
            .playlistInsert(playlistID: "other", trackID: "b", positions: [0]),
        ])
        #expect(library == original)
    }

    @Test func duplicateRequestsAreIdempotent() {
        let library = MusicDemo.library
        #expect(FavoritesPolicy.track("evening-2", liked: true, in: library).mutations.isEmpty)
        #expect(FavoritesPolicy.track("evening-1", liked: false, in: library).mutations.isEmpty)
        #expect(FavoritesPolicy.album("evening", saved: true, in: library).mutations.isEmpty)
        #expect(FavoritesPolicy.artist("north", followed: true, in: library).mutations.isEmpty)
        #expect(
            FavoritesPolicy.membership(
                trackID: "evening-2", playlistID: "evening", included: true, in: library
            ).mutations.isEmpty)
    }
}
