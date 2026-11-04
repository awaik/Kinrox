import Foundation
import Observation
import SpotifyWebAPI

/// Explicit native setup. Construction does not read a key, download or start an audio process.
@MainActor @Observable
final class SoloistSetup {
    private(set) var availability = MusicEngineAvailability.notInstalled
    private(set) var deviceName = ""
    private(set) var busy = false
    private(set) var configured = false
    private(set) var installation: SoloistInstallation?
    private(set) var hasKey = false
    var canRecoverPlayback: Bool {
        hasKey && installation != nil && paths?.paired == true && hostRequirement != nil
    }
    var showsKeyFields: Bool {
        switch availability {
        case .needsKey, .notInstalled: true
        case .failed: !hasKey || installation == nil
        default: false
        }
    }
    var onAvailability: ((MusicEngineAvailability) -> Void)?
    var onReady: (() async -> Void)?
    var beforeChange: (() async -> Void)?
    private let keys: any SpotifyCredentialStore
    private let storage: SoloistAccountStorage
    private let installer = SoloistInstaller()
    private let engines: URL
    private let defaults: UserDefaults
    private var binding: String?
    private var paths: SoloistAccountPaths?
    private var client: SpotifyClient?
    private var task: Task<Void, Never>?
    private var pairing: SoloistPairing?
    private var generation = UUID()
    private var hostRequirement: String?
    private static let installationPreference = "app.kinrox.spotify.soloist.installation"
    private static let bindingPreference = "app.kinrox.spotify.soloist.binding"
    private static let volumePreference = "app.kinrox.spotify.soloist.volume"
    static let keyService = "app.kinrox.spotify.soloist-key"

    init(
        keys: (any SpotifyCredentialStore)? = nil, defaults: UserDefaults = .standard,
        support: URL? = nil, caches: URL? = nil
    ) {
        self.keys = keys ?? KeychainSpotifyCredentialStore(service: Self.keyService)
        self.defaults = defaults
        let support =
            support
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(
                "Kinrox")
        let caches =
            caches
            ?? FileManager.default.urls(
                for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Kinrox")
        engines = support.appendingPathComponent("Engines/Soloist")
        storage = SoloistAccountStorage(
            support: support.appendingPathComponent("Soloist"),
            caches: caches.appendingPathComponent("Soloist"))
    }

    func configure(client: SpotifyClient, clientID: String, userID: String) async {
        await cancel()
        let attempt = UUID()
        generation = attempt
        let binding = SoloistAccountStorage.binding(clientID: clientID, userID: userID)
        busy = true
        defer { if generation == attempt { busy = false } }
        do {
            await beforeChange?()
            guard generation == attempt else { return }
            if let previous = self.binding ?? defaults.string(forKey: Self.bindingPreference),
                previous != binding
            {
                try keys.remove(clientID: previous)
                try await storage.disconnect(binding: previous)
                guard generation == attempt else { return }
            }
            hasKey = false
            self.binding = binding
            self.client = client
            paths = nil
            deviceName = "Kinrox · " + UUID().uuidString.prefix(8)
            configured = true
            let paths = try await storage.prepare(binding: binding)
            guard generation == attempt else { return }
            self.paths = paths
            defaults.set(binding, forKey: Self.bindingPreference)
            let app = Bundle.main.bundleURL
            let identifier = (Bundle.main.bundleIdentifier ?? "app.kinrox.player")
                .replacingOccurrences(of: ".player", with: ".soloist-host")
            hostRequirement = try await Task.detached {
                try SoloistProcessSupervisor.hostRequirement(appURL: app, identifier: identifier)
            }.value
            guard generation == attempt else { return }
            if let data = defaults.data(forKey: Self.installationPreference),
                let value = try? JSONDecoder().decode(SoloistInstallation.self, from: data),
                value.binary.standardizedFileURL.path.hasPrefix(
                    engines.standardizedFileURL.path + "/"),
                FileManager.default.fileExists(atPath: value.binary.path)
            {
                installation = value
            }
            hasKey = try keys.refreshToken(clientID: binding) != nil
            if !hasKey {
                change(.needsKey)
            } else if let installation {
                if installation.expiryDate <= Date() {
                    change(.expired)
                } else if paths.paired {
                    change(.ready)
                    await onReady?()
                } else {
                    change(.needsPairing)
                }
            } else {
                change(.notInstalled)
            }
        } catch {
            guard generation == attempt else { return }
            change(.failed(L10n.text("Could not prepare Soloist. Check Settings.")))
        }
    }

    func saveKeyAndInstall(_ key: String) {
        guard let binding, !busy else { return }
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 16_384 else {
            change(.needsKey)
            return
        }
        do { try keys.save(value, clientID: binding) } catch {
            change(.failed(L10n.text("Could not save the Soloist key in Keychain.")))
            return
        }
        if SpotifyDocuments.bundled != nil {
            defaults.set(SpotifyDocuments.currentVersion, forKey: SpotifyAccount.consentPreference)
        }
        hasKey = true
        if let installation, installation.expiryDate > Date() {
            begin { attempt in
                await self.beforeChange?()
                guard self.generation == attempt else { throw CancellationError() }
                if self.paths?.paired == true {
                    self.change(.ready)
                    await self.onReady?()
                } else {
                    self.change(.needsPairing)
                }
            }
        } else {
            install()
        }
    }

    func install() {
        guard configured, !busy else { return }
        begin { attempt in
            await self.beforeChange?()
            guard self.generation == attempt else { throw CancellationError() }
            self.change(.downloading)
            let value = try await self.installer.install(in: self.engines)
            guard self.generation == attempt else { throw CancellationError() }
            self.installation = value
            self.defaults.set(
                try JSONEncoder().encode(value), forKey: Self.installationPreference)
            if self.paths?.paired == true {
                self.change(.ready)
                await self.onReady?()
            } else {
                self.change(.needsPairing)
            }
        }
    }

    func pair(replaceSession: Bool = true) {
        guard !busy, let binding, let client else { return }
        begin { attempt in
            await self.beforeChange?()
            guard self.generation == attempt else { throw CancellationError() }
            try await self.storage.setPaired(false, binding: binding)
            self.paths = try await self.storage.prepare(binding: binding)
            let driver = try self.driver()
            let pairing = SoloistPairing(driver: driver)
            self.pairing = pairing
            self.change(.needsPairing)
            let name = self.deviceName
            try await pairing.connect(replaceSession: replaceSession) {
                try await client.devices().filter { $0.name == name }.count == 1
            }
            guard self.generation == attempt else { throw CancellationError() }
            try await self.storage.setPaired(true, binding: binding)
            self.paths = try await self.storage.prepare(binding: binding)
            self.change(.ready)
            await self.onReady?()
        }
    }

    func makeEngine() throws -> SoloistMusicEngine {
        guard availability == .ready else { throw SoloistFailure.unavailable }
        guard let installation, installation.expiryDate > Date() else {
            change(.expired)
            throw SoloistFailure.unavailable
        }
        let initialVolume: Double
        if defaults.object(forKey: Self.volumePreference) != nil {
            initialVolume = min(100, max(0, defaults.double(forKey: Self.volumePreference)))
        } else {
            let isTesting =
                ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || NSClassFromString("XCTestCase") != nil
            initialVolume = isTesting ? 0 : 100
        }
        return SoloistMusicEngine(
            runtime: SoloistRuntime(
                driver: try driver(), initialVolume: initialVolume,
                onVolumeChange: { [weak self] value in
                    self?.defaults.set(value, forKey: Self.volumePreference)
                }))
    }

    func observeRuntime(_ value: MusicEngineAvailability) { availability = value }

    func recover(then action: @escaping @MainActor () -> Void = {}) {
        guard !busy, canRecoverPlayback else { return }
        begin { attempt in
            await self.beforeChange?()
            guard self.generation == attempt else { throw CancellationError() }
            guard let installation = self.installation, installation.expiryDate > Date() else {
                self.change(.expired)
                return
            }
            self.change(.ready)
            await self.onReady?()
            guard self.generation == attempt else { throw CancellationError() }
            action()
        }
    }

    func cancel() async {
        let attempt = UUID()
        generation = attempt
        let pending = task
        let pairing = pairing
        pending?.cancel()
        await pairing?.cancel()
        await pending?.value
        guard generation == attempt else { return }
        task = nil
        self.pairing = nil
        busy = false
        if configured, availability != .needsKey {
            if let installation {
                change(
                    installation.expiryDate <= Date()
                        ? .expired : paths?.paired == true ? .ready : .needsPairing)
            } else {
                change(.notInstalled)
            }
        }
    }

    /// Called only after the coordinator and music engine have completed shutdown.
    func disconnect() async throws {
        await cancel()
        if let binding {
            try keys.remove(clientID: binding)
            try await storage.disconnect(binding: binding)
        }
        defaults.removeObject(forKey: Self.bindingPreference)
        paths = nil
        binding = nil
        client = nil
        configured = false
        hasKey = false
        change(.needsKey)
    }

    private func driver() throws -> SoloistProcessSupervisor {
        guard let installation, let paths, let binding, let hostRequirement else {
            throw SoloistFailure.unavailable
        }
        let keys = keys
        return SoloistProcessSupervisor(
            config: .init(
                installation: installation, profile: paths.profile, cache: paths.cache,
                reaper: Bundle.main.bundleURL.appendingPathComponent(
                    "Contents/Helpers/KinroxSoloistHost"),
                hostRequirement: hostRequirement, deviceName: deviceName,
                key: {
                    guard let key = try await keys.refreshTokenAsync(clientID: binding) else {
                        throw SoloistFailure.unavailable
                    }
                    return key
                }))
    }

    private func change(_ value: MusicEngineAvailability) {
        availability = value
        onAvailability?(value)
    }

    private func begin(_ operation: @escaping @MainActor (UUID) async throws -> Void) {
        let attempt = UUID()
        generation = attempt
        busy = true
        task = Task {
            defer {
                if self.generation == attempt {
                    self.busy = false
                    self.pairing = nil
                }
            }
            do { try await operation(attempt) } catch is CancellationError {} catch {
                guard self.generation == attempt else { return }
                self.change(
                    .failed(
                        error as? SoloistFailure == .accountMismatch
                            ? L10n.text("A different Spotify account is paired. Pair again.")
                            : L10n.text("Could not start Soloist. Check Settings.")))
            }
        }
    }
}
