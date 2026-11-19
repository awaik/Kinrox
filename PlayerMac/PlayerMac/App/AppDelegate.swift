import AppKit
import RemoteProtocol
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = PlayerSession(
        recents: RecentFilesStore { NSDocumentController.shared.noteNewRecentDocumentURL($0) })
    private var playerWindow: PlayerWindowController?
    private var closingTasks: [UUID: Task<Void, Never>] = [:]
    private var openPanel: NSOpenPanel?
    private var isTerminating = false
    private var receivedOpenRequest = false
    private var nowPlaying: NowPlayingController?
    private var updater: SparkleUpdater?

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else { return }
        let remote = RemoteServer(recents: session.recents, pairing: session.pairing)
        session.remote = remote
        remote.onPairingRequested = { [weak self] in self?.showPlayer() }
        remote.openRecent = { [weak self] id in
            guard let self, !self.isTerminating,
                let item = self.session.recents.items.first(where: { $0.id == id })
            else { return .itemNotFound }
            return self.openRecent(item)
        }
        showPlayer()
        if ProcessInfo.processInfo.environment["KINROX_MUSIC_DEMO"] == "1" { session.mode = .music }
        session.spotify.restore()
        remote.start()
        updater = SparkleUpdater(center: session.updates)
        // Launch from terminal: Kinrox /full/path/to/video.mkv.
        if !receivedOpenRequest, let url = Self.launchURL(arguments: CommandLine.arguments) {
            open(url)
        }
    }

    static func launchURL(arguments: [String]) -> URL? {
        let options = arguments.dropFirst()
        // Do not guess foreign flag values: path comes first or after "--".
        let path: String?
        if let separator = options.firstIndex(of: "--") {
            path = options.suffix(from: options.index(after: separator)).first
        } else {
            path = options.first
        }
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        guard !isRunningTests else { return false }
        showPlayer()
        return true
    }

    /// "Open With", drag and drop onto Dock icon, and `open -a Kinrox file`.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !isRunningTests, !isTerminating else { return }
        guard !urls.isEmpty else { return }
        receivedOpenRequest = true
        openMedia(urls)
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        guard !isRunningTests, !isTerminating else { return false }
        showPlayer()
        session.mode = .video
        if LocalAudioFiles.isAudio(url) {
            return session.localAudio.play([url], using: session.mediaLibrary)
        }
        return playerWindow?.model.open(url: url) ?? false
    }

    private func openMedia(_ urls: [URL]) {
        guard
            let first = urls.first(where: { LocalAudioFiles.isAudio($0) || VideoFiles.isVideo($0) })
        else {
            if let url = urls.first { open(url) }
            return
        }
        if LocalAudioFiles.isAudio(first) {
            showPlayer()
            session.mode = .video
            session.localAudio.play(urls, using: session.mediaLibrary)
        } else {
            open(first)
        }
    }

    @discardableResult
    func openRecent(_ item: RecentItem) -> ProtocolError.Code? {
        guard !isRunningTests, !isTerminating else { return .internal }
        guard let url = session.recents.resolve(item) else {
            // Entry without file is removed upon open attempt.
            session.recents.remove(item.id)
            showPlayer()
            playerWindow?.model.errorMessage =
                L10n.format("File %@ was not found. It has been removed from recents.", item.title)
            return .itemNotFound
        }
        return open(url) ? nil : .internal
    }

    func clearRecents() {
        session.recents.clear()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    func openFile() { chooseFiles(folders: false) }

    private func chooseFiles(folders: Bool) {
        guard !isRunningTests, !isTerminating, openPanel == nil,
            session.model?.trackController.isChoosingFile != true
        else { return }
        showPlayer()
        guard let player = playerWindow?.window else { return }
        let window = folders ? player.attachedSheet ?? player : player
        guard window.attachedSheet == nil else { return }
        session.model?.trackController.presentation = nil
        let panel = NSOpenPanel()
        panel.title = folders ? L10n.text("Add Folder…") : L10n.text("Open File…")
        panel.prompt = folders ? L10n.text("Add") : L10n.text("Open")
        panel.canChooseDirectories = folders
        panel.canChooseFiles = !folders
        panel.allowsMultipleSelection = true
        if !folders {
            panel.allowedContentTypes = VideoFiles.contentTypes + LocalAudioFiles.contentTypes
        }
        openPanel = panel
        session.isOpenPanelShown = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            defer {
                self.openPanel = nil
                self.session.isOpenPanelShown = false
            }
            guard response == .OK else { return }
            if folders {
                self.session.mediaLibrary.addFolders(panel.urls)
            } else {
                self.openMedia(panel.urls)
            }
        }
    }

    private func showPlayer() {
        guard !isTerminating else { return }
        if playerWindow == nil {
            do {
                playerWindow = try PlayerWindowController(
                    session: session,
                    recents: session.recents, pairing: session.pairing, remote: session.remote,
                    updates: session.updates,
                    actions: PlayerActions(
                        openFile: { [weak self] in self?.openFile() },
                        openRecent: { [weak self] item in self?.openRecent(item) },
                        open: { [weak self] url in self?.open(url) },
                        openMedia: { [weak self] urls in self?.openMedia(urls) },
                        chooseFolders: { [weak self] in self?.chooseFiles(folders: true) },
                        addFolders: { [weak self] urls in
                            self?.session.mediaLibrary.addFolders(urls)
                        })
                ) { [weak self] model in
                    self?.playerWindow = nil
                    self?.session.model = nil
                    self?.session.remote?.windowClosed()
                    self?.close(model)
                }
                session.model = playerWindow?.model
                if session.model != nil {
                    let controller = NowPlayingController(center: SystemNowPlayingCenter())
                    session.playback.connectNowPlaying(controller)
                    nowPlaying = controller
                }
            } catch {
                FileHandle.standardError.write(Data("KINROX_PLAYER_FAILED: \(error)\n".utf8))
                let alert = NSAlert(error: error)
                alert.messageText = L10n.text("Failed to start player")
                alert.runModal()
                return
            }
        }
        playerWindow?.showWindow(nil)
        playerWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The release verifier requires this only after the real engine, render
        // context, and window have been created successfully.
        FileHandle.standardError.write(Data("KINROX_PLAYER_READY\n".utf8))
    }

    private func close(_ model: PlayerViewModel) {
        nowPlaying?.disconnect()
        nowPlaying = nil
        let closingPlayback = session.playback.beginClose()
        let id = UUID()
        closingTasks[id] = Task { [weak self] in
            await closingPlayback.value
            await model.shutdown()
            await self?.session.mediaLibrary.flushProgress()
            self?.closingTasks[id] = nil
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        session.remote?.stop()
        nowPlaying?.disconnect()
        openPanel?.cancel(nil)
        playerWindow?.close()
        let tasks = Array(closingTasks.values)
        Task {
            for task in tasks { await task.value }
            await session.soloist.cancel()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
