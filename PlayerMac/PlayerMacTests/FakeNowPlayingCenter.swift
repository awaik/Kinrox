import MediaPlayer

@testable import Kinrox

@MainActor
final class FakeNowPlayingCenter: NowPlayingCenter {
    var nowPlayingInfo: [String: Any]? { didSet { infoWrites += 1 } }
    var playbackState: MPNowPlayingPlaybackState = .unknown
    var infoWrites = 0
    var enabled: Set<NowPlayingCommand> = []
    var enabledOnInstall: Set<NowPlayingCommand>?
    var handler: NowPlayingCommandHandler?

    func installHandlers(_ handler: @escaping NowPlayingCommandHandler) {
        self.handler = handler
        if let enabledOnInstall { enabled = enabledOnInstall }
    }
    func setEnabledCommands(_ enabled: Set<NowPlayingCommand>) { self.enabled = enabled }
    func removeHandlers() { handler = nil }

    // Even disabled commands can be invoked: testing race with player state changes.
    func send(_ command: NowPlayingCommand, position: Double? = nil) -> MPRemoteCommandHandlerStatus
    {
        handler?(command, position) ?? .noActionableNowPlayingItem
    }
}
