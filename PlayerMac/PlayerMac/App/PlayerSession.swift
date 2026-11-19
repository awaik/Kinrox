import Foundation
import MetaBrainzAPI
import Observation
import SpotifyWebAPI

enum AppMode { case video, music }

/// Shared application state upon which menus and player window depend.
@MainActor @Observable
final class PlayerSession {
    var mode = AppMode.video {
        didSet {
            music.setWorkspaceActive(mode == .music && model != nil)
            remote?.modeChanged()
        }
    }
    let music: MusicViewModel
    let localAudio: LocalAudioViewModel
    let mediaLibrary: MediaLibraryStore
    let musicBrainzLimiter: MusicBrainzRateLimiter
    var homeSection = HomeSection.overview
    var homeSelectedSeries: String?
    var homeSelectedAlbum: String?
    var homeFilter = HomeFilterState()
    var isHomeSearchFocused = false
    var isHomeSearchShown = false
    var isLibrarySheetShown = false
    var searchFocusRequest = 0
    let spotify = SpotifyAccount()
    let soloist = SoloistSetup()
    let playback = PlaybackCoordinator()

    func selectHome() {
        if mode != .video { mode = .video }
        if model?.isShowingHome == false { model?.showHome() }
    }

    var model: PlayerViewModel? {
        didSet {
            remote?.connect(to: model)
            if let model {
                playback.connect(video: model, music: music, localAudio: localAudio)
                model.writeWatchProgress = { [weak self] in self?.mediaLibrary.record($0) }
            } else {
                isHomeSearchFocused = false
                isHomeSearchShown = false
                isLibrarySheetShown = false
            }
        }
    }
    var remote: RemoteServer? {
        didSet {
            if let model { remote?.connect(to: model) }
            remote?.connectLocalAudio(
                localAudio,
                isActive: { [weak self] in
                    guard let self else { return false }
                    return self.playback.activeSource == .localAudio
                        || (self.playback.activeSource != .music && self.mode == .video
                            && self.model?.canControl != true)
                })
            remote?.connectMusic(
                music, coordinator: playback,
                isActive: { [weak self] in
                    guard let self else { return false }
                    return self.mode == .music && self.model?.canControl != true
                        && self.localAudio.currentTrack == nil
                })
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
        let limiter = MusicBrainzRateLimiter()
        musicBrainzLimiter = limiter
        mediaLibrary = MediaLibraryStore(limiter: limiter)
        localAudio = LocalAudioViewModel(artwork: mediaLibrary.artwork)
        music = MusicViewModel(
            store: demoMusic ? DemoMusicLibraryStore() : DisconnectedMusicLibraryStore(),
            defaults: musicDefaults, workspaceActive: false)
        music.setWorkspaceActive(mode == .music)
        spotify.onInteractiveConnection = { [weak self] in
            guard let self, !demoMusic else { return }
            (self.music.store as? SpotifyLibraryStore)?.retire()
            self.music.replaceStore(DisconnectedMusicLibraryStore())
            self.music.engineFactory = nil
            self.music.acceptsPlayback = false
        }
        spotify.onRestore = { [weak self] client, binding, cache in
            guard let self, !demoMusic else { return }
            let store = SpotifyLibraryStore(
                client: client, cache: cache, connected: false,
                musicBrainzLimiter: self.musicBrainzLimiter)
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
                store = SpotifyLibraryStore(
                    client: client, profile: profile, cache: cache,
                    musicBrainzLimiter: self.musicBrainzLimiter)
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
        playback.connect(video: nil, music: music, localAudio: localAudio)
        if !demoMusic { configureSoloist() }
    }

    var isOnHome: Bool {
        mode == .video && (model?.isShowingHome == true || model?.hasMedia != true)
            && model?.isLoading != true && model?.isScreensaverEngaged != true
    }

    var activeControlTarget: PlaybackCoordinator.Source {
        if mode == .music { return .music }
        if model?.hasMedia == true, model?.isShowingHome == false { return .video }
        if localAudio.currentTrack != nil,
            playback.activeSource == .localAudio
                || (playback.activeSource != .music && model?.canControl != true)
        {
            return .localAudio
        }
        if playback.activeSource == .music { return .music }
        return .video
    }

    var unmodifiedShortcutsAllowed: Bool {
        !isOpenPanelShown && !isHomeSearchFocused && !isLibrarySheetShown && pairing.prompt == nil
            && model?.isShowingConnectPhone != true && model?.trackController.presentation == nil
            && model?.trackController.isChoosingFile != true && model?.isScreensaverEngaged != true
    }

    var canControl: Bool {
        guard unmodifiedShortcutsAllowed else { return false }
        switch activeControlTarget {
        case .music: return music.currentTrack != nil
        case .localAudio: return localAudio.currentTrack != nil
        case .video: return model?.canControl == true
        }
    }

    var controlsMusic: Bool { activeControlTarget == .music }
    var controlsLocalAudio: Bool { activeControlTarget == .localAudio }

    var musicShortcutsAllowed: Bool { mode == .music && unmodifiedShortcutsAllowed }
    var trackShortcutsAllowed: Bool { mode == .video && unmodifiedShortcutsAllowed }

    func focusHomeSearch() {
        guard isOnHome else { return }
        isHomeSearchShown = true
        searchFocusRequest += 1
    }

    func leaveHomeSearch() {
        homeFilter.query = ""
        isHomeSearchFocused = false
        isHomeSearchShown = false
    }

    var videoNavigationAllowed: Bool {
        mode == .video && unmodifiedShortcutsAllowed && pairing.prompt == nil
            && model?.trackController.presentation == nil
            && model?.trackController.isChoosingFile != true
            && model?.isScreensaverEngaged != true
            && model?.hasMedia == true
    }

    var videoCloseAllowed: Bool {
        videoNavigationAllowed
    }
}
