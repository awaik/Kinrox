import AppKit
import MediaPlayer

@MainActor
final class NowPlayingController {
    private let center: any NowPlayingCenter
    private let clock: () -> TimeInterval
    private let artwork: MPMediaItemArtwork?
    private weak var model: (any NowPlayingSource)?
    private var observation: UUID?
    private var metadata: NowPlayingMetadata?
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

    func connect(to model: any NowPlayingSource) {
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
        guard let model, let updated = model.nowPlayingMetadata else {
            setCommands([])
            if metadata != nil { clear() }
            return
        }
        setCommands(model.nowPlayingCommands)
        let now = clock()
        let position = model.nowPlayingPosition
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
            MPNowPlayingInfoPropertyMediaType: updated.isMusic
                ? MPNowPlayingInfoMediaType.audio.rawValue
                : MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let album = updated.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if !updated.isMusic, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
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
        guard let model, model.nowPlayingMetadata != nil else {
            return .noActionableNowPlayingItem
        }
        let accepted = model.performNowPlaying(command, position: position)
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
