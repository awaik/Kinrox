import Foundation

extension Message {
    func validateMusicFields() throws {
        let valid: Bool
        switch self {
        case .requestQueue(_, let request): valid = (0...100_000).contains(request.offset)
        case .requestLikeOptions(_, let request):
            valid = Command.validMusicID(request.trackId) && (0...100_000).contains(request.offset)
        case .queue(_, let page):
            valid =
                Self.validPage(
                    offset: page.offset, count: page.items.count, total: page.total,
                    next: page.nextOffset)
                && Set(page.items.map(\.id)).count == page.items.count
                && page.items.allSatisfy { Self.validTrack($0.track) }
        case .likeOptions(_, let page):
            valid =
                Command.validMusicID(page.trackId)
                && Self.validPage(
                    offset: page.offset, count: page.items.count, total: page.total,
                    next: page.nextOffset)
                && page.items.allSatisfy(\.isValid)
        case .state(_, let state):
            guard let music = state.music else { return }
            valid =
                (0...100_000).contains(music.queueCount) && music.outputName.utf8.count <= 2048
                && (music.status?.utf8.count ?? 0) <= 2048
                && (music.disallowedActions?.count ?? 0) <= 32
                && music.disallowedActions?.allSatisfy { $0.utf8.count <= 64 } != false
                && music.track.map(Self.validTrack) != false
                && music.nextTrack.map(Self.validTrack) != false
                && (state.source == .video || music.volumeKnown != false
                    || (state.volume == 0 && music.disallowedActions?.contains("volume") == true))
        default: return
        }
        guard valid else {
            throw ProtocolError(code: .invalidPayload, message: "Invalid music payload.")
        }
    }

    private static func validTrack(_ track: RemoteMusicTrack) -> Bool {
        Command.validMusicID(track.id) && track.albumID.map(Command.validMusicID) != false
            && track.title.utf8.count <= 2048
            && track.album.utf8.count <= 2048 && track.year.utf8.count <= 32
            && track.artists.count <= 100 && track.artists.allSatisfy { $0.utf8.count <= 2048 }
            && track.duration.isFinite && track.duration >= 0
    }
    private static func validPage(offset: Int, count: Int, total: Int, next: Int?) -> Bool {
        guard (0...100_000).contains(total), (0...total).contains(offset), count <= 50,
            offset + count <= total
        else { return false }
        if let next { return count > 0 && next == offset + count && next < total }
        return offset + count == total
    }
}
