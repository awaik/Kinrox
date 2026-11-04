import CryptoKit
import Foundation

struct SoloistAccountPaths: Sendable {
    let binding: String
    let profile: URL
    let cache: URL
    let paired: Bool
}

/// Account-scoped private storage. Only directories with our exact ownership marker can be erased.
actor SoloistAccountStorage {
    private struct Marker: Codable {
        let format: Int
        let binding: String
        var paired: Bool
    }
    let support: URL
    let caches: URL
    private let files = FileManager.default

    init(support: URL, caches: URL) {
        self.support = support
        self.caches = caches
    }

    nonisolated static func binding(clientID: String, userID: String) -> String {
        let bytes = Data((clientID + "\u{0}" + userID).utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func prepare(binding: String) throws -> SoloistAccountPaths {
        try validate(binding)
        let account = support.appendingPathComponent(binding, isDirectory: true)
        let cache = caches.appendingPathComponent(binding, isDirectory: true)
        for directory in [support, caches] { try SoloistInstaller.privateDirectory(directory) }
        for directory in [account, cache] {
            if files.fileExists(atPath: directory.path) {
                _ = try marker(in: directory, binding: binding)
            } else {
                try SoloistInstaller.privateDirectory(directory)
                try write(.init(format: 1, binding: binding, paired: false), in: directory)
            }
        }
        let profile = account.appendingPathComponent("profile", isDirectory: true)
        try SoloistInstaller.privateDirectory(profile)
        return .init(
            binding: binding, profile: profile, cache: cache,
            paired: try marker(in: account, binding: binding).paired)
    }

    func setPaired(_ paired: Bool, binding: String) throws {
        try validate(binding)
        let directory = support.appendingPathComponent(binding, isDirectory: true)
        var value = try marker(in: directory, binding: binding)
        value.paired = paired
        try write(value, in: directory)
    }

    /// The caller must first stop playback and close the profile lock.
    func disconnect(binding: String) throws {
        try validate(binding)
        for directory in [support, caches] where files.fileExists(atPath: directory.path) {
            try checkDirectory(directory)
        }
        let directories = [support, caches].map { $0.appendingPathComponent(binding) }
        // Validate both before deleting either; unknown data is retained for owner inspection.
        for directory in directories where files.fileExists(atPath: directory.path) {
            _ = try marker(in: directory, binding: binding)
        }
        for directory in directories where files.fileExists(atPath: directory.path) {
            try files.removeItem(at: directory)
        }
    }

    private func validate(_ binding: String) throws {
        guard binding.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw SoloistFailure.installation
        }
    }

    private func marker(in directory: URL, binding: String) throws -> Marker {
        try checkDirectory(directory)
        let url = directory.appendingPathComponent("kinrox-owner.json")
        let info = try files.attributesOfItem(atPath: url.path)
        guard info[.type] as? FileAttributeType == .typeRegular,
            (info[.size] as? Int ?? Int.max) < 1024
        else { throw SoloistFailure.installation }
        let value = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: url))
        guard value.format == 1, value.binding == binding else { throw SoloistFailure.installation }
        return value
    }

    private func checkDirectory(_ directory: URL) throws {
        let info = try files.attributesOfItem(atPath: directory.path)
        guard info[.type] as? FileAttributeType == .typeDirectory,
            info[.ownerAccountID] as? UInt32 == getuid(),
            (info[.posixPermissions] as? Int ?? 0) & 0o077 == 0
        else { throw SoloistFailure.installation }
    }

    private func write(_ value: Marker, in directory: URL) throws {
        let url = directory.appendingPathComponent("kinrox-owner.json")
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
