import AppKit
import Observation

/// Owns discovery and track commands, with libmpv as the selection source of truth.
@MainActor @Observable
final class TrackController {
    enum Presentation { case quick, browser, scope }
    typealias Scanner = @Sendable (URL, URL, Bool) -> AsyncStream<TrackScanUpdate>

    var presentation: Presentation?
    var selectedKind: MediaTrackKind = .audio
    private(set) var tracks: [MediaTrack] = []
    private(set) var files: [TrackFile] = []
    private(set) var video: URL?
    private(set) var mediaGeneration = UUID()
    private(set) var settings: TrackFolderSettings?
    private(set) var isReady = false
    private(set) var isScanning = false
    private(set) var foldersScanned = 0
    private(set) var unreadableFolders = 0
    var message: String?
    private(set) var filePanel: NSOpenPanel?
    var isChoosingFile: Bool { filePanel != nil }

    @ObservationIgnored private let engine: any PlayerEngine
    @ObservationIgnored private let preferences: TrackPreferences
    @ObservationIgnored private let scanner: Scanner
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = UUID()
    @ObservationIgnored private var requestCounter: UInt64 = 0
    @ObservationIgnored private var pending: [UInt64: Request] = [:]
    @ObservationIgnored private var manualKinds: Set<MediaTrackKind> = []
    @ObservationIgnored private var restoredKinds: Set<MediaTrackKind> = []
    @ObservationIgnored private var failedRestorations: Set<MediaTrackKind> = []
    @ObservationIgnored private var manualPreferences: [MediaTrackKind: TrackPreference] = [:]

    private struct Request {
        let kind: MediaTrackKind
        var file: TrackFile?
        var preference: TrackPreference?
        var completed = false
        var remember = false
    }

    init(
        engine: any PlayerEngine, preferences: TrackPreferences = TrackPreferences(),
        scanner: @escaping Scanner = TrackFileScanner.scan
    ) {
        self.engine = engine
        self.preferences = preferences
        self.scanner = scanner
    }

    deinit { scanTask?.cancel() }

    func prepare(for video: URL) {
        stop()
        mediaGeneration = UUID()
        presentation = nil
        self.video = video.standardizedFileURL.resolvingSymlinksInPath()
        settings = preferences.settings(for: video)
        files = []
        tracks = []
        message = nil
    }

    func loaded(path: String, tracks: [MediaTrack]) {
        guard video?.path == VideoFiles.key(URL(fileURLWithPath: path)) else { return }
        isReady = true
        self.tracks = tracks
        refresh()
        restorePreferences()
    }

    func update(_ tracks: [MediaTrack]) {
        guard isReady else { return }
        self.tracks = tracks
        resolveLoadedFiles()
        restorePreferences()
    }

    func stop() {
        cancelScan()
        let panel = filePanel
        filePanel = nil
        panel?.cancel(nil)
        for id in pending.keys { engine.cancelTrackCommand(id: id) }
        pending = [:]
        manualKinds = []
        restoredKinds = []
        failedRestorations = []
        manualPreferences = [:]
        isReady = false
        tracks = []
    }

    func close() {
        stop()
        presentation = nil
        video = nil
        files = []
    }

    func presentFilePanel(
        _ panel: NSOpenPanel, for window: NSWindow, selected: @escaping (URL) -> Void
    ) {
        guard isReady, filePanel == nil, window.attachedSheet == nil, window.sheetParent == nil
        else {
            return
        }
        let generation = mediaGeneration
        filePanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.filePanel === panel else { return }
            self.filePanel = nil
            guard response == .OK, let url = panel.url, self.isReady,
                self.mediaGeneration == generation
            else { return }
            selected(url)
        }
    }

    func refresh() {
        guard isReady, let video, let settings else { return }
        cancelScan()
        restoredKinds.subtract(failedRestorations)
        failedRestorations = []
        message = nil
        files = []
        foldersScanned = 0
        unreadableFolders = 0
        isScanning = true
        let generation = scanGeneration
        let stream = scanner(settings.root, video, settings.recursive)
        scanTask = Task { [weak self] in
            for await update in stream {
                guard let self, !Task.isCancelled, self.scanGeneration == generation else { return }
                self.files.append(contentsOf: update.files)
                self.files.sort {
                    $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
                }
                self.foldersScanned = update.folders
                self.unreadableFolders = update.unreadableFolders
            }
            guard let self, !Task.isCancelled, self.scanGeneration == generation else { return }
            self.isScanning = false
            self.restorePreferences()
        }
    }

    func cancelScan() {
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func applySettings(root: URL, recursive: Bool, remember: Bool) {
        guard var settings else { return }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let needsScan = settings.root != resolvedRoot || settings.recursive != recursive
        let enablingRemember = remember && !settings.remember
        settings.root = resolvedRoot
        settings.recursive = recursive
        settings.remember = remember
        if !remember {
            settings.audio = nil
            settings.subtitle = nil
        } else if enablingRemember {
            for (kind, preference) in manualPreferences { settings[kind] = preference }
        }
        self.settings = settings
        saveSettings()
        if needsScan { refresh() }
    }

    func setRemember(_ remember: Bool) {
        guard let settings else { return }
        applySettings(root: settings.root, recursive: settings.recursive, remember: remember)
    }

    func available(_ kind: MediaTrackKind) -> [MediaTrack] { tracks.filter { $0.kind == kind } }

    func matchingFiles(_ kind: MediaTrackKind) -> [TrackFile] {
        files.filter { $0.kind == kind && $0.matchesVideo && loadedTrack(for: $0) == nil }
    }

    func loadedTrack(for file: TrackFile) -> MediaTrack? {
        let matches = loadedTracks(for: file)
        return matches.first(where: \.isSelected) ?? matches.first(where: \.isDefault)
            ?? matches.first
    }

    private func loadedTracks(for file: TrackFile) -> [MediaTrack] {
        tracks.filter {
            $0.kind == file.kind
                && $0.externalURL.map(VideoFiles.key) == VideoFiles.key(file.url)
        }
    }

    func isPending(_ file: TrackFile) -> Bool { pending.values.contains { $0.file?.id == file.id } }

    func select(_ track: MediaTrack) {
        guard isReady, tracks.contains(where: { $0.id == track.id }) else { return }
        beginManual(track.kind)
        select(track, kind: track.kind, remember: true)
    }

    func disableSubtitles() {
        guard isReady else { return }
        beginManual(.subtitle)
        select(nil, kind: .subtitle, remember: true)
    }

    func select(_ file: TrackFile) {
        guard isReady, !isPending(file) else { return }
        if let track = loadedTrack(for: file) {
            select(track)
            return
        }
        beginManual(file.kind)
        add(file, remember: true)
    }

    func addFile(_ url: URL, kind: MediaTrackKind) {
        select(
            TrackFile(
                url: url.standardizedFileURL.resolvingSymlinksInPath(), kind: kind,
                relativePath: TrackFile.relativePath(url, root: settings?.root), matchesVideo: false
            ))
    }

    func cycle(_ kind: MediaTrackKind) {
        let items = available(kind)
        let external = matchingFiles(kind)
        guard !items.isEmpty || !external.isEmpty else { return }
        let next = (items.firstIndex(where: \.isSelected) ?? -1) + 1
        if next < items.count {
            select(items[next])
        } else if next < items.count + external.count {
            select(external[next - items.count])
        } else if kind == .subtitle {
            disableSubtitles()
        } else if let first = items.first {
            select(first)
        }
    }

    func completed(id: UInt64, error: String?) {
        guard var request = pending[id] else { return }
        if error != nil {
            pending[id] = nil
            if !request.remember { failedRestorations.insert(request.kind) }
            message =
                request.file.map {
                    L10n.format("Could not open track: %@", $0.url.lastPathComponent)
                }
                ?? L10n.text("Could not switch track.")
            if request.remember, presentation == nil { presentation = .quick }
            return
        }
        if request.file != nil {
            request.completed = true
            pending[id] = request
            resolveLoadedFiles()
        } else {
            pending[id] = nil
            if request.remember {
                manualPreferences[request.kind] = request.preference
                if settings?.remember == true {
                    settings?[request.kind] = request.preference
                    saveSettings()
                }
            }
        }
    }

    private func beginManual(_ kind: MediaTrackKind) {
        manualKinds.insert(kind)
        message = nil
        for (id, request) in pending where request.kind == kind {
            engine.cancelTrackCommand(id: id)
            pending[id] = nil
        }
    }

    private func nextRequest() -> UInt64 {
        requestCounter += 1
        return requestCounter
    }

    private func select(_ track: MediaTrack?, kind: MediaTrackKind, remember: Bool) {
        let id = nextRequest()
        let preference = track.map(TrackPreference.init) ?? TrackPreference(disabled: true)
        do {
            try engine.selectTrack(kind: kind, number: track?.number, requestID: id)
            pending[id] = Request(kind: kind, preference: preference, remember: remember)
        } catch {
            if !remember { failedRestorations.insert(kind) }
            message = L10n.text("Could not switch track.")
            if remember, presentation == nil { presentation = .quick }
        }
    }

    private func add(_ file: TrackFile, remember: Bool, preference: TrackPreference? = nil) {
        guard !isPending(file) else { return }
        let id = nextRequest()
        do {
            try engine.addTrack(url: file.url, kind: file.kind, requestID: id)
            pending[id] = Request(
                kind: file.kind, file: file, preference: preference, remember: remember)
        } catch {
            if !remember { failedRestorations.insert(file.kind) }
            message = L10n.format("Could not open track: %@", file.url.lastPathComponent)
            if remember, presentation == nil { presentation = .quick }
        }
    }

    private func resolveLoadedFiles() {
        for (id, request) in pending {
            guard request.completed, let file = request.file, let fallback = loadedTrack(for: file)
            else { continue }
            pending[id] = nil
            if let preference = request.preference {
                let matches = loadedTracks(for: file).filter(preference.matches)
                if matches.count == 1 {
                    select(matches[0], kind: request.kind, remember: false)
                } else {
                    failedRestorations.insert(request.kind)
                    message = L10n.text("Preferred track is unavailable. Using the default track.")
                }
            } else {
                select(fallback, kind: request.kind, remember: request.remember)
            }
        }
    }

    private func restorePreferences() {
        guard isReady, settings?.remember == true else { return }
        for kind in MediaTrackKind.allCases {
            guard !manualKinds.contains(kind), !restoredKinds.contains(kind),
                let preference = settings?[kind]
            else { continue }
            if preference.disabled, kind == .subtitle {
                restoredKinds.insert(kind)
                select(nil, kind: kind, remember: false)
                continue
            }
            let candidates = available(kind).filter(preference.matches)
            if candidates.count == 1 {
                restoredKinds.insert(kind)
                select(candidates[0], kind: kind, remember: false)
            } else if !isScanning {
                let candidates = files.filter { $0.kind == kind && preference.matches($0) }
                if candidates.count == 1 {
                    restoredKinds.insert(kind)
                    add(candidates[0], remember: false, preference: preference)
                } else {
                    message = L10n.text("Preferred track is unavailable. Using the default track.")
                }
            }
        }
    }

    private func saveSettings() {
        if let settings, let video { preferences.save(settings, for: video) }
    }
}
