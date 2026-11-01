import Foundation

/// Pure library policy. Album saves, track likes and artist follows are independent.
public enum FavoritesPolicy {
    public static func track(_ id: String, liked: Bool, in library: LibrarySnapshot)
        -> FavoriteChange
    {
        guard library.likedTrackIDs.contains(id) != liked else { return FavoriteChange() }
        var mutations: [LibraryMutation] = [.trackLiked(id: id, liked)]
        var undo: [LibraryMutation] = [.trackLiked(id: id, !liked)]
        if !liked {
            for playlist in library.editablePlaylists {
                let positions = playlist.trackIDs.indices.filter { playlist.trackIDs[$0] == id }
                guard !positions.isEmpty else { continue }
                mutations.append(.playlistRemove(playlistID: playlist.id, trackID: id))
                // Restore every duplicate at its original index when the API allows.
                undo.append(
                    .playlistInsert(playlistID: playlist.id, trackID: id, positions: positions))
            }
        }
        return FavoriteChange(mutations: mutations, undo: undo, opensLikeOptions: liked)
    }

    public static func album(_ id: String, saved: Bool, in library: LibrarySnapshot)
        -> FavoriteChange
    {
        guard library.savedAlbumIDs.contains(id) != saved else { return FavoriteChange() }
        return FavoriteChange(
            mutations: [.albumSaved(id: id, saved)], undo: [.albumSaved(id: id, !saved)])
    }

    public static func artist(
        _ id: String, followed: Bool, in library: LibrarySnapshot
    ) -> FavoriteChange {
        guard library.followedArtistIDs.contains(id) != followed else { return FavoriteChange() }
        return FavoriteChange(
            mutations: [.artistFollowed(id: id, followed)],
            undo: [.artistFollowed(id: id, !followed)])
    }

    public static func membership(
        trackID: String, playlistID: String, included: Bool, in library: LibrarySnapshot
    ) -> FavoriteChange {
        guard let playlist = library.editablePlaylists.first(where: { $0.id == playlistID }) else {
            return FavoriteChange()
        }
        let positions = playlist.trackIDs.indices.filter { playlist.trackIDs[$0] == trackID }
        guard positions.isEmpty == included else { return FavoriteChange() }
        let remove = LibraryMutation.playlistRemove(playlistID: playlistID, trackID: trackID)
        let insert = LibraryMutation.playlistInsert(
            playlistID: playlistID, trackID: trackID,
            positions: included ? [playlist.trackIDs.count] : positions)
        return FavoriteChange(
            mutations: [included ? insert : remove], undo: [included ? remove : insert])
    }
}
