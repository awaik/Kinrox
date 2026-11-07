import Foundation

public enum MusicDiscoveryMode: String, Codable, CaseIterable, Sendable {
    case sameSpirit
    case underground
    case fresh
}

public enum MusicDiscoveryReasonKind: String, Codable, Equatable, Sendable {
    case playlistCooccurrence
    case compilation
    case underground
    case freshRelease
    case sharedGenre
    case sharedArtist
}

public struct MusicDiscoveryItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String { track.id }
    public let track: MusicTrack
    public let reasonKind: MusicDiscoveryReasonKind
    public let contextName: String
    public let matchCount: Int
    public let score: Int

    public init(
        track: MusicTrack, reasonKind: MusicDiscoveryReasonKind, contextName: String = "",
        matchCount: Int = 1, score: Int = 1
    ) {
        self.track = track
        self.reasonKind = reasonKind
        self.contextName = contextName
        self.matchCount = max(1, matchCount)
        self.score = score
    }
}

public struct MusicDiscoveryMix: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let trackIDs: [String]

    public init(id: String, title: String, subtitle: String, trackIDs: [String]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.trackIDs = trackIDs
    }
}

public struct MusicDiscoverySnapshot: Codable, Equatable, Sendable {
    public var seedTitle: String
    public var mode: MusicDiscoveryMode
    public var genres: [String]
    public var selectedGenre: String?
    public var hideLiked: Bool
    public var items: [MusicDiscoveryItem]
    public var mixes: [MusicDiscoveryMix]

    public init(
        seedTitle: String = "", mode: MusicDiscoveryMode = .sameSpirit,
        genres: [String] = [], selectedGenre: String? = nil, hideLiked: Bool = true,
        items: [MusicDiscoveryItem] = [], mixes: [MusicDiscoveryMix] = []
    ) {
        self.seedTitle = seedTitle
        self.mode = mode
        self.genres = genres
        self.selectedGenre = selectedGenre
        self.hideLiked = hideLiked
        self.items = items
        self.mixes = mixes
    }

    public var tracks: [MusicTrack] { items.map(\.track) }
}

public enum MusicDiscoveryEngine {
    public static let defaultGenres = [
        "psybient", "organic electronic", "downtempo", "handpan", "ambient", "melodic techno",
    ]

    public static func build(
        seedTitle: String = "",
        seedTrackIDs: Set<String> = [],
        seedArtistIDs: Set<String> = [],
        seedArtistName: String = "",
        mode: MusicDiscoveryMode = .sameSpirit,
        genres: [String] = [],
        selectedGenre: String? = nil,
        hideLiked: Bool = true,
        catalog: MusicCatalog,
        library: LibrarySnapshot,
        cooccurringPlaylists: [(playlist: MusicPlaylist, tracks: [MusicTrack])] = [],
        compilationAlbums: [(album: MusicAlbum, tracks: [MusicTrack])] = [],
        undergroundTracks: [MusicTrack] = [],
        freshTracks: [MusicTrack] = [],
        operatorTracks: [MusicTrack] = []
    ) -> MusicDiscoverySnapshot {
        let excludedIDs = seedTrackIDs.union(hideLiked ? library.likedTrackIDs : [])
        var bestByTrackID: [String: MusicDiscoveryItem] = [:]
        var cooccurrenceCounts: [String: Int] = [:]

        func consider(_ candidate: MusicDiscoveryItem) {
            guard candidate.track.isPlayable != false, !excludedIDs.contains(candidate.track.id)
            else { return }
            if let existing = bestByTrackID[candidate.track.id] {
                if candidate.score > existing.score {
                    bestByTrackID[candidate.track.id] = candidate
                }
            } else {
                bestByTrackID[candidate.track.id] = candidate
            }
        }

        // 1. Co-occurring public/library playlists
        for (playlist, tracks) in cooccurringPlaylists {
            for track in tracks {
                cooccurrenceCounts[track.id, default: 0] += 1
                let count = cooccurrenceCounts[track.id, default: 1]
                consider(
                    MusicDiscoveryItem(
                        track: track,
                        reasonKind: .playlistCooccurrence,
                        contextName: seedArtistName.isEmpty ? playlist.title : seedArtistName,
                        matchCount: count,
                        score: 90 + count * 10))
            }
        }

        // 2. Collaborator & compilation releases (appears_on / compilation)
        for (album, tracks) in compilationAlbums {
            for track in tracks {
                consider(
                    MusicDiscoveryItem(
                        track: track,
                        reasonKind: .compilation,
                        contextName: album.title,
                        matchCount: 1,
                        score: 80))
            }
        }

        // 3. Confirmed album tag searches (tag:hipster / tag:new) and genre/spirit searches
        for (offset, track) in undergroundTracks.enumerated() {
            consider(
                MusicDiscoveryItem(
                    track: track,
                    reasonKind: .underground,
                    contextName: track.albumTitle.isEmpty ? seedArtistName : track.albumTitle,
                    matchCount: 1,
                    score: (mode == .underground ? 95 : 75) - min(20, offset)))
        }

        for (offset, track) in freshTracks.enumerated() {
            consider(
                MusicDiscoveryItem(
                    track: track,
                    reasonKind: .freshRelease,
                    contextName: track.albumTitle.isEmpty ? seedArtistName : track.albumTitle,
                    matchCount: 1,
                    score: (mode == .fresh ? 95 : 75) - min(20, offset)))
        }

        for (offset, track) in operatorTracks.enumerated() {
            let sharesArtist = !seedArtistIDs.isDisjoint(with: track.artists.map(\.id))
            consider(
                MusicDiscoveryItem(
                    track: track,
                    reasonKind: sharesArtist ? .sharedArtist : .sharedGenre,
                    contextName: sharesArtist
                        ? track.artistNames
                        : (selectedGenre ?? genres.first ?? track.albumTitle),
                    matchCount: 1,
                    score: max(40, 85 - offset)))
        }

        // 4. Local catalog & playlist graph fallback (only assigns confirmed relationships)
        for playlist in library.playlists {
            let playlistTracks = playlist.trackIDs.compactMap { catalog.track(id: $0) }
            let overlapsSeed =
                seedTrackIDs.isEmpty
                || playlistTracks.contains {
                    seedTrackIDs.contains($0.id)
                        || !seedArtistIDs.isDisjoint(with: $0.artists.map(\.id))
                }
            if overlapsSeed {
                for track in playlistTracks {
                    cooccurrenceCounts[track.id, default: 0] += 1
                    let count = cooccurrenceCounts[track.id, default: 1]
                    consider(
                        MusicDiscoveryItem(
                            track: track,
                            reasonKind: .playlistCooccurrence,
                            contextName: playlist.title,
                            matchCount: count,
                            score: 70 + count * 5))
                }
            }
        }

        for track in catalog.tracks {
            let sharesArtist = !seedArtistIDs.isDisjoint(with: track.artists.map(\.id))
            let reason: MusicDiscoveryReasonKind = sharesArtist ? .sharedArtist : .sharedGenre
            let baseScore = sharesArtist ? 65 : 50
            consider(
                MusicDiscoveryItem(
                    track: track,
                    reasonKind: reason,
                    contextName: sharesArtist
                        ? track.artistNames : (selectedGenre ?? track.albumTitle),
                    matchCount: 1,
                    score: baseScore))
        }

        let ordered = bestByTrackID.values.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.track.title.localizedStandardCompare(rhs.track.title) == .orderedAscending
        }

        var mixes: [MusicDiscoveryMix] = []
        for (playlist, tracks) in cooccurringPlaylists.prefix(3) where !tracks.isEmpty {
            mixes.append(
                MusicDiscoveryMix(
                    id: "playlist:\(playlist.id)",
                    title: playlist.title,
                    subtitle: "\(tracks.count)",
                    trackIDs: tracks.map(\.id)))
        }
        if mixes.isEmpty {
            let topIDs = Array(ordered.prefix(8).map(\.track.id))
            if !topIDs.isEmpty {
                mixes.append(
                    MusicDiscoveryMix(
                        id: "mix:spirit",
                        title: seedTitle.isEmpty ? "Discovery Wave" : seedTitle,
                        subtitle: "\(topIDs.count)",
                        trackIDs: topIDs))
            }
        }

        let resolvedGenres = genres.isEmpty ? defaultGenres : genres
        return MusicDiscoverySnapshot(
            seedTitle: seedTitle,
            mode: mode,
            genres: resolvedGenres,
            selectedGenre: selectedGenre,
            hideLiked: hideLiked,
            items: ordered,
            mixes: mixes)
    }
}
