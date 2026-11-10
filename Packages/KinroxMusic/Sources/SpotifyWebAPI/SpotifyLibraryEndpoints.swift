import Foundation
import MusicCore

extension SpotifyClient {
    public func profile() async throws -> SpotifyProfile {
        try await get(SpotifyProfile.self, "me")
    }
    public func likedTracks() async throws -> [SpotifyTrack] {
        try await pages(SpotifySavedTrack.self, "me/tracks?limit=50").compactMap(\.track)
    }
    public func savedAlbums() async throws -> [SpotifyAlbum] {
        try await pages(SpotifySavedAlbum.self, "me/albums?limit=50").map(\.album)
    }
    public func followedArtists() async throws -> [MusicArtist] {
        var next: String? = "me/following?type=artist&limit=50"
        var visited = Set<String>()
        var result: [MusicArtist] = []
        while let path = next {
            guard visited.insert(path).inserted, visited.count <= 2000 else {
                throw SpotifyError.invalidResponse
            }
            let response = try await get(SpotifyFollowedArtists.self, path)
            result += response.artists.items
            next = response.artists.next
        }
        return result
    }
    public func playlists() async throws -> [SpotifyPlaylist] {
        try await pages(SpotifyPlaylist.self, "me/playlists?limit=50")
    }
    public func playlist(_ id: String, live: Bool = false, priority: SpotifyRequestPriority? = nil)
        async throws -> SpotifyPlaylist
    {
        let data = try await request(
            "playlists/" + Self.identifier(id), priority: priority, live: live)
        return try JSONDecoder().decode(SpotifyPlaylist.self, from: data)
    }
    public func playlistItems(_ id: String) async throws -> [SpotifyPlaylistItem] {
        try await pages(
            SpotifyPlaylistItem.self, "playlists/" + Self.identifier(id) + "/items?limit=50")
    }
    public func track(_ id: String) async throws -> SpotifyTrack {
        try await get(SpotifyTrack.self, "tracks/" + Self.identifier(id))
    }
    public func album(_ id: String) async throws -> SpotifyAlbum {
        try await get(SpotifyAlbum.self, "albums/" + Self.identifier(id))
    }
    public func remainingAlbumTracks(_ next: String) async throws -> [SpotifyTrack] {
        try await pages(SpotifyTrack.self, next)
    }
    public func albumTracks(_ id: String) async throws -> [SpotifyTrack] {
        try await pages(SpotifyTrack.self, "albums/" + Self.identifier(id) + "/tracks?limit=50")
    }
    public func artist(_ id: String) async throws -> SpotifyArtistDetails {
        try await get(SpotifyArtistDetails.self, "artists/" + Self.identifier(id))
    }
    public func artistAlbums(
        _ id: String, includeGroups: String = "album,single"
    ) async throws -> [SpotifyAlbum] {
        try await pages(
            SpotifyAlbum.self,
            "artists/" + Self.identifier(id) + "/albums?limit=50&include_groups=" + includeGroups)
    }
    public func search(
        _ text: String, offset: Int = 0, types: String = "track,album,artist", limit: Int = 10
    ) async throws -> SpotifySearchResults {
        try await get(
            SpotifySearchResults.self, "search",
            query: [
                "q": text, "type": types, "limit": String(max(1, min(10, limit))),
                "offset": String(max(0, offset)),
            ])
    }

    /// Max 40 URIs per consolidated library request (2026 Development Mode API).
    public func setSaved(uris: [String], saved: Bool) async throws {
        guard !uris.isEmpty, uris.count <= 40,
            uris.allSatisfy({
                $0.hasPrefix("spotify:track:") || $0.hasPrefix("spotify:album:")
                    || $0.hasPrefix("spotify:artist:")
            })
        else { throw SpotifyError.invalidResponse }
        _ = try await request(
            "me/library", method: saved ? "PUT" : "DELETE",
            query: ["uris": uris.joined(separator: ",")])
    }

    public func createPlaylist(name: String, description: String = "") async throws
        -> SpotifyPlaylist
    {
        struct Body: Encodable {
            let name: String
            let description: String
            let `public`: Bool
        }
        let data = try await request(
            "me/playlists", method: "POST",
            body: JSONEncoder().encode(Body(name: name, description: description, public: false)))
        return try JSONDecoder().decode(SpotifyPlaylist.self, from: data)
    }

    public func insertItems(playlistID: String, uris: [String], position: Int?) async throws
        -> String
    {
        guard !uris.isEmpty, uris.count <= 100 else { throw SpotifyError.invalidResponse }
        struct Body: Encodable {
            let uris: [String]
            let position: Int?
        }
        let data = try await request(
            "playlists/" + Self.identifier(playlistID) + "/items", method: "POST",
            body: JSONEncoder().encode(Body(uris: uris, position: position.map { max(0, $0) })))
        return try JSONDecoder().decode(SpotifySnapshot.self, from: data).snapshotID
    }

    /// Removes every occurrence of each URI, matching FavoritesPolicy's undo positions.
    public func removeItems(playlistID: String, uris: [String]) async throws -> String {
        guard !uris.isEmpty, uris.count <= 100 else { throw SpotifyError.invalidResponse }
        struct Item: Encodable { let uri: String }
        struct Body: Encodable { let items: [Item] }
        let data = try await request(
            "playlists/" + Self.identifier(playlistID) + "/items", method: "DELETE",
            body: JSONEncoder().encode(Body(items: uris.map { Item(uri: $0) })))
        return try JSONDecoder().decode(SpotifySnapshot.self, from: data).snapshotID
    }

    public func replaceItems(playlistID: String, uris: [String]) async throws -> String {
        guard uris.count <= 100 else { throw SpotifyError.invalidResponse }
        struct Body: Encodable { let uris: [String] }
        let data = try await request(
            "playlists/" + Self.identifier(playlistID) + "/items", method: "PUT",
            body: JSONEncoder().encode(Body(uris: uris)))
        return try JSONDecoder().decode(SpotifySnapshot.self, from: data).snapshotID
    }

    static func identifier(_ id: String) throws -> String {
        guard !id.isEmpty, id.count <= 128,
            id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
        else { throw SpotifyError.invalidURL }
        return id
    }
}
