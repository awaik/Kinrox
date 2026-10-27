import Foundation
import Security
import Testing

@testable import Kinrox
@testable import RemoteProtocol

@Suite("M4.4: real Keychain", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RemoteKeychainTests {
    @Test("Corrupted entry does not hide healthy remotes or impede revocation")
    func corruptedRecordIsolation() throws {
        let service = "app.kinrox.tests.paired-devices.\(UUID().uuidString)"
        let store = KeychainPairedDeviceStore(service: service)
        let good = UUID()
        let bad = UUID()
        defer {
            try? store.forget(good)
            try? store.forget(bad)
        }
        let token = Data(repeating: 7, count: 32)
        try store.save(.init(deviceId: good, deviceName: "Healthy remote", token: token))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: bad.uuidString,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data("{broken".utf8),
        ]
        #expect(SecItemAdd(query as CFDictionary, nil) == errSecSuccess)
        #expect(try store.devices().map(\.id) == [good])
        #expect(try store.token(for: good) == token)
        #expect(throws: KeychainPairedDeviceStore.Failure.self) { try store.token(for: bad) }
        try store.forget(good)
        #expect(try store.devices().isEmpty)
    }

    @Test("Token survives new store instance, attributes local, Forget revokes access")
    func persistenceAndProtection() async throws {
        // Unique service: test does not read or delete real user pairings.
        let service = "app.kinrox.tests.paired-devices.\(UUID().uuidString)"
        let store = KeychainPairedDeviceStore(service: service)
        #expect(try store.devices().isEmpty)
        let id = UUID()
        defer { try? store.forget(id) }
        let h = try RemoteServerHarness(store: store)
        defer {
            h.server.stop()
            h.browser.stop()
            for client in h.clients { client.close() }
        }
        try await h.start()
        let client = try await h.pair(id)
        let token = try #require(h.tokens[id])
        let restored = KeychainPairedDeviceStore(service: service)
        #expect(try restored.token(for: id) == token)
        #expect(try restored.devices().map(\.id) == [id])
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
        ]
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let attributes = try #require(result as? [String: Any])
        #expect(
            attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        client.close()
        h.server.stop()
        h.server.start(monitorSystem: false)
        try await waitForRemote { h.server.isOnline && h.discovered != nil }
        let authenticated = try h.client(id, token: token)
        try await waitForRemote { authenticated.state == .connected }
        h.server.forget(id)
        #expect(try restored.token(for: id) == nil)
        #expect(try restored.devices().isEmpty)
        await h.stop()
    }
}
