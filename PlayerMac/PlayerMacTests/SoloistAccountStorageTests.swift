import Foundation
import Testing

@testable import Kinrox

@Suite("Soloist owned account storage")
struct SoloistAccountStorageTests {
    @Test func independentAccountsAndDisconnectPreserveUnrelatedData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = SoloistAccountStorage(
            support: root.appendingPathComponent("sessions"),
            caches: root.appendingPathComponent("cache"))
        let first = SoloistAccountStorage.binding(clientID: "client", userID: "first")
        let second = SoloistAccountStorage.binding(clientID: "client", userID: "second")
        let a = try await storage.prepare(binding: first)
        let b = try await storage.prepare(binding: second)
        #expect(!a.paired && !b.paired && a.profile != b.profile && a.cache != b.cache)
        try await storage.setPaired(true, binding: first)
        #expect(try await storage.prepare(binding: first).paired)
        try await storage.disconnect(binding: first)
        #expect(!FileManager.default.fileExists(atPath: a.profile.path))
        #expect(!FileManager.default.fileExists(atPath: a.cache.path))
        #expect(FileManager.default.fileExists(atPath: b.profile.path))
        #expect(FileManager.default.fileExists(atPath: b.cache.path))
    }

    @Test func unknownOrMismatchedOwnershipCannotBeDeleted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = SoloistAccountStorage(
            support: root.appendingPathComponent("sessions"),
            caches: root.appendingPathComponent("cache"))
        let binding = SoloistAccountStorage.binding(clientID: "client", userID: "fixture")
        let paths = try await storage.prepare(binding: binding)
        let marker = paths.cache.appendingPathComponent("kinrox-owner.json")
        let unknown = Data(#"{"format":1,"binding":"someone-else","paired":true}"#.utf8)
        try unknown.write(to: marker)
        await #expect(throws: SoloistFailure.self) {
            try await storage.disconnect(binding: binding)
        }
        #expect(FileManager.default.fileExists(atPath: paths.profile.path))
        #expect(try Data(contentsOf: marker) == unknown)
        await #expect(throws: SoloistFailure.self) {
            try await storage.prepare(binding: "../escape")
        }
    }
}
