import AppKit
import MediaPlayer

@MainActor
final class NowPlayingController {
    private struct Metadata: Equatable {
        let url: URL?
        let title: String
        let artist: String
        let duration: Double
        let paused: Bool
    }

    private let center: any NowPlayingCenter
    private let clock: () -> TimeInterval
    private let artwork: MPMediaItemArtwork?
    private weak var model: PlayerViewModel?
    private var observation: UUID?
    private var metadata: Metadata?
    private var publishedPosition: Double = 0
    private var publishedAt: TimeInterval = 0
    private var awaitingPosition = false
    private var generation = UUID()
    private var enabledCommands: Set<NowPlayingCommand>?

    init(
        center: any NowPlayingCenter,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.center = center
        self.clock = clock
        if let image = NSImage(named: "KinroxLogo"), let data = image.tiffRepresentation {
            artwork = NowPlayingArtwork.make(data: data, size: image.size)
        } else {
            artwork = nil
        }
    }

    func connect(to model: PlayerViewModel) {
        disconnect()
        self.model = model
        let generation = generation
        center.installHandlers { [weak self] command, position in
            guard let self, self.generation == generation else {
                return .noActionableNowPlayingItem
            }
            return self.handle(command, position: position)
        }
        // After installing handlers, re-synchronize command availability.
        enabledCommands = nil
        observation = model.observePlayback { [weak self] event in
            if event == .shutdown {
                self?.disconnect()
            } else {
                self?.update(event: event)
            }
        }
        update()
    }

    func disconnect() {
        generation = UUID()
        if let observation { model?.removePlaybackObserver(observation) }
        observation = nil
        model = nil
        center.removeHandlers()
        setCommands([])
        clear()
    }

    private func clear() {
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        metadata = nil
        awaitingPosition = false
    }

    private func update(event: PlaybackEvent? = nil) {
        guard let model, model.canControl, !model.isLoading else {
            setCommands([])
            if metadata != nil { clear() }
            return
        }
        var enabled = Set(NowPlayingCommand.allCases)
        if !model.canNext { enabled.remove(.nextTrack) }
        if !model.canPrevious { enabled.remove(.previousTrack) }
        setCommands(enabled)

        let playlist = model.playlist
        let updated = Metadata(
            url: model.currentURL, title: model.displayTitle,
            artist: playlist.flatMap { $0.count > 1 ? $0.folderName : nil } ?? "Kinrox",
            duration: model.duration, paused: model.paused || model.isAtEnd)
        let now = clock()
        let position = model.playbackPosition
        let expected =
            publishedPosition + (metadata?.paused == false ? max(0, now - publishedAt) : 0)
        var force = event == .playbackRestarted
        // mpv may send time-pos after PLAYBACK_RESTART; account for both orderings.
        if case .property(.position, .number) = event, awaitingPosition {
            force = true
            awaitingPosition = false
        }
        if event == .playbackRestarted { awaitingPosition = true }
        guard
            force || metadata != updated || abs(position - expected) > 1.5
                || (updated.paused && position != publishedPosition)
        else { return }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: updated.title,
            MPMediaItemPropertyArtist: updated.artist,
            MPMediaItemPropertyPlaybackDuration: updated.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: updated.paused ? 0.0 : 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        let state: MPNowPlayingPlaybackState = updated.paused ? .paused : .playing
        if center.playbackState != state { center.playbackState = state }
        metadata = updated
        publishedPosition = position
        publishedAt = now
    }

    private func handle(_ command: NowPlayingCommand, position: Double?)
        -> MPRemoteCommandHandlerStatus
    {
        guard let model, model.canControl, !model.isLoading else {
            return .noActionableNowPlayingItem
        }
        let accepted: Bool
        switch command {
        case .togglePlayPause: accepted = model.togglePause()
        case .play: accepted = model.setPaused(false)
        case .pause: accepted = model.setPaused(true)
        case .nextTrack: accepted = model.next()
        case .previousTrack: accepted = model.previous()
        case .skipForward: accepted = model.seek(by: 10)
        case .skipBackward: accepted = model.seek(by: -10)
        case .changePlaybackPosition:
            guard let position, position.isFinite else { return .commandFailed }
            accepted = model.seek(to: position)
        }
        return accepted ? .success : .commandFailed
    }

    private func setCommands(_ commands: Set<NowPlayingCommand>) {
        guard enabledCommands != commands else { return }
        center.setEnabledCommands(commands)
        enabledCommands = commands
    }
}

enum NowPlayingArtwork {
    nonisolated static func make(data: Data, size: CGSize) -> MPMediaItemArtwork {
        // MediaPlayer requests artwork on its queue. Pass immutable
        // bytes and create separate image per request without capturing MainActor/NSImage.
        MPMediaItemArtwork(boundsSize: size) { @Sendable _ in
            NSImage(data: data) ?? NSImage(size: size)
        }
    }
}
