import Foundation

public struct LibrarySnapshot: Codable, Equatable, Sendable {
    public var userID: String
    public var likedTrackIDs: Set<String>
    public var savedAlbumIDs: Set<String>
    public var followedArtistIDs: Set<String>
    public var playlists: [MusicPlaylist]

    public init(
        userID: String, likedTrackIDs: Set<String> = [], savedAlbumIDs: Set<String> = [],
        followedArtistIDs: Set<String> = [], playlists: [MusicPlaylist] = []
    ) {
        self.userID = userID
        self.likedTrackIDs = likedTrackIDs
        self.savedAlbumIDs = savedAlbumIDs
        self.followedArtistIDs = followedArtistIDs
        self.playlists = playlists
    }

    public var editablePlaylists: [MusicPlaylist] { playlists.filter { $0.isEditable(by: userID) } }

    public mutating func apply(_ mutations: [LibraryMutation]) {
        for mutation in mutations {
            switch mutation {
            case .trackLiked(let id, let value): Self.set(id, value, in: &likedTrackIDs)
            case .albumSaved(let id, let value): Self.set(id, value, in: &savedAlbumIDs)
            case .artistFollowed(let id, let value): Self.set(id, value, in: &followedArtistIDs)
            case .playlistRemove(let playlistID, let trackID):
                guard let index = editableIndex(playlistID) else { continue }
                playlists[index].trackIDs.removeAll { $0 == trackID }
            case .playlistInsert(let playlistID, let trackID, let positions):
                guard let index = editableIndex(playlistID) else { continue }
                for position in positions.sorted() {
                    let offset = min(max(0, position), playlists[index].trackIDs.count)
                    playlists[index].trackIDs.insert(trackID, at: offset)
                }
            }
        }
    }

    private func editableIndex(_ id: String) -> Int? {
        playlists.firstIndex { $0.id == id && $0.isEditable(by: userID) }
    }

    private static func set(_ id: String, _ value: Bool, in set: inout Set<String>) {
        if value { set.insert(id) } else { set.remove(id) }
    }
}

public enum LibraryMutation: Codable, Equatable, Sendable {
    case trackLiked(id: String, Bool)
    case albumSaved(id: String, Bool)
    case artistFollowed(id: String, Bool)
    case playlistRemove(playlistID: String, trackID: String)
    case playlistInsert(playlistID: String, trackID: String, positions: [Int])
}

public struct FavoriteChange: Equatable, Sendable {
    public let mutations: [LibraryMutation]
    public let undo: [LibraryMutation]
    public let opensLikeOptions: Bool

    public init(
        mutations: [LibraryMutation] = [], undo: [LibraryMutation] = [],
        opensLikeOptions: Bool = false
    ) {
        self.mutations = mutations
        self.undo = undo
        self.opensLikeOptions = opensLikeOptions
    }
}
