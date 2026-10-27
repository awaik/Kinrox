import Foundation
import RemoteProtocol
import RemoteTransport
import Security
import Testing

@testable import RemoteiOS

@Suite(
    "Real Bonjour, TransportClient, and Keychain on iOS", .serialized,
    .enabled(
        if: supportsListener,
        "Network.framework listener inside Simulator drops self-connect; run on iPhone"))
@MainActor struct RemoteIntegrationTests {
    @Test("PIN -> Keychain -> new client without PIN -> revoke -> forget")
    func livePairingAndPersistence() async throws {
        let serverId = UUID()
        let service = "app.kinrox.remote.tests.\(UUID())"
        let store = KeychainServerStore(service: service)
        let preferences = RemotePreferences(
            defaults: UserDefaults(suiteName: "Kinrox.M5.Live.\(UUID())")!)
        let fixture = LiveServerFixture()
        let server = TransportServer(
            advertisement: try BonjourAdvertiser(
                serverId: serverId,
                name: "Kinrox-iOS-Test-\(UUID().uuidString.prefix(8))", appVersion: "1.0"),
            loadToken: { fixture.tokens[$0] }, saveToken: { fixture.tokens[$0.deviceId] = $0.token }
        )
        server.onEvent = { event in
            switch event {
            case .pairingRequested(_, _, let pin):
                fixture.pin = pin
                fixture.pairRequests += 1
            case .authenticated(let id, _):
                fixture.connectionId = id
                Task {
                    try await server.send(.state(.init(), RemoteModelHarness.playing), to: id)
                    try await server.send(.recent(.init(), [fixture.recent]), to: id)
                }
            case .message(let id, let message):
                if case .command(let header, let command) = message {
                    fixture.commands.append(command)
                    Task { try await server.send(.ack(.init(), .init(replyTo: header.id)), to: id) }
                }
            case .disconnected(_, let failure): fixture.failure = failure
            }
        }
        let model = RemoteAppModel(
            credentials: store, preferences: preferences, monitorNetwork: false)
        var restarted: RemoteAppModel?
        defer {
            model.stop()
            restarted?.stop()
            server.stop()
            // Only the unique test service UUID record created by this test is removed.
            try? store.forget(serverId)
        }
        try server.start()
        model.start()
        try await waitForRemote {
            model.players.contains { $0.id == serverId && $0.status == .new }
        }
        model.select(try #require(model.players.first { $0.id == serverId }))
        try await waitForRemote {
            if let failure = fixture.failure { throw failure }
            return model.connectionState == .awaitingPIN && fixture.pin != nil
        }
        let pin = try #require(fixture.pin)
        model.submitPIN(pin == "000000" ? "111111" : "000000")
        try await waitForRemote { model.pairingMessage != nil }
        #expect(model.pairingMessage == L10n.text("Incorrect code. Try again."))
        model.submitPIN(pin)
        try await waitForRemote { model.controlsEnabled && !model.recents.isEmpty }
        #expect(model.screen == .remote && fixture.pairRequests == 1)
        let read = try KeychainServerStore(service: service).token(for: serverId)
        let matches = read != nil && read == fixture.tokens[preferences.deviceId]
        #expect(matches)
        try verifyAttributes(store: store, id: serverId)
        model.send(.setVolume(volume: 0))
        model.send(.seekRelative(seconds: 10))
        try await waitForRemote { fixture.commands.count == 2 && model.pending.isEmpty }
        #expect(fixture.commands.contains(.seekRelative(seconds: 10)))
        model.enterBackground()
        try await waitForRemote { server.connectionCount == 0 }
        model.enterForeground()
        try await waitForRemote { model.controlsEnabled }
        #expect(fixture.pairRequests == 1)
        model.stop()
        server.stop()
        try server.start()
        let fresh = RemoteAppModel(
            credentials: KeychainServerStore(service: service),
            preferences: preferences, monitorNetwork: false)
        restarted = fresh
        fresh.start()
        try await waitForRemote { fresh.controlsEnabled }
        #expect(fixture.pairRequests == 1 && fresh.selected?.id == serverId)
        fixture.tokens.removeValue(forKey: preferences.deviceId)
        server.disconnect(deviceId: preferences.deviceId)
        try await waitForRemote { fresh.connectionState == .needsPairing }
        #expect(try store.token(for: serverId) != nil)
        fresh.forgetSelected()
        #expect(try store.token(for: serverId) == nil)
        #expect(fresh.screen == .players && preferences.selected == nil)
    }

    @Test("Real save callback error closes TransportClient")
    func failedClientStorage() async throws {
        let id = UUID()
        let fixture = LiveServerFixture()
        let server = TransportServer(
            advertisement: try BonjourAdvertiser(
                serverId: id, name: "Kinrox-Fail-\(UUID().uuidString.prefix(8))", appVersion: "1.0"),
            loadToken: { _ in nil }, saveToken: { _ in })
        let browser = BonjourBrowser()
        var client: TransportClient?
        defer {
            client?.close()
            browser.stop()
            server.stop()
        }
        server.onEvent = { if case .pairingRequested(_, _, let pin) = $0 { fixture.pin = pin } }
        try server.start()
        browser.start()
        try await waitForRemote { browser.servers.contains { $0.id == id && $0.isAvailable } }
        let transport = try TransportClient(
            server: #require(browser.servers.first { $0.id == id }),
            deviceId: UUID(), deviceName: "Error Test", appVersion: "1.0", mode: .pair,
            saveToken: { _ in throw RemoteTestFailure.storage })
        client = transport
        transport.start()
        try await waitForRemote {
            if case .closed(let failure) = transport.state { throw failure }
            return transport.state == .awaitingPIN && fixture.pin != nil
        }
        try await transport.submitPIN(#require(fixture.pin))
        try await waitForRemote { if case .closed = transport.state { true } else { false } }
        #expect(transport.state == .closed(.storageFailure))
    }

    private func verifyAttributes(store: KeychainServerStore, id: UUID) throws {
        var query = store.query(id)
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let attributes = try #require(result as? [String: Any])
        #expect(
            attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool != true)
        #expect(attributes[kSecAttrAccount as String] as? String == id.uuidString)
    }
}

@MainActor private final class LiveServerFixture {
    var tokens: [UUID: Data] = [:]
    var pin: String?
    var pairRequests = 0
    var connectionId: UUID?
    var failure: TransportFailure?
    var commands: [Command] = []
    let recent = RecentItem(id: UUID(), title: "Test File.mkv", duration: 100, available: true)
}

// On both available Simulator runtimes, self-connect is rejected before accept.
// Physical iPhone required: these tests were genuinely executed, not replaced by fakes.
private let supportsListener: Bool = {
    #if targetEnvironment(simulator)
        false
    #else
        true
    #endif
}()
