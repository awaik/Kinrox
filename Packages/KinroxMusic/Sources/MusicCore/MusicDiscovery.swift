import Foundation

public enum MusicDiscoveryMode: String, Codable, CaseIterable, Sendable {
    case sameSpirit, underground, fresh
}

public enum MusicDiscoveryReasonKind: String, Codable, Equatable, Sendable {
    case listenBrainzRecording, listenBrainzArtist, collaborator, remixer, compilation
    case ownPlaylist, likedSameDay, playHistory, sharedGenre, freshRelease, underground
}

public struct MusicDiscoveryReason: Codable, Equatable, Sendable {
    public let kind: MusicDiscoveryReasonKind
    public let detail: String
    public let matchCount: Int

    public init(kind: MusicDiscoveryReasonKind, detail: String = "", matchCount: Int = 1) {
        self.kind = kind
        self.detail = detail
        self.matchCount = max(1, matchCount)
    }
}

public enum MusicDiscoverySectionKind: String, Codable, CaseIterable, Sendable {
    case listeners, collaborators, yourPlaylists, genre

    public init(reason: MusicDiscoveryReasonKind) {
        switch reason {
        case .listenBrainzRecording, .listenBrainzArtist: self = .listeners
        case .collaborator, .remixer, .compilation: self = .collaborators
        case .ownPlaylist, .likedSameDay, .playHistory: self = .yourPlaylists
        case .sharedGenre, .freshRelease, .underground: self = .genre
        }
    }
}

public struct MusicDiscoverySection: Identifiable, Codable, Equatable, Sendable {
    public var id: String { kind.rawValue }
    public let kind: MusicDiscoverySectionKind
    public let items: [MusicDiscoveryItem]
}

public struct MusicDiscoverySeed: Codable, Equatable, Sendable {
    public let title: String
    public let artistNames: String
    public let trackID: String?
    public let artistID: String?

    public init(
        title: String = "", artistNames: String = "", trackID: String? = nil,
        artistID: String? = nil
    ) {
        self.title = title
        self.artistNames = artistNames
        self.trackID = trackID
        self.artistID = artistID
    }
}

public enum MusicGenreSource: String, Codable, Equatable, Sendable {
    case spotify, musicBrainz, none
}

public enum MusicListenBrainzStatus: String, Codable, Equatable, Sendable {
    case off, ready, unavailable
}

public struct MusicDiscoveryItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String { track.id }
    public let track: MusicTrack
    public let reasons: [MusicDiscoveryReason]
    public let score: Double
    public let section: MusicDiscoverySectionKind
    public var primaryReason: MusicDiscoveryReason? { reasons.first }
    public var reasonKind: MusicDiscoveryReasonKind { reasons.first?.kind ?? .sharedGenre }

    public init(track: MusicTrack, reasons: [MusicDiscoveryReason], score: Double) {
        self.track = track
        self.reasons = reasons
        self.score = score
        section = .init(reason: reasons.first?.kind ?? .sharedGenre)
    }
}

public struct MusicDiscoveryMix: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let trackIDs: [String]
}

public struct MusicDiscoverySnapshot: Codable, Equatable, Sendable {
    public var seed: MusicDiscoverySeed
    public var mode: MusicDiscoveryMode
    public var genres: [String]
    public var genreSource: MusicGenreSource
    public var selectedGenre: String?
    public var hideLiked: Bool
    public var sections: [MusicDiscoverySection]
    public var items: [MusicDiscoveryItem]
    public var mixes: [MusicDiscoveryMix]
    public var tracks: [MusicTrack] { items.map(\.track) }
    public var displayItems: [MusicDiscoveryItem] { sections.flatMap(\.items) }
    public var displayTracks: [MusicTrack] { displayItems.map(\.track) }

    public init(
        seed: MusicDiscoverySeed = .init(), mode: MusicDiscoveryMode = .sameSpirit,
        genres: [String] = [], genreSource: MusicGenreSource = .none,
        selectedGenre: String? = nil, hideLiked: Bool = true,
        items: [MusicDiscoveryItem] = [], mixes: [MusicDiscoveryMix] = []
    ) {
        self.seed = seed
        self.mode = mode
        self.genres = genres
        self.genreSource = genres.isEmpty ? .none : genreSource
        self.selectedGenre = selectedGenre
        self.hideLiked = hideLiked
        self.items = items
        self.mixes = mixes
        sections = MusicDiscoverySectionKind.allCases.compactMap { kind in
            let members = items.filter { $0.section == kind }
            return members.isEmpty ? nil : MusicDiscoverySection(kind: kind, items: members)
        }
    }
}

/// Signals are persisted with complete candidate metadata, then ranked against current local feedback.
public struct MusicDiscoverySignal: Codable, Equatable, Sendable {
    public let track: MusicTrack
    public let reason: MusicDiscoveryReason
    public let strength: Double
    public let lowerHalf: Bool

    public init(
        track: MusicTrack, kind: MusicDiscoveryReasonKind, detail: String = "",
        matchCount: Int = 1, strength: Double = 1, lowerHalf: Bool = false
    ) {
        self.track = track
        reason = MusicDiscoveryReason(kind: kind, detail: detail, matchCount: matchCount)
        self.strength = strength.isFinite ? min(1, max(0, strength)) : 0
        self.lowerHalf = lowerHalf
    }

    public static let weights: [MusicDiscoveryReasonKind: Double] = [
        .listenBrainzRecording: 1, .listenBrainzArtist: 0.8, .collaborator: 0.7,
        .remixer: 0.6, .ownPlaylist: 0.7, .compilation: 0.5, .likedSameDay: 0.4,
        .playHistory: 0.6, .sharedGenre: 0.35, .freshRelease: 0.45, .underground: 0.45,
    ]
    public var contribution: Double { strength * Self.weights[reason.kind, default: 0] }

    public static func normalizedScores(_ scores: [Double]) -> [Double] {
        let maximum = scores.filter(\.isFinite).max() ?? 0
        return scores.enumerated().map { index, score in
            maximum > 0
                ? (score.isFinite ? max(0, min(1, score / maximum)) : 0)
                : 1 - Double(index) / Double(max(1, scores.count))
        }
    }
}

public struct MusicPlayHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let trackID: String
    public let previousTrackID: String?
    public let playedAt: Date
    public let playedSeconds: Double
    public let completed: Bool
    public let skipped: Bool

    public init(
        id: UUID = UUID(), sessionID: UUID, trackID: String, previousTrackID: String? = nil,
        playedAt: Date, playedSeconds: Double, completed: Bool, skipped: Bool
    ) {
        self.id = id
        self.sessionID = sessionID
        self.trackID = trackID
        self.previousTrackID = previousTrackID
        self.playedAt = playedAt
        self.playedSeconds = playedSeconds
        self.completed = completed
        self.skipped = skipped
    }

    public static func retained(_ rows: [Self], now: Date) -> [Self] {
        Array(
            rows.filter { $0.playedAt > now.addingTimeInterval(-180 * 86400) }
                .sorted { $0.playedAt < $1.playedAt }.suffix(20_000))
    }
}
