import Foundation

extension Message {
    func validateLibraryFields() throws {
        let valid: Bool
        switch self {
        case .requestState(_, let request):
            if let features = request.features {
                valid =
                    features.count <= 16
                    && features.allSatisfy { !$0.isEmpty && $0.utf8.count <= 64 }
            } else {
                valid = true
            }
        case .state(_, let state):
            let libraryValid = state.library.map(Self.validLibraryState) ?? true
            let sourcesValid = state.sources.map(Self.validSources) ?? true
            valid = libraryValid && sourcesValid
        case .requestLibrary(_, let request):
            valid =
                (0...100_000).contains(request.offset)
                && Self.validParentId(request.parentId, section: request.section)
                && (request.query?.utf8.count ?? 0) <= 200
        case .library(_, let page):
            valid =
                Self.validParentId(page.parentId, section: page.section)
                && Self.validPage(
                    offset: page.offset, count: page.items.count, total: page.total,
                    next: page.nextOffset)
                && Set(page.items.map(\.id)).count == page.items.count
                && page.items.allSatisfy(Self.validLibraryItem)
        case .requestLibraryItem(_, let request):
            valid = Command.validMusicID(request.id)
        case .libraryItem(_, let response):
            valid =
                Self.validLibraryItem(response.item) && Self.validLibraryDetails(response.details)
        case .requestArtwork(_, let request):
            valid = Command.validMusicID(request.id) && (64...360).contains(request.maxPixel)
        case .artwork(_, let response):
            valid = Command.validMusicID(response.id) && (response.jpeg?.count ?? 0) <= 40_000
        default: return
        }
        guard valid else {
            throw ProtocolError(code: .invalidPayload, message: "Invalid library payload.")
        }
    }

    private static func validLibraryState(_ state: RemoteLibraryState) -> Bool {
        let range = 0...1_000_000
        return range.contains(state.folders) && range.contains(state.videos)
            && range.contains(state.series) && range.contains(state.albums)
            && range.contains(state.tracks)
    }

    private static func validSources(_ sources: RemoteSources) -> Bool {
        sources.video.map(validSourceSummary) != false
            && sources.localMusic.map(validSourceSummary) != false
            && sources.spotify.map(validSourceSummary) != false
    }

    private static func validSourceSummary(_ summary: RemoteSourceSummary) -> Bool {
        summary.title.utf8.count <= 2048 && (summary.subtitle?.utf8.count ?? 0) <= 2048
            && summary.artwork.map(Command.validMusicID) != false
    }

    private static func validParentId(_ parentId: String?, section: RemoteLibrarySection) -> Bool {
        if section == .children { return parentId.map(Command.validMusicID) == true }
        return parentId == nil
    }

    private static func validProgress(_ progress: RemoteWatchProgress) -> Bool {
        progress.position.isFinite && progress.position >= 0 && progress.duration.isFinite
            && progress.duration >= 0
    }

    private static func validRating(_ rating: Double?, scale: Int?) -> Bool {
        if rating == nil && scale == nil { return true }
        guard let rating, let scale, rating.isFinite, rating >= 0, scale == 5 || scale == 10 else {
            return false
        }
        return rating <= Double(scale)
    }

    private static func validLibraryItem(_ item: RemoteLibraryItem) -> Bool {
        Command.validMusicID(item.id)
            && item.title.utf8.count <= 2048
            && (item.subtitle?.utf8.count ?? 0) <= 2048
            && (item.episodeLabel?.utf8.count ?? 0) <= 64
            && item.season.map { $0 >= 0 } != false
            && item.episode.map { $0 >= 0 } != false
            && item.trackNumber.map { $0 >= 0 } != false
            && item.year.map { (0...9999).contains($0) } != false
            && validRating(item.rating, scale: item.ratingScale)
            && item.genres.count <= 5 && item.genres.allSatisfy { $0.utf8.count <= 128 }
            && item.badges.count <= 4 && item.badges.allSatisfy { $0.utf8.count <= 64 }
            && item.duration.map { $0.isFinite && $0 >= 0 } != false
            && item.progress.map(validProgress) != false
            && item.childCount.map { (0...1_000_000).contains($0) } != false
            && (item.folderName?.utf8.count ?? 0) <= 512
    }

    private static func validLibraryDetails(_ details: LibraryItemDetails) -> Bool {
        (details.overview?.utf8.count ?? 0) <= 4096
            && (details.ratingSource?.utf8.count ?? 0) <= 64
            && details.fileName.map { $0.utf8.count <= 1024 && !$0.contains("/") } != false
            && (details.folderName?.utf8.count ?? 0) <= 512
            && details.audioLanguages.count <= 32
            && details.audioLanguages.allSatisfy { $0.utf8.count <= 64 }
            && details.subtitleLanguages.count <= 64
            && details.subtitleLanguages.allSatisfy { $0.utf8.count <= 64 }
            && details.seasons.count <= 200 && details.seasons.allSatisfy { $0 >= 0 }
            && details.watchedCount.map { (0...1_000_000).contains($0) } != false
            && details.nextEpisodeId.map(Command.validMusicID) != false
    }
}
