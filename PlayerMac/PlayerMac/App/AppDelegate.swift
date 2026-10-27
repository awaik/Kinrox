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
        remote.start()
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
        guard let url = urls.first(where: VideoFiles.isVideo) ?? urls.first else { return }
        receivedOpenRequest = true
        open(url)
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        guard !isRunningTests, !isTerminating else { return false }
        showPlayer()
        return playerWindow?.model.open(url: url) ?? false
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

    func openFile() {
        guard !isRunningTests, !isTerminating, openPanel == nil else { return }
        showPlayer()
        guard let window = playerWindow?.window else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("Open Video")
        panel.prompt = L10n.text("Open")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = VideoFiles.contentTypes
        openPanel = panel
        session.isOpenPanelShown = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            defer {
                self.openPanel = nil
                self.session.isOpenPanelShown = false
            }
            if response == .OK, let url = panel.url { self.open(url) }
        }
    }

    private func showPlayer() {
        guard !isTerminating else { return }
        if playerWindow == nil {
            do {
                playerWindow = try PlayerWindowController(
                    recents: session.recents, pairing: session.pairing, remote: session.remote,
                    actions: PlayerActions(
                        openFile: { [weak self] in self?.openFile() },
                        openRecent: { [weak self] item in self?.openRecent(item) },
                        open: { [weak self] url in self?.open(url) })
                ) { [weak self] model in
                    self?.playerWindow = nil
                    self?.session.model = nil
                    self?.session.remote?.windowClosed()
                    self?.close(model)
                }
                session.model = playerWindow?.model
                if let model = session.model {
                    let controller = NowPlayingController(center: SystemNowPlayingCenter())
                    controller.connect(to: model)
                    nowPlaying = controller
                }
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = L10n.text("Failed to start player")
                alert.runModal()
                return
            }
        }
        playerWindow?.showWindow(nil)
        playerWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close(_ model: PlayerViewModel) {
        nowPlaying?.disconnect()
        nowPlaying = nil
        let id = UUID()
        closingTasks[id] = Task { [weak self] in
            await model.shutdown()
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
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
