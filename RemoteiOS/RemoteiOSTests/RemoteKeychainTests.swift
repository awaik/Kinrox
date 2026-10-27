import Foundation
import Security
import Testing

@testable import RemoteiOS

@Suite("iPhone Storage - Real Keychain")
@MainActor struct RemoteKeychainTests {
    @Test("Write, update name, attributes, read with fresh store, and delete")
    func persistence() throws {
        let service = "app.kinrox.remote.tests.\(UUID())"
        let store = KeychainServerStore(service: service)
        let id = UUID()
        let token = Data(repeating: 42, count: 32)
        defer { try? store.forget(id) }
        try store.save(token: token, server: SavedMac(id: id, name: "First Name"))
        try store.save(token: token, server: SavedMac(id: id, name: "New Name"))
        let fresh = KeychainServerStore(service: service)
        let matches = try fresh.token(for: id) == token
        #expect(matches)
        #expect(try fresh.servers() == [SavedMac(id: id, name: "New Name")])
        var query = store.query(id)
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let attributes = try #require(result as? [String: Any])
        #expect(
            attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool != true)
        try fresh.forget(id)
        #expect(try store.token(for: id) == nil && store.servers().isEmpty)
    }
}
