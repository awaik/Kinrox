import Foundation
import RemoteProtocol
import Security

struct PairedDevice: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let pairedAt: Date
}

@MainActor
protocol PairedDeviceStore {
    func devices() throws -> [PairedDevice]
    func token(for id: UUID) throws -> Data?
    func save(_ record: ServerHandshake.PairingRecord) throws
    func forget(_ id: UUID) throws
}

/// Local Data Protection Keychain only: legacy macOS Keychain ignores accessible.
@MainActor
final class KeychainPairedDeviceStore: PairedDeviceStore {
    static let service = "app.kinrox.remote.paired-devices"
    private let service: String

    private struct Record: Codable {
        let device: PairedDevice
        let token: Data
    }

    struct Failure: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            L10n.format("Failed to access Keychain (%@).", String(status))
        }
    }

    init(service: String = KeychainPairedDeviceStore.service) { self.service = service }

    private func query(_ id: UUID? = nil) -> [String: Any] {
        var result: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
        if let id { result[kSecAttrAccount as String] = id.uuidString }
        return result
    }

    func token(for id: UUID) throws -> Data? {
        var query = query(id)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw Failure(status: errSecDecode) }
        let record = try decode(data)
        guard record.device.id == id else { throw Failure(status: errSecDecode) }
        return record.token
    }

    func devices() throws -> [PairedDevice] {
        var query = query()
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        guard let rows = result as? [[String: Any]] else { throw Failure(status: errSecDecode) }
        return rows.compactMap { row -> PairedDevice? in
            guard let data = row[kSecValueData as String] as? Data,
                let account = row[kSecAttrAccount as String] as? String,
                let record = try? decode(data), record.device.id.uuidString == account
            else { return nil }
            return record.device
        }.sorted { $0.pairedAt > $1.pairedAt }
    }

    func save(_ record: ServerHandshake.PairingRecord) throws {
        guard record.token.count == 32 else { throw Failure(status: errSecParam) }
        let data = try JSONEncoder().encode(
            Record(
                device: PairedDevice(
                    id: record.deviceId, name: record.deviceName, pairedAt: Date()),
                token: record.token))
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let query = query(record.deviceId)
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
