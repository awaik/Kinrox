import Foundation

public enum MusicSource: Hashable, Sendable {
    case albums, liked, queue
    case playlist(String)
    case artist(String)
    case search(String)
}

public struct BrowserContents: Equatable, Sendable {
    public let albums: [MusicAlbum]
    public let artists: [MusicArtist]
    public let tracks: [MusicTrack]

    public init(albums: [MusicAlbum], artists: [MusicArtist], tracks: [MusicTrack]) {
        self.albums = albums
        self.artists = artists
        self.tracks = tracks
    }
}

public struct BrowserSelection: Equatable, Sendable {
    public var source: MusicSource
    public var albumID: String?
    public var trackID: String?

    public init(source: MusicSource = .albums, albumID: String? = nil, trackID: String? = nil) {
        self.source = source
        self.albumID = albumID
        self.trackID = trackID
    }

    public mutating func select(source: MusicSource) {
        self.source = source
        albumID = nil
        trackID = nil
    }

    public mutating func select(albumID: String?) {
        self.albumID = albumID
        trackID = nil
    }

    public func contents(
        catalog: MusicCatalog, library: LibrarySnapshot, queue: MusicQueue
    ) -> BrowserContents {
        let tracks: [MusicTrack]
        var albums = catalog.albums
        var artists = catalog.artists
        switch source {
        case .albums:
            albums = albums.filter { library.savedAlbumIDs.contains($0.id) }
            let ids = Set(albums.map(\.id))
            tracks = catalog.tracks.filter { ids.contains($0.albumID) }
        case .liked:
            tracks = catalog.tracks.filter { library.likedTrackIDs.contains($0.id) }
        case .playlist(let id):
            tracks = (library.playlists.first { $0.id == id }?.trackIDs ?? []).compactMap { id in
                catalog.tracks.first { $0.id == id }
            }
        case .artist(let id):
            albums = albums.filter { $0.artists.contains { $0.id == id } }
            tracks = catalog.tracks.filter { $0.artists.contains { $0.id == id } }
        case .queue:
            tracks = queue.items.map(\.track)
        case .search(let query):
            let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            func matches(_ value: String) -> Bool {
                !query.isEmpty && value.localizedStandardContains(query)
            }
            artists = artists.filter { matches($0.name) }
            tracks = catalog.tracks.filter {
                matches($0.title) || matches($0.albumTitle)
                    || $0.artists.contains { matches($0.name) }
            }
            albums = albums.filter { matches($0.title) || $0.artists.contains { matches($0.name) } }
        }
        let trackAlbums = Set(tracks.map(\.albumID))
        if source != .albums {
            albums = catalog.albums.filter {
                trackAlbums.contains($0.id) || albums.contains($0) && retainsAlbums
            }
        }
        let filtered: [MusicTrack]
        if let albumID, source == .albums,
            let album = catalog.albums.first(where: { $0.id == albumID })
        {
            filtered = catalog.tracks(in: album)
        } else {
            filtered = albumID.map { id in tracks.filter { $0.albumID == id } } ?? tracks
        }
        return BrowserContents(albums: albums, artists: artists, tracks: filtered)
    }

    private var retainsAlbums: Bool {
        switch source {
        case .search, .artist: true
        default: false
        }
    }
}
