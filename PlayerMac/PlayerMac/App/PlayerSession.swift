import Foundation
import Observation
import SpotifyWebAPI

enum AppMode { case video, music }

/// Shared application state upon which menus and player window depend.
@MainActor @Observable
final class PlayerSession {
    var mode = AppMode.video { didSet { remote?.modeChanged() } }
    let music: MusicViewModel
    let spotify = SpotifyAccount()
    let soloist = SoloistSetup()
    let playback = PlaybackCoordinator()
    var model: PlayerViewModel? {
        didSet {
            remote?.connect(to: model)
            if model != nil { playback.connect(video: model, music: music) }
        }
    }
    var remote: RemoteServer? {
        didSet {
            if let model { remote?.connect(to: model) }
            remote?.connectMusic(
                music, coordinator: playback,
                isActive: { [weak self] in self?.controlsMusic == true })
        }
    }
    /// While file open panel is displayed, unmodified keys belong to it.
    var isOpenPanelShown = false
    let recents: RecentFilesStore
    let pairing = PairingCenter()
    let updates = UpdateCenter()

    init(
        recents: RecentFilesStore,
        demoMusic: Bool = ProcessInfo.processInfo.environment["KINROX_MUSIC_DEMO"] == "1",
        musicDefaults: UserDefaults? =
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            ? .standard : nil
    ) {
        self.recents = recents
        music = MusicViewModel(
            store: demoMusic ? DemoMusicLibraryStore() : DisconnectedMusicLibraryStore(),
            defaults: musicDefaults)
        spotify.onInteractiveConnection = { [weak self] in
            guard let self, !demoMusic else { return }
            (self.music.store as? SpotifyLibraryStore)?.retire()
            self.music.replaceStore(DisconnectedMusicLibraryStore())
            self.music.engineFactory = nil
            self.music.acceptsPlayback = false
        }
        spotify.onRestore = { [weak self] client, binding, cache in
            guard let self, !demoMusic else { return }
            let store = SpotifyLibraryStore(client: client, cache: cache, connected: false)
            self.excludeLegacyQueue(from: store, clientID: binding.clientID, userID: binding.userID)
            self.music.replaceStore(store, accountName: binding.accountName)
            self.music.acceptsPlayback = false
            await store.restore()
        }
        spotify.onRestoreFailed = { [weak self] message in
            guard let self, !demoMusic else { return }
            self.music.acceptsPlayback = false
            self.music.statusMessage = message
            self.music.retryPlayback = { [weak self] in self?.spotify.restore() }
            self.music.notifyPlayback()
        }
        spotify.onConnected = { [weak self] client, profile, cache in
            guard let self, !demoMusic else { return }
            let store: SpotifyLibraryStore
            if let restored = self.music.store as? SpotifyLibraryStore,
                restored.client === client, restored.library.userID == profile.id
            {
                store = restored
                store.isConnected = true
            } else {
                (self.music.store as? SpotifyLibraryStore)?.retire()
                store = SpotifyLibraryStore(client: client, profile: profile, cache: cache)
                self.excludeLegacyQueue(
                    from: store, clientID: self.spotify.clientID, userID: profile.id)
                self.music.replaceStore(store, accountName: self.spotify.accountName)
                await store.restore()
            }
            guard !store.isClosed else { return }
            let clientID = self.spotify.clientID
            let userID = self.spotify.userID ?? ""
            self.music.accountName = self.spotify.accountName
            self.music.acceptsPlayback = false
            await self.soloist.configure(client: client, clientID: clientID, userID: userID)
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
            try await self.soloist.disconnect()
            self.music.syncTask?.cancel()
            self.music.browsingTask?.cancel()
            (self.music.store as? SpotifyLibraryStore)?.retire()
        }
        playback.connect(video: nil, music: music)
        if !demoMusic { configureSoloist() }
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

    var videoNavigationAllowed: Bool {
        mode == .video && !isOpenPanelShown && pairing.prompt == nil
            && model?.trackController.presentation == nil
            && model?.trackController.isChoosingFile != true
            && model?.isScreensaverEngaged != true
            && model?.hasMedia == true
    }

    var videoCloseAllowed: Bool {
        videoNavigationAllowed
    }
}
