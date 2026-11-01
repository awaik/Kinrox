import Foundation
import Security

@MainActor
protocol SpotifyCredentialStore {
    func refreshToken(clientID: String) throws -> String?
    func save(_ token: String, clientID: String) throws
    func remove(clientID: String) throws
}

@MainActor
final class KeychainSpotifyCredentialStore: SpotifyCredentialStore {
    private let service: String
    init(service: String = "app.kinrox.spotify.account") { self.service = service }
    private func query(_ clientID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: clientID,
            kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false,
        ]
    }
    func refreshToken(clientID: String) throws -> String? {
        var query = query(clientID)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
            let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { throw KeychainPairedDeviceStore.Failure(status: status) }
        return token
    }
    func save(_ token: String, clientID: String) throws {
        let values: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let query = query(clientID)
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainPairedDeviceStore.Failure(status: status)
        }
    }
    func remove(clientID: String) throws {
        let status = SecItemDelete(query(clientID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainPairedDeviceStore.Failure(status: status)
        }
    }
}
