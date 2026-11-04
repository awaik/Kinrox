import Foundation

struct NowPlayingMetadata: Equatable {
    let identity: String
    let title: String
    let artist: String
    let album: String?
    let duration: Double
    let paused: Bool
    let isMusic: Bool
}

@MainActor
protocol NowPlayingSource: AnyObject {
    var nowPlayingMetadata: NowPlayingMetadata? { get }
    var nowPlayingPosition: Double { get }
    var nowPlayingCommands: Set<NowPlayingCommand> { get }
    func performNowPlaying(_ command: NowPlayingCommand, position: Double?) -> Bool
    func observePlayback(_ observer: @escaping (PlaybackEvent?) -> Void) -> UUID
    func removePlaybackObserver(_ id: UUID)
}

extension PlayerViewModel: NowPlayingSource {
    var nowPlayingMetadata: NowPlayingMetadata? {
        guard canControl, !isLoading else { return nil }
        return NowPlayingMetadata(
            identity: currentURL?.absoluteString ?? "", title: displayTitle,
            artist: playlist.flatMap { $0.count > 1 ? $0.folderName : nil } ?? "Kinrox", album: nil,
            duration: duration, paused: paused || isAtEnd, isMusic: false)
    }
    var nowPlayingPosition: Double { playbackPosition }
    var nowPlayingCommands: Set<NowPlayingCommand> {
        guard nowPlayingMetadata != nil else { return [] }
        var enabled = Set(NowPlayingCommand.allCases)
        if !canNext { enabled.remove(.nextTrack) }
        if !canPrevious { enabled.remove(.previousTrack) }
        return enabled
    }
    func performNowPlaying(_ command: NowPlayingCommand, position: Double?) -> Bool {
        switch command {
        case .togglePlayPause: return togglePause()
        case .play: return setPaused(false)
        case .pause: return setPaused(true)
        case .nextTrack: return next()
        case .previousTrack: return previous()
        case .skipForward: return seek(by: 10)
        case .skipBackward: return seek(by: -10)
        case .changePlaybackPosition:
            guard let position, position.isFinite else { return false }
            return seek(to: position)
        }
    }
}

extension MusicViewModel: NowPlayingSource {
    var nowPlayingMetadata: NowPlayingMetadata? {
        guard let track = currentTrack else { return nil }
        return NowPlayingMetadata(
            identity: queue.current?.id.uuidString ?? track.id, title: track.title,
            artist: track.artistNames, album: track.albumTitle,
            duration: playbackDuration > 0 ? playbackDuration : track.duration,
            paused: paused, isMusic: true)
    }
    var nowPlayingPosition: Double { displayedPosition }
    var nowPlayingCommands: Set<NowPlayingCommand> {
        guard currentTrack != nil else { return [] }
        var enabled = Set(NowPlayingCommand.allCases)
        if !canNext { enabled.remove(.nextTrack) }
        if !canPrevious { enabled.remove(.previousTrack) }
        if !allows("resuming") { enabled.remove(.play) }
        if !allows("pausing") { enabled.remove(.pause) }
        if !canTogglePause { enabled.remove(.togglePlayPause) }
        if !canSeek {
            enabled.subtract([.skipForward, .skipBackward, .changePlaybackPosition])
        }
        return enabled
    }
    func performNowPlaying(_ command: NowPlayingCommand, position: Double?) -> Bool {
        guard nowPlayingCommands.contains(command) else { return false }
        switch command {
        case .togglePlayPause: togglePause()
        case .play: setPaused(false)
        case .pause: setPaused(true)
        case .nextTrack: next()
        case .previousTrack: previous()
        case .skipForward: seek(self.displayedPosition + 10)
        case .skipBackward: seek(self.displayedPosition - 10)
        case .changePlaybackPosition:
            guard let position, position.isFinite else { return false }
            seek(position)
        }
        return true
    }
}
