import Darwin
import Foundation
import Testing

@testable import Kinrox

@Suite("Owned Soloist endpoint recovery")
struct SoloistEndpointTests {
    @Test func crashedChildEndpointsArePreservedOutsideTheLaunchNames() throws {
        let profile = try fixture()
        try SoloistEndpointFiles(profile: profile, pid: 123, port: "54321").retire()
        let files = FileManager.default
        #expect(!files.fileExists(atPath: profile.appendingPathComponent("soloist.pid").path))
        let archive = try #require(
            files.contentsOfDirectory(at: profile, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("retired-endpoint-") })
        #expect(
            try String(contentsOf: archive.appendingPathComponent("soloist.pid"), encoding: .utf8)
                == "123")
        #expect(
            try String(contentsOf: profile.appendingPathComponent("session"), encoding: .utf8)
                == "preserve")
    }

    @Test func wrongOwnerAndSymlinkRemainUntouched() throws {
        let profile = try fixture()
        #expect(throws: SoloistFailure.profileBusy) {
            try SoloistEndpointFiles(profile: profile, pid: 456, port: "54321").retire()
        }
        #expect(
            FileManager.default.fileExists(atPath: profile.appendingPathComponent("ws.port").path))
        let linked = profile.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: linked.appendingPathComponent("soloist.pid"),
            withDestinationURL: profile.appendingPathComponent("soloist.pid"))
        #expect(throws: SoloistFailure.profileBusy) {
            try SoloistEndpointFiles(profile: linked, pid: 123, port: "54321").retire()
        }
        #expect(
            try String(contentsOf: profile.appendingPathComponent("soloist.pid"), encoding: .utf8)
                == "123")
    }

    @Test(arguments: [false, true])
    func nextLaunchRetiresDeadProcessEndpointsWithoutTouchingItsSession(partial: Bool) throws {
        let profile = try fixture()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        try Data(String(process.processIdentifier).utf8).write(
            to: profile.appendingPathComponent("soloist.pid"))
        if partial { try Data().write(to: profile.appendingPathComponent("ws.port")) }
        try SoloistEndpointFiles.retireStale(in: profile)
        #expect(
            !FileManager.default.fileExists(atPath: profile.appendingPathComponent("ws.addr").path))
        #expect(
            try String(contentsOf: profile.appendingPathComponent("session"), encoding: .utf8)
                == "preserve")
        try SoloistEndpointFiles.retireStale(in: profile)
    }

    @Test func liveRecycledPIDAndUnattributedFilesAreNeverRetired() throws {
        let profile = try fixture()
        try Data(String(getpid()).utf8).write(to: profile.appendingPathComponent("soloist.pid"))
        #expect(throws: SoloistFailure.profileBusy) {
            try SoloistEndpointFiles.retireStale(in: profile)
        }
        let partial = profile.appendingPathComponent("partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
        try Data("54321".utf8).write(to: partial.appendingPathComponent("ws.port"))
        #expect(throws: SoloistFailure.profileBusy) {
            try SoloistEndpointFiles.retireStale(in: partial)
        }
        #expect(
            FileManager.default.fileExists(atPath: partial.appendingPathComponent("ws.port").path))
    }

    @Test func earlyOwnedExitCanRetireAPartialEndpointBeforeSocketValidation() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
        try Data("123".utf8).write(to: profile.appendingPathComponent("soloist.pid"))
        try SoloistEndpointFiles(profile: profile, pid: 123).retire()
        #expect(
            !FileManager.default.fileExists(
                atPath: profile.appendingPathComponent("soloist.pid").path))
    }

    @Test func danglingSymlinkCannotBeMistakenForAnAbsentEndpoint() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
        let link = profile.appendingPathComponent("soloist.pid")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: profile.appendingPathComponent("missing"))
        #expect(throws: SoloistFailure.profileBusy) {
            try SoloistEndpointFiles.retireStale(in: profile)
        }
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path).hasSuffix(
                "missing"))
    }

    private func fixture() throws -> URL {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Kinrox-Endpoint-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
        for (name, value) in [
            "soloist.pid": "123", "ws.addr": "127.0.0.1", "ws.port": "54321", "session": "preserve",
        ] {
            try Data(value.utf8).write(
                to: profile.appendingPathComponent(name), options: .withoutOverwriting)
        }
        return profile
    }
}
