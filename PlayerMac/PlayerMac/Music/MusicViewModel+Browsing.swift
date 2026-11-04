import Foundation
import MusicCore

enum TrackSortColumn: String, Codable, Equatable, Sendable {
    case number
    case title
    case artists
    case album
    case added
    case duration
}

struct TrackSortOrder: Codable, Equatable, Sendable {
    var column: TrackSortColumn
    var ascending: Bool

    static let `default` = TrackSortOrder(column: .number, ascending: true)
}

extension MusicViewModel {
    static let sortOrdersPreference = "app.kinrox.music.trackSortOrders"
    static let rememberedTracksPreference = "app.kinrox.music.focusedTracks"
    static let selectionPreference = "app.kinrox.music.selection"

    var showsAddedColumn: Bool {
        guard album == nil else { return false }
        switch selection.source {
        case .liked, .playlist: return true
        default: return false
        }
    }

    var sortStorageKey: String { selection.source.storageKey }

    var currentTrackSortOrder: TrackSortOrder {
        let order = trackSortOrders[sortStorageKey] ?? .default
        if order.column == .added && !showsAddedColumn { return .default }
        if order.column == .album && album != nil { return .default }
        return order
    }

    func toggleTrackSort(_ column: TrackSortColumn) {
        if column == .added && !showsAddedColumn { return }
        if column == .album && album != nil { return }
        let existing = currentTrackSortOrder
        let next: TrackSortOrder
        if existing.column == column {
            next = TrackSortOrder(column: column, ascending: !existing.ascending)
        } else {
            next = TrackSortOrder(column: column, ascending: column != .added)
        }
        trackSortOrders[sortStorageKey] = next
        persistSortOrders()
        refreshContents()
    }

    func addedDate(for track: MusicTrack) -> Date? {
        let resolved = catalog.track(id: track.id) ?? track
        if case .playlist(let playlistID) = selection.source {
            return resolved.addedDate(for: playlistID)
        }
        return resolved.addedDate()
    }

    func formattedAddedDate(for track: MusicTrack, locale: Locale = .current) -> String {
        guard let date = addedDate(for: track) else { return "—" }
        return date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    }

    func sortedTracks(_ tracks: [MusicTrack]) -> [MusicTrack] {
        let order = currentTrackSortOrder
        if order.column == .number {
            return order.ascending ? tracks : Array(tracks.reversed())
        }
        let indexed = Array(tracks.enumerated())
        return indexed.sorted { lhs, rhs in
            if order.column == .added {
                let lhsDate = addedDate(for: lhs.element)
                let rhsDate = addedDate(for: rhs.element)
                switch (lhsDate, rhsDate) {
                case (let l?, let r?) where l != r:
                    return order.ascending ? l < r : l > r
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.offset < rhs.offset
                }
            }
            let comparison: ComparisonResult
            switch order.column {
            case .title:
                comparison = lhs.element.title.localizedStandardCompare(rhs.element.title)
            case .artists:
                let artistComparison = lhs.element.artistNames.localizedStandardCompare(
                    rhs.element.artistNames)
                comparison =
                    artistComparison == .orderedSame
                    ? lhs.element.title.localizedStandardCompare(rhs.element.title)
                    : artistComparison
            case .album:
                comparison = lhs.element.albumTitle.localizedStandardCompare(rhs.element.albumTitle)
            case .duration:
                if lhs.element.duration == rhs.element.duration {
                    comparison = .orderedSame
                } else {
                    comparison =
                        lhs.element.duration < rhs.element.duration
                        ? .orderedAscending : .orderedDescending
                }
            case .number, .added:
                comparison = .orderedSame
            }
            if comparison == .orderedSame { return lhs.offset < rhs.offset }
            return order.ascending
                ? comparison == .orderedAscending : comparison == .orderedDescending
        }.map(\.element)
    }

    func focusTrack(_ id: String?, queueID: UUID? = nil) {
        focusedTrackID = id
        focusedQueueID = queueID
        if let id {
            rememberedTrackIDs[selection.storageKey] = id
            rememberedTrackIDs[selection.source.storageKey] = id
            persistRememberedTracks()
        }
    }

    func rememberedTrackID(for selection: BrowserSelection) -> String? {
        rememberedTrackIDs[selection.storageKey]
            ?? (selection.albumID == nil ? rememberedTrackIDs[selection.source.storageKey] : nil)
    }

    var hasActivePopover: Bool {
        likeOptionsTrackID != nil || previewAlbumAnchor != nil || previewArtistAnchor != nil
    }

    func dismissPopovers() {
        likeOptionsTrackID = nil
        likeOptionsAnchor = nil
        previewAlbumID = nil
        previewAlbumTrack = nil
        previewAlbumAnchor = nil
        previewArtists = []
        previewArtistID = nil
        previewArtistAnchor = nil
    }

    func openAlbumPreview(for track: MusicTrack, anchor: String) {
        guard !track.albumID.isEmpty else { return }
        if previewAlbumAnchor == anchor && previewAlbumID == track.albumID {
            dismissPopovers()
            return
        }
        dismissPopovers()
        previewAlbumID = track.albumID
        previewAlbumTrack = track
        previewAlbumAnchor = anchor
        if let store = store as? SpotifyLibraryStore {
            Task { [weak self] in
                guard let self else { return }
                try? await store.loadAlbum(track.albumID)
                guard self.store === store else { return }
                self.catalog = store.catalog
            }
        }
    }

    func openArtistPreview(for track: MusicTrack, artistID: String? = nil, anchor: String) {
        guard !track.artists.isEmpty else { return }
        let targetID = artistID ?? track.artists[0].id
        if previewArtistAnchor == anchor && previewArtistID == targetID {
            dismissPopovers()
            return
        }
        dismissPopovers()
        previewArtists = track.artists
        previewArtistID = targetID
        previewArtistAnchor = anchor
        loadPreviewArtistIfNeeded(targetID)
    }

    func selectPreviewArtist(_ id: String) {
        guard previewArtists.contains(where: { $0.id == id }) else { return }
        previewArtistID = id
        loadPreviewArtistIfNeeded(id)
    }

    private func loadPreviewArtistIfNeeded(_ id: String) {
        guard let store = store as? SpotifyLibraryStore else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await store.loadArtist(id)
            guard self.store === store else { return }
            self.catalog = store.catalog
        }
    }

    func navigateToAlbum(albumID: String, trackID: String? = nil) {
        guard !albumID.isEmpty else { return }
        dismissPopovers()
        selection.select(source: .albums)
        selection.select(albumID: albumID)
        if let trackID {
            rememberedTrackIDs[selection.storageKey] = trackID
            persistRememberedTracks()
        }
        persistSelection()
        refreshContents()
        if let trackID, contents.tracks.contains(where: { $0.id == trackID }) {
            focusTrack(trackID)
        }
        focusedColumn = .tracks
        loadSelection(albumID: albumID)
    }

    func navigateToArtist(_ artist: MusicArtist) {
        guard !artist.id.isEmpty else { return }
        dismissPopovers()
        catalog.merge(artists: [artist])
        focusedColumn = .source
        select(.artist(artist.id))
    }

    func persistSortOrders() {
        guard let defaults, let data = try? JSONEncoder().encode(trackSortOrders) else { return }
        defaults.set(data, forKey: Self.sortOrdersPreference)
    }

    func persistRememberedTracks() {
        guard let defaults, let data = try? JSONEncoder().encode(rememberedTrackIDs) else { return }
        defaults.set(data, forKey: Self.rememberedTracksPreference)
    }

    func persistSelection() {
        guard let defaults else { return }
        if case .search = selection.source { return }
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: Self.selectionPreference)
    }

    static func loadPersistedSortOrders(from defaults: UserDefaults?) -> [String: TrackSortOrder] {
        guard let data = defaults?.data(forKey: sortOrdersPreference),
            let decoded = try? JSONDecoder().decode([String: TrackSortOrder].self, from: data)
        else { return [:] }
        return decoded
    }

    static func loadPersistedRememberedTracks(from defaults: UserDefaults?) -> [String: String] {
        guard let data = defaults?.data(forKey: rememberedTracksPreference),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    static func loadPersistedSelection(from defaults: UserDefaults?) -> BrowserSelection? {
        guard let data = defaults?.data(forKey: selectionPreference),
            let decoded = try? JSONDecoder().decode(BrowserSelection.self, from: data)
        else { return nil }
        if case .search = decoded.source { return nil }
        return decoded
    }
}
