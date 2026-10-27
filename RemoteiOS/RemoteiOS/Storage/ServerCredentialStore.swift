import Foundation
import Security

@MainActor
protocol ServerCredentialStore: AnyObject {
    func servers() throws -> [SavedMac]
    func token(for id: UUID) throws -> Data?
    func save(token: Data, server: SavedMac) throws
    func forget(_ id: UUID) throws
}

@MainActor
final class KeychainServerStore: ServerCredentialStore {
    static let service = "app.kinrox.remote.servers"
    let service: String
    private struct Record: Codable {
        let token: Data
        let name: String
    }
    struct Failure: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            L10n.format("Failed to access Keychain (%@).", String(status))
        }
    }
    init(service: String = KeychainServerStore.service) { self.service = service }

    func query(_ id: UUID? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ]
        if let id { query[kSecAttrAccount as String] = id.uuidString }
        return query
    }
    func token(for id: UUID) throws -> Data? {
        var query = query(id)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw Failure(status: errSecDecode) }
        return try decode(data).token
    }
    func servers() throws -> [SavedMac] {
        var query = query()
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        guard let rows = result as? [[String: Any]] else { throw Failure(status: errSecDecode) }
        return rows.compactMap { row in
            guard let account = row[kSecAttrAccount as String] as? String,
                let id = UUID(uuidString: account),
                let data = row[kSecValueData as String] as? Data,
                let record = try? decode(data)
            else { return nil }
            return SavedMac(id: id, name: record.name)
        }
    }
    func save(token: Data, server: SavedMac) throws {
        guard token.count == 32 else { throw Failure(status: errSecParam) }
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(
                Record(token: token, name: server.name)),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let query = query(server.id)
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil))
        } else {
            try check(status)
        }
    }
    func forget(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func decode(_ data: Data) throws -> Record {
        guard let record = try? JSONDecoder().decode(Record.self, from: data),
            record.token.count == 32
        else { throw Failure(status: errSecDecode) }
        return record
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw Failure(status: status) }
    }
}
