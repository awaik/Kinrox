import Foundation
import MusicCore

@MainActor
protocol MusicLibraryStore: AnyObject {
    var catalog: MusicCatalog { get }
    var library: LibrarySnapshot { get }
    func change(_ request: MusicFavoriteRequest) async throws -> FavoriteChange
    func apply(_ mutations: [LibraryMutation]) async throws
    func createPlaylist(title: String, trackID: String) async throws -> MusicPlaylist
}

/// Deliberately offline. Demo identifiers are never passed to Spotify.
@MainActor
final class DemoMusicLibraryStore: MusicLibraryStore {
    let catalog = MusicDemo.catalog
    private(set) var library = MusicDemo.library

    func apply(_ mutations: [LibraryMutation]) async throws { library.apply(mutations) }

    func createPlaylist(title: String, trackID: String) async throws -> MusicPlaylist {
        let id = UUID().uuidString
        let playlist = MusicPlaylist(
            id: id, uri: "demo:playlist:\(id)", title: title, ownerID: library.userID,
            trackIDs: [trackID])
        library.playlists.append(playlist)
        return playlist
    }
}

@MainActor
final class DisconnectedMusicLibraryStore: MusicLibraryStore {
    enum Failure: Error { case disconnected }
    let catalog = MusicCatalog()
    let library = LibrarySnapshot(userID: "")
    func apply(_ mutations: [LibraryMutation]) async throws { throw Failure.disconnected }
    func createPlaylist(title: String, trackID: String) async throws -> MusicPlaylist {
        throw Failure.disconnected
    }
}
