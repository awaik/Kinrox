import Foundation
import Observation

enum AppMode { case video, music }

/// Shared application state upon which menus and player window depend.
@MainActor @Observable
final class PlayerSession {
    var mode = AppMode.video
    let music: MusicViewModel
    let spotify = SpotifyAccount()
    let playback = PlaybackCoordinator()
    var model: PlayerViewModel? {
        didSet {
            remote?.connect(to: model)
            if model != nil { playback.connect(video: model, music: music) }
        }
    }
    var remote: RemoteServer? { didSet { remote?.connectMusic(music, coordinator: playback) } }
    /// While file open panel is displayed, unmodified keys belong to it.
    var isOpenPanelShown = false
    let recents: RecentFilesStore
    let pairing = PairingCenter()
    let updates = UpdateCenter()

    init(
        recents: RecentFilesStore,
        demoMusic: Bool = ProcessInfo.processInfo.environment["KINROX_MUSIC_DEMO"] == "1"
    ) {
        self.recents = recents
        music = MusicViewModel(
            store: demoMusic ? DemoMusicLibraryStore() : DisconnectedMusicLibraryStore())
        spotify.onConnected = { [weak self] client in
            guard let self else { return }
            let store = SpotifyLibraryStore(client: client)
            let clientID = self.spotify.clientID
            let userID = self.spotify.userID ?? ""
            let factory: () -> any MusicEngine = { [weak store, weak self] in
                let engine = SpotifyConnectMusicEngine(
                    client: client, clientID: clientID, userID: userID)
                store?.queuePlaylistID = engine.playlistID
                engine.onPlaylistCreated = { [weak store, weak self] id in
                    store?.excludeQueuePlaylist(id)
                    if let store { self?.music.library = store.library }
                }
                return engine
            }
            self.music.replaceStore(store, accountName: self.spotify.accountName)
            self.music.acceptsPlayback = true
            self.music.engineFactory = factory
            self.music.connect(engine: factory())
            self.music.syncLibrary()
        }
        spotify.onDisconnected = { [weak self] in
            self?.music.engineFactory = nil
            self?.music.replaceStore(DisconnectedMusicLibraryStore())
        }
        spotify.beforeDisconnect = { [weak self] in
            guard let self else { return }
            self.music.acceptsPlayback = false
            self.playback.cancelPending(.music)
            await self.playback.settle()
            await self.music.shutdownPlayback()
        }
        playback.connect(video: nil, music: music)
    }

    var canControl: Bool {
        if controlsMusic {
            return !isOpenPanelShown && pairing.prompt == nil && music.currentTrack != nil
        }
        return !isOpenPanelShown && pairing.prompt == nil
            && model?.trackController.presentation == nil
            && model?.trackController.isChoosingFile != true && model?.isScreensaverEngaged != true
            && (model?.canControl ?? false)
    }

    var controlsMusic: Bool {
        playback.activeSource == .music || (mode == .music && model?.canControl != true)
    }

    var musicShortcutsAllowed: Bool {
        mode == .music && !isOpenPanelShown && pairing.prompt == nil
            && model?.trackController.isChoosingFile != true
    }

    var trackShortcutsAllowed: Bool {
        mode == .video && !isOpenPanelShown && model?.trackController.presentation == nil
            && model?.trackController.isChoosingFile != true
            && model?.isScreensaverEngaged != true
    }
}
