import Foundation
import MusicCore
import SpotifyWebAPI

/// Serial transaction boundary for optimistic UI. Failed multi-playlist changes are
/// compensated before a later request may proceed; rate limits never trigger a retry storm.
@MainActor
final class FavoritesService {
    private let client: SpotifyClient
    private var pendingCompensation: [LibraryMutation] = []
    init(client: SpotifyClient) { self.client = client }

    func apply(_ mutations: [LibraryMutation], to snapshot: LibrarySnapshot) async throws
        -> LibrarySnapshot
    {
        while let mutation = pendingCompensation.first {
            _ = try await execute(mutation, in: snapshot)
            pendingCompensation.removeFirst()
        }
        var current = snapshot
        var undo: [LibraryMutation] = []
        do {
            let atomic = mutations.flatMap { mutation -> [LibraryMutation] in
                if case .playlistInsert(let id, let track, let positions) = mutation {
                    return positions.sorted().map {
                        .playlistInsert(playlistID: id, trackID: track, positions: [$0])
                    }
                }
                return [mutation]
            }
            for mutation in atomic {
                let inverse = inverse(mutation, in: current)
                let version = try await execute(mutation, in: current)
                current.apply([mutation])
                if let (id, snapshotID) = version,
                    let index = current.playlists.firstIndex(where: { $0.id == id })
                {
                    current.playlists[index].snapshotID = snapshotID
                }
                undo.insert(contentsOf: inverse, at: 0)
            }
            return current
        } catch {
            pendingCompensation = undo
            while let mutation = pendingCompensation.first {
                do {
                    _ = try await execute(mutation, in: snapshot)
                    pendingCompensation.removeFirst()
                } catch { break }
            }
            throw error
        }
    }

    private func execute(_ mutation: LibraryMutation, in snapshot: LibrarySnapshot) async throws
        -> (String, String)?
    {
        switch mutation {
        case .trackLiked(let id, let saved):
            try await client.setSaved(uris: ["spotify:track:" + id], saved: saved)
        case .albumSaved(let id, let saved):
            try await client.setSaved(uris: ["spotify:album:" + id], saved: saved)
        case .artistFollowed(let id, let saved):
            try await client.setSaved(uris: ["spotify:artist:" + id], saved: saved)
        case .playlistRemove(let id, let trackID):
            try editable(id, in: snapshot)
            return (
                id, try await client.removeItems(playlistID: id, uris: ["spotify:track:" + trackID])
            )
        case .playlistInsert(let id, let trackID, let positions):
            try editable(id, in: snapshot)
            var version = ""
            for position in positions.sorted() {
                version = try await client.insertItems(
                    playlistID: id, uris: ["spotify:track:" + trackID], position: position)
            }
            return version.isEmpty ? nil : (id, version)
        }
        return nil
    }

    private func editable(_ id: String, in snapshot: LibrarySnapshot) throws {
        guard snapshot.editablePlaylists.contains(where: { $0.id == id }) else {
            throw SpotifyError.forbidden
        }
    }

    private func inverse(_ mutation: LibraryMutation, in snapshot: LibrarySnapshot)
        -> [LibraryMutation]
    {
        switch mutation {
        case .trackLiked(let id, _):
            return [.trackLiked(id: id, snapshot.likedTrackIDs.contains(id))]
        case .albumSaved(let id, _):
            return [.albumSaved(id: id, snapshot.savedAlbumIDs.contains(id))]
        case .artistFollowed(let id, _):
            return [.artistFollowed(id: id, snapshot.followedArtistIDs.contains(id))]
        case .playlistRemove(let id, let track):
            let positions =
                snapshot.playlists.first { $0.id == id }?.trackIDs.enumerated().compactMap {
                    $0.element == track ? $0.offset : nil
                } ?? []
            return [.playlistInsert(playlistID: id, trackID: track, positions: positions)]
        case .playlistInsert(let id, let track, _):
            let positions =
                snapshot.playlists.first { $0.id == id }?.trackIDs.enumerated().compactMap {
                    $0.element == track ? $0.offset : nil
                } ?? []
            return [
                .playlistRemove(playlistID: id, trackID: track),
                .playlistInsert(playlistID: id, trackID: track, positions: positions),
            ]
        }
    }
}
