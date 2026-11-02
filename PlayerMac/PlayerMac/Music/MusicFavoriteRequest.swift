import Foundation
import MusicCore

/// Intent is evaluated only after the resources it reads have been validated.
enum MusicFavoriteRequest: Sendable {
    case track(String, liked: Bool?)
    case album(String, saved: Bool?)
    case artist(String, followed: Bool?)
    case membership(track: String, playlist: String, included: Bool)
    case undo([LibraryMutation], snapshots: [String: String])

    func change(in library: LibrarySnapshot) -> FavoriteChange {
        switch self {
        case .track(let id, let value):
            FavoritesPolicy.track(
                id, liked: value ?? !library.likedTrackIDs.contains(id), in: library)
        case .album(let id, let value):
            FavoritesPolicy.album(
                id, saved: value ?? !library.savedAlbumIDs.contains(id), in: library)
        case .artist(let id, let value):
            FavoritesPolicy.artist(
                id, followed: value ?? !library.followedArtistIDs.contains(id), in: library)
        case .membership(let track, let playlist, let included):
            FavoritesPolicy.membership(
                trackID: track, playlistID: playlist, included: included, in: library)
        case .undo(let mutations, _): FavoriteChange(mutations: mutations)
        }
    }
}

extension MusicLibraryStore {
    func change(_ request: MusicFavoriteRequest) async throws -> FavoriteChange {
        let change = request.change(in: library)
        try await apply(change.mutations)
        return change
    }
}

extension LibraryMutation {
    var resourceKeys: Set<String> {
        switch self {
        case .trackLiked: ["liked"]
        case .albumSaved: ["albums"]
        case .artistFollowed: ["artists"]
        case .playlistInsert(let id, _, _), .playlistRemove(let id, _):
            ["playlists", "playlist:" + id]
        }
    }
}
