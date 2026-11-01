import Foundation
import MusicCore
import SpotifyWebAPI

@MainActor
final class SpotifyLibraryStore: MusicLibraryStore {
    private(set) var catalog = MusicCatalog()
    private(set) var library = LibrarySnapshot(userID: "")
    private let client: SpotifyClient
    private let favorites: FavoritesService
    private var index = PlaylistMembershipIndex()
    private var loadedAlbums = Set<String>()
    var queuePlaylistID: String?
    private var pendingCreation: (title: String, trackID: String, playlist: MusicPlaylist)?

    init(client: SpotifyClient) {
        self.client = client
        favorites = FavoritesService(client: client)
    }

    func excludeQueuePlaylist(_ id: String) {
        queuePlaylistID = id
        library.playlists.removeAll { $0.id == id }
    }

    /// Atomic publication: a cancelled or partial sync never replaces a complete cache.
    func refresh() async throws {
        _ = try await favorites.apply([], to: library)
        let profile = try await client.profile()
        let liked = try await client.likedTracks()
        let albums = try await client.savedAlbums()
        let artists = try await client.followedArtists()
        let playlists = try await client.playlists()
        var nextCatalog = catalog
        merge(
            tracks: liked.compactMap { $0.model() },
            albums: liked.compactMap { $0.album?.model() } + albums.map { $0.model() },
            artists: artists, into: &nextCatalog)
        var nextIndex = index
        var editable: [MusicPlaylist] = []
        for remote in playlists where remote.id != queuePlaylistID {
            var playlist = remote.model()
            guard playlist.isEditable(by: profile.id) else { continue }
            if let cached = index.trackIDs(playlistID: playlist.id, snapshotID: playlist.snapshotID)
            {
                playlist.trackIDs = cached
            } else {
                let entries = try await client.playlistItems(playlist.id)
                // Keep placeholders for local/unavailable items to retain exact Spotify positions.
                playlist.trackIDs = entries.enumerated().map { offset, entry in
                    entry.value?.id ?? "unavailable:\(offset)"
                }
                let tracks = entries.compactMap { $0.value?.model() }
                merge(
                    tracks: tracks, albums: entries.compactMap { $0.value?.album?.model() },
                    artists: [], into: &nextCatalog)
                nextIndex.update(
                    playlistID: playlist.id, snapshotID: playlist.snapshotID,
                    trackIDs: playlist.trackIDs)
            }
            editable.append(playlist)
        }
        nextIndex.retain(Set(editable.map(\.id)))
        try Task.checkCancellation()
        var mergedCatalog = catalog
        merge(
            tracks: nextCatalog.tracks, albums: nextCatalog.albums, artists: nextCatalog.artists,
            into: &mergedCatalog)
        catalog = mergedCatalog
        library = LibrarySnapshot(
            userID: profile.id, likedTrackIDs: Set(liked.compactMap(\.id)),
            savedAlbumIDs: Set(albums.map(\.id)), followedArtistIDs: Set(artists.map(\.id)),
            playlists: editable)
        index = nextIndex
    }

    func loadAlbum(_ id: String) async throws {
        guard !loadedAlbums.contains(id) else { return }
        let album = try await client.album(id)
        let tracks = try await client.albumTracks(id).compactMap { $0.model(album: album) }
        try Task.checkCancellation()
        merge(
            tracks: tracks, albums: [album.model(trackIDs: tracks.map(\.id))],
            artists: album.artists, into: &catalog)
        loadedAlbums.insert(id)
    }

    func loadArtist(_ id: String) async throws {
        let albums = try await client.artistAlbums(id)
        try Task.checkCancellation()
        merge(tracks: [], albums: albums.map { $0.model() }, artists: [], into: &catalog)
    }

    func search(_ query: String) async throws -> MusicCatalog {
        let results = try await client.search(query)
        let tracks = results.tracks?.items.compactMap { $0.model() } ?? []
        let albums =
            (results.albums?.items ?? []).map { $0.model() }
            + (results.tracks?.items ?? []).compactMap { $0.album?.model() }
        let artists = results.artists?.items ?? []
        try Task.checkCancellation()
        merge(tracks: tracks, albums: albums, artists: artists, into: &catalog)
        var result = MusicCatalog()
        merge(tracks: tracks, albums: albums, artists: artists, into: &result)
        return result
    }

    func apply(_ mutations: [LibraryMutation]) async throws {
        let next = try await favorites.apply(mutations, to: library)
        library = next
        for playlist in next.playlists {
            index.update(
                playlistID: playlist.id, snapshotID: playlist.snapshotID,
                trackIDs: playlist.trackIDs)
        }
    }

    func createPlaylist(title: String, trackID: String) async throws -> MusicPlaylist {
        var playlist: MusicPlaylist
        if let pendingCreation, pendingCreation.title == title, pendingCreation.trackID == trackID {
            playlist = pendingCreation.playlist
        } else {
            playlist = try await client.createPlaylist(name: title).model()
            pendingCreation = (title, trackID, playlist)
            library.playlists.append(playlist)
        }
        playlist.snapshotID = try await client.insertItems(
            playlistID: playlist.id, uris: ["spotify:track:" + trackID], position: 0)
        playlist.trackIDs = [trackID]
        pendingCreation = nil
        if let index = library.playlists.firstIndex(where: { $0.id == playlist.id }) {
            library.playlists[index] = playlist
        }
        index.update(
            playlistID: playlist.id, snapshotID: playlist.snapshotID, trackIDs: playlist.trackIDs)
        return playlist
    }

    private func merge(
        tracks: [MusicTrack], albums: [MusicAlbum], artists: [MusicArtist],
        into catalog: inout MusicCatalog
    ) {
        var trackIndices = Dictionary(
            catalog.tracks.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        for track in tracks {
            if let index = trackIndices[track.id] {
                catalog.tracks[index] = track
            } else {
                trackIndices[track.id] = catalog.tracks.count
                catalog.tracks.append(track)
            }
        }
        for album in albums {
            if let index = catalog.albums.firstIndex(where: { $0.id == album.id }) {
                if !album.trackIDs.isEmpty || catalog.albums[index].trackIDs.isEmpty {
                    catalog.albums[index] = album
                }
            } else {
                catalog.albums.append(album)
            }
        }
        for artist in artists + tracks.flatMap(\.artists) + albums.flatMap(\.artists) {
            if let index = catalog.artists.firstIndex(where: { $0.id == artist.id }) {
                catalog.artists[index] = artist
            } else {
                catalog.artists.append(artist)
            }
        }
    }
}
