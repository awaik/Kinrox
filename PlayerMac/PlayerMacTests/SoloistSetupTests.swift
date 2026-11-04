import Foundation
import SpotifyWebAPI
import Testing

@testable import Kinrox

@Suite("Soloist setup account lifecycle")
@MainActor
struct SoloistSetupTests {
    @Test func runtimeFailuresKeepCompletedSetupAndOfferInlineRecovery() async throws {
        let fixture = try Fixture()
        try await fixture.prepare("first")
        await fixture.configure("first")
        let model = MusicViewModel()
        model.accountName = "Fixture"
        for availability: MusicEngineAvailability in [
            .starting, .reconnecting, .externalTakeover, .failed("Soloist playback stopped."),
        ] {
            fixture.setup.observeRuntime(availability)
            #expect(!fixture.setup.showsKeyFields)
            #expect(fixture.setup.canRecoverPlayback)
            model.engineAvailability = availability
            model.engineNeedsSetup = !fixture.setup.canRecoverPlayback
            #expect(!MusicServiceStatus(model: model).needsSettings(availability.message ?? ""))
        }
        await fixture.configure("second")
        #expect(fixture.setup.showsKeyFields)
        #expect(!fixture.setup.canRecoverPlayback)
        fixture.setup.observeRuntime(.failed("Setup failed"))
        #expect(fixture.setup.showsKeyFields)
        model.engineAvailability = fixture.setup.availability
        model.engineNeedsSetup = !fixture.setup.canRecoverPlayback
        #expect(MusicServiceStatus(model: model).needsSettings("Setup failed"))
        for availability: MusicEngineAvailability in [
            .needsKey, .needsPairing, .notInstalled, .expired,
        ] {
            model.engineAvailability = availability
            model.engineNeedsSetup = false
            #expect(MusicServiceStatus(model: model).needsSettings(availability.message ?? ""))
            model.isRefreshing = true
            #expect(MusicServiceStatus(model: model).showsAction)
            model.isRefreshing = false
        }
        let disconnected = MusicViewModel(store: DisconnectedMusicLibraryStore())
        #expect(disconnected.playbackStatusMessage == L10n.text("Connect Spotify in Settings."))
        #expect(!disconnected.acceptsPlayback)
        #expect(MusicServiceStatus(model: disconnected).showsAction)
    }

    @Test func initialVolumeRestoresOnLoadAndPersistsVolumeUpdates() async throws {
        let driver = FakeSoloistDriver()
        var persisted: Double?
        let runtime = SoloistRuntime(
            driver: driver, initialVolume: 85,
            onVolumeChange: { value in persisted = value })
        let uri = "spotify:track:" + String(repeating: "A", count: 22)
        try await runtime.perform(.load(uri: uri, occurrenceID: UUID(), position: 0))
        #expect(await runtime.confirmedSnapshot().volume == 85)
        try await runtime.perform(.volume(45))
        #expect(persisted == 45)
        #expect(await runtime.confirmedSnapshot().volume == 45)
        await runtime.shutdown()
    }

    @Test func constructionIsInertAndCancelPreservesCompletedPairing() async throws {
        let fixture = try Fixture()
        #expect(fixture.keys.reads == 0)
        var ready = 0
        fixture.setup.onReady = { ready += 1 }
        try await fixture.prepare("first")
        await fixture.configure("first")
        #expect(fixture.setup.availability == .ready && ready == 1)
        await fixture.setup.cancel()
        #expect(fixture.setup.availability == .ready)
        #expect(ready == 1)
    }

    @Test func changingAccountStopsPlaybackBeforeRemovingItsOwnedCredentialsAndData() async throws {
        let fixture = try Fixture()
        let first = try await fixture.prepare("first")
        await fixture.configure("first")
        var settled = false
        fixture.setup.beforeChange = {
            #expect(FileManager.default.fileExists(atPath: first.profile.path))
            #expect(fixture.keys.values[first.binding] != nil)
            settled = true
        }
        await fixture.configure("second")
        #expect(settled)
        #expect(fixture.keys.values[first.binding] == nil)
        #expect(!FileManager.default.fileExists(atPath: first.profile.path))
        #expect(!FileManager.default.fileExists(atPath: first.cache.path))
        #expect(fixture.setup.availability == .needsKey)
    }

    @Test func failedDisconnectRetainsBindingForRetryAndDoesNotEraseInstallation() async throws {
        let fixture = try Fixture()
        let first = try await fixture.prepare("first")
        await fixture.configure("first")
        fixture.keys.failRemoval = true
        await #expect(throws: SoloistFailure.self) { try await fixture.setup.disconnect() }
        #expect(fixture.setup.configured)
        #expect(FileManager.default.fileExists(atPath: first.profile.path))
        fixture.keys.failRemoval = false
        try await fixture.setup.disconnect()
        try await fixture.setup.disconnect()
        #expect(!fixture.setup.configured && fixture.setup.availability == .needsKey)
        #expect(!FileManager.default.fileExists(atPath: first.profile.path))
        #expect(FileManager.default.fileExists(atPath: fixture.binary.path))
    }

    @MainActor private struct Fixture {
        let root: URL
        let binary: URL
        let keys = SetupKeys()
        let setup: SoloistSetup
        let storage: SoloistAccountStorage
        let client = SpotifyClient { _ in throw SoloistFailure.unavailable }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let support = root.appendingPathComponent("support")
            let caches = root.appendingPathComponent("caches")
            binary = support.appendingPathComponent("Engines/Soloist/fixture/soloist")
            try SoloistInstaller.privateDirectory(binary.deletingLastPathComponent())
            try Data("not executable".utf8).write(to: binary)
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            let installation = SoloistInstallation(
                binary: binary, digest: "fixture", version: "fixture", buildDate: Date())
            defaults.set(
                try JSONEncoder().encode(installation),
                forKey: "app.kinrox.spotify.soloist.installation")
            storage = SoloistAccountStorage(
                support: support.appendingPathComponent("Soloist"),
                caches: caches.appendingPathComponent("Soloist"))
            setup = SoloistSetup(keys: keys, defaults: defaults, support: support, caches: caches)
        }

        @discardableResult func prepare(_ user: String) async throws -> SoloistAccountPaths {
            let binding = SoloistAccountStorage.binding(clientID: "client", userID: user)
            let paths = try await storage.prepare(binding: binding)
            try await storage.setPaired(true, binding: binding)
            keys.values[binding] = "synthetic-key"
            return paths
        }

        func configure(_ user: String) async {
            await setup.configure(client: client, clientID: "client", userID: user)
        }
    }
}

@MainActor
private final class SetupKeys: SpotifyCredentialStore {
    var values: [String: String] = [:]
    var reads = 0
    var failRemoval = false
    func refreshToken(clientID: String) throws -> String? {
        reads += 1
        return values[clientID]
    }
    func save(_ token: String, clientID: String) throws { values[clientID] = token }
    func remove(clientID: String) throws {
        if failRemoval { throw SoloistFailure.installation }
        values.removeValue(forKey: clientID)
    }
}
