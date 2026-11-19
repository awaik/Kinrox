import Foundation
import MetaBrainzAPI
import OSLog
import Observation

@MainActor @Observable
final class MediaLibraryStore {
    static let autoWatchKey = "mediaLibrary.autoWatchFolders"
    static let enrichKey = "mediaLibrary.enrichMetadata"
    static let logger = Logger(subsystem: "app.kinrox.player", category: "MediaLibrary")

    var snapshot = MediaLibraryDatabase.Snapshot()
    private(set) var states: [UUID: FolderScanState] = [:]
    private(set) var focusedFolder: UUID?
    private(set) var autoWatchFolders: Bool
    private(set) var enrichMetadata: Bool
    private(set) var storageFailed = false

    let database: MediaLibraryDatabase
    let artwork: ArtworkCache
    let videoClient: OpenVideoMetadataClient
    let musicClient: MetaBrainzClient
    private let defaults: UserDefaults
    private var watcher: MediaFolderWatcher?
    @ObservationIgnored private var preferences: DefaultsObserver?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var pendingScan = false
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored var enrichmentTask: Task<Void, Never>?
    @ObservationIgnored var pendingEnrichment = false
    @ObservationIgnored private var progressWrites: Task<Void, Never>?
    @ObservationIgnored var enrichmentGeneration = UUID()

    init(
        limiter: MusicBrainzRateLimiter,
        defaults: UserDefaults? = nil, storage: (data: URL, cache: URL)? = nil,
        videoClient: OpenVideoMetadataClient = OpenVideoMetadataClient(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let smokeTest = environment["KINROX_RELEASE_SMOKE_TEST"] == "1"
        let isolated = smokeTest || environment["XCTestConfigurationFilePath"] != nil
        let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KinroxLibrary-\(UUID())")
        let locations =
            storage
            ?? Self.storage(smokeTest ? [:] : environment, testRoot: isolated ? testRoot : nil)
        database = MediaLibraryDatabase(
            location: locations.data.appendingPathComponent("media-library.sqlite"))
        artwork = ArtworkCache(
            directory: locations.cache.appendingPathComponent("MediaLibrary/Artwork"))
        self.videoClient = videoClient
        musicClient = MetaBrainzClient(
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                ?? "development",
            limiter: limiter)
        let defaults =
            defaults
            ?? (isolated ? UserDefaults(suiteName: testRoot.lastPathComponent)! : .standard)
        self.defaults = defaults
        autoWatchFolders = defaults.object(forKey: Self.autoWatchKey) as? Bool ?? true
        enrichMetadata = defaults.object(forKey: Self.enrichKey) as? Bool ?? true
        if !smokeTest {
            watcher = MediaFolderWatcher { [weak self] in
                guard let self, self.autoWatchFolders else { return }
                self.rescanAll()
            }
        }
        preferences = DefaultsObserver(defaults: defaults) { [weak self] in
            Task { @MainActor in self?.preferencesChanged() }
        }
        if !isolated {
            if autoWatchFolders {
                rescanAll()
            } else {
                Task { [weak self] in
                    do { try await self?.reload() } catch { self?.reportStorageError(error) }
                }
            }
        }
    }

    var folders: [WatchedFolder] { snapshot.folders }

    func setAutoWatchFolders(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.autoWatchKey)
        preferencesChanged()
    }

    func setEnrichMetadata(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enrichKey)
        preferencesChanged()
    }

    private func preferencesChanged() {
        let active = defaults.object(forKey: Self.autoWatchKey) as? Bool ?? true
        let enrich = defaults.object(forKey: Self.enrichKey) as? Bool ?? true
        if active != autoWatchFolders {
            autoWatchFolders = active
            if active { rescanAll() }
            updateWatcher()
        }
        if enrich != enrichMetadata {
            enrichMetadata = enrich
            stopEnrichment()
            if enrich { scheduleEnrichment(refresh: false) }
        }
    }

    func addFolders(_ urls: [URL]) {
        Task { [weak self] in
            guard let self else { return }
            let folders = await Task.detached(priority: .utility) {
                urls.compactMap { MediaFolderScanner.folder($0) }
            }.value
            do {
                for folder in folders { self.focusedFolder = try await self.database.add(folder) }
                try await self.reload()
                self.rescanAll()
            } catch { self.reportStorageError(error) }
        }
    }

    func removeFolder(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.database.remove(id)
                if self.focusedFolder == id { self.focusedFolder = nil }
                self.stopEnrichment()
                try await self.reload()
                self.rescanAll()
            } catch { self.reportStorageError(error) }
        }
    }

    func rescanAll(refreshMetadata: Bool = false) {
        pendingScan = true
        pendingRefresh = pendingRefresh || refreshMetadata
        guard scanTask == nil else { return }
        scanTask = Task { [weak self] in await self?.runScans() }
    }

    private func runScans() async {
        defer { scanTask = nil }
        while pendingScan {
            pendingScan = false
            let refresh = pendingRefresh
            pendingRefresh = false
            do {
                try await reload()
                for folder in folders { await scan(folder) }
                try await reload()
                scheduleEnrichment(refresh: refresh)
            } catch { reportStorageError(error) }
        }
    }

    private func scan(_ folder: WatchedFolder) async {
        states[folder.id] = .scanning(0)
        let database = database
        let artwork = artwork
        do {
            let result = try await Task.detached(priority: .utility) { [weak self] in
                try await MediaFolderScanner.scan(folder, database: database, artwork: artwork) {
                    [weak self] count in
                    await self?.updateScan(folder.id, count: count)
                }
            }.value
            states[folder.id] =
                switch result {
                case .ready: .ready
                case .offline: .offline
                case .incomplete: .failed
                }
        } catch {
            states[folder.id] = .failed
            if (try? await database.folders().contains(where: { $0.id == folder.id })) == true {
                Self.logger.error(
                    "Folder scan failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func updateScan(_ folder: UUID, count: Int) {
        if states[folder] != .scanning(count) { states[folder] = .scanning(count) }
    }

    func reload() async throws {
        var next = try await database.snapshot()
        for (path, progress) in snapshot.progress
        where progress.updated > (next.progress[path]?.updated ?? .distantPast) {
            next.progress[path] = progress
        }
        snapshot = next
        let ids = Set(folders.map(\.id))
        states = states.filter { ids.contains($0.key) }
        updateWatcher()
        storageFailed = false
    }

    private func updateWatcher() {
        watcher?.watch(autoWatchFolders ? folders : [])
    }

    func record(_ progress: WatchProgress) {
        snapshot.progress[progress.path] = progress
        let database = database
        let previous = progressWrites
        progressWrites = Task { [weak self] in
            await previous?.value
            do { try await database.save(progress) } catch { self?.reportStorageError(error) }
        }
    }

    func flushProgress() async { await progressWrites?.value }

    private func reportStorageError(_ error: Error) {
        storageFailed = true
        Self.logger.error(
            "Library storage failed: \(error.localizedDescription, privacy: .private)")
    }

    private static func storage(
        _ environment: [String: String], testRoot: URL?
    ) -> (data: URL, cache: URL) {
        let files = FileManager.default
        let data = environment["KINROX_DATA_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let cache = environment["KINROX_CACHE_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        return (
            data ?? testRoot
                ?? files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Kinrox"),
            cache ?? testRoot
                ?? files.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Kinrox")
        )
    }
}

private final class DefaultsObserver {
    let token: any NSObjectProtocol
    init(defaults: UserDefaults, change: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in change() }
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}
