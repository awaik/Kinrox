import MediaPlayer

enum NowPlayingCommand: CaseIterable, Sendable {
    case togglePlayPause, play, pause, nextTrack, previousTrack
    case changePlaybackPosition, skipForward, skipBackward
}

typealias NowPlayingCommandHandler =
    @MainActor @Sendable (NowPlayingCommand, Double?) -> MPRemoteCommandHandlerStatus

@MainActor
protocol NowPlayingCenter: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
    var playbackState: MPNowPlayingPlaybackState { get set }
    func installHandlers(_ handler: @escaping NowPlayingCommandHandler)
    func setEnabledCommands(_ enabled: Set<NowPlayingCommand>)
    func removeHandlers()
}

@MainActor
final class SystemNowPlayingCenter: NowPlayingCenter {
    private let infoCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var targets: [(MPRemoteCommand, Any)] = []

    var nowPlayingInfo: [String: Any]? {
        get { infoCenter.nowPlayingInfo }
        set { infoCenter.nowPlayingInfo = newValue }
    }

    var playbackState: MPNowPlayingPlaybackState {
        get { infoCenter.playbackState }
        set { infoCenter.playbackState = newValue }
    }

    func installHandlers(_ handler: @escaping NowPlayingCommandHandler) {
        removeHandlers()
        commandCenter.skipForwardCommand.preferredIntervals = [10]
        commandCenter.skipBackwardCommand.preferredIntervals = [10]
        for kind in NowPlayingCommand.allCases {
            let command = command(for: kind)
            let target = command.addTarget { @Sendable event in
                // Event object remains on origin thread; only Double is passed to MainActor.
                let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
                return Self.deliver(kind, position: position, to: handler)
            }
            targets.append((command, target))
        }
    }

    nonisolated static func deliver(
        _ command: NowPlayingCommand, position: Double?, to handler: NowPlayingCommandHandler
    ) -> MPRemoteCommandHandlerStatus {
        // SDK does not guarantee callback queue. Main queue is MainActor executor
        // in AppKit app; thread check prevents sync onto itself.
        if Thread.isMainThread {
            return MainActor.assumeIsolated { handler(command, position) }
        }
        return DispatchQueue.main.sync { handler(command, position) }
    }

    func setEnabledCommands(_ enabled: Set<NowPlayingCommand>) {
        for kind in NowPlayingCommand.allCases {
            command(for: kind).isEnabled = enabled.contains(kind)
        }
        for command in unsupportedCommands { command.isEnabled = false }
    }

    func removeHandlers() {
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        setEnabledCommands([])
    }

    private func command(for kind: NowPlayingCommand) -> MPRemoteCommand {
        switch kind {
        case .togglePlayPause: commandCenter.togglePlayPauseCommand
        case .play: commandCenter.playCommand
        case .pause: commandCenter.pauseCommand
        case .nextTrack: commandCenter.nextTrackCommand
        case .previousTrack: commandCenter.previousTrackCommand
        case .changePlaybackPosition: commandCenter.changePlaybackPositionCommand
        case .skipForward: commandCenter.skipForwardCommand
        case .skipBackward: commandCenter.skipBackwardCommand
        }
    }

    private var unsupportedCommands: [MPRemoteCommand] {
        [
            commandCenter.stopCommand, commandCenter.enableLanguageOptionCommand,
            commandCenter.disableLanguageOptionCommand, commandCenter.changePlaybackRateCommand,
            commandCenter.changeRepeatModeCommand, commandCenter.changeShuffleModeCommand,
            commandCenter.seekForwardCommand, commandCenter.seekBackwardCommand,
            commandCenter.ratingCommand, commandCenter.likeCommand, commandCenter.dislikeCommand,
            commandCenter.bookmarkCommand,
        ]
    }
}
