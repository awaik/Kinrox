import CryptoKit
import Foundation
import Testing

@testable import Kinrox

@Suite("Soloist installation boundaries")
struct SoloistInstallationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KINROX_SOLOIST_ARCHIVE"] != nil))
    func inspectedSpotifyArchivePassesNativeParserWithoutExecutingIt() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["KINROX_SOLOIST_ARCHIVE"])
        let digest = try await Task.detached {
            let tar = try SoloistInstaller.utility(
                "/usr/bin/gzip", ["-dc", path], limit: SoloistArchive.maximumBytes)
            let binary = try SoloistArchive.binary(in: tar)
            try SoloistArchive.validateMachO(binary)
            return SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
        }.value
        #expect(digest == "2a4f1b9474b8799c8fe79376e90ae4976afe51e169918497859305baa2df8d40")
    }
    @Test func archiveNeverExtractsLinksTraversalDuplicatesOrAmbiguousExecutable() throws {
        let payload = Data([1, 2, 3])
        #expect(try SoloistArchive.binary(in: archive([("soloist", 48, payload)])) == payload)
        for name in ["../soloist", "/soloist", "folder/soloist", "folder/../file", "a\\b"] {
            #expect(throws: SoloistFailure.self) {
                try SoloistArchive.binary(
                    in: archive([(name, 48, payload), ("soloist", 48, payload)]))
            }
        }
        for kind: UInt8 in [49, 50, 51, 52, 54, 120] {
            #expect(throws: SoloistFailure.self) {
                try SoloistArchive.binary(
                    in: archive([("entry", kind, payload), ("soloist", 48, payload)]))
            }
        }
        #expect(throws: SoloistFailure.self) {
            try SoloistArchive.binary(
                in: archive([("soloist", 48, payload), ("soloist", 48, payload)]))
        }
        var corrupt = archive([("soloist", 48, payload)])
        corrupt[0] ^= 1
        #expect(throws: SoloistFailure.self) { try SoloistArchive.binary(in: corrupt) }
        #expect(throws: SoloistFailure.self) {
            try SoloistArchive.binary(in: Data(corrupt.prefix(1024)))
        }
    }

    @Test func architectureAndMinimumOSAreCheckedBeforeExecution() throws {
        let valid = macho(cpu: 0x0100_000C, minimum: 0x000D_0000)
        try SoloistArchive.validateMachO(valid)
        for data in [
            macho(cpu: 0x0100_0007, minimum: 0x000D_0000),
            macho(cpu: 0x0100_000C, minimum: 0x000F_0000), Data(valid.prefix(40)),
        ] { #expect(throws: SoloistFailure.self) { try SoloistArchive.validateMachO(data) } }
    }

    @Test func downloadAndVersionPolicyRejectsUnreviewedOriginsAndExpiredBuilds() throws {
        #expect(SoloistInstaller.allowed(SoloistInstaller.download))
        for text in [
            "http://soloist-builds.spotifycdn.com/file", "https://spotifycdn.com/file",
            "https://soloist-builds.spotifycdn.com.evil.test/file",
            "https://user@soloist-builds.spotifycdn.com/file",
            "https://soloist-builds.spotifycdn.com:444/file",
        ] { #expect(!SoloistInstaller.allowed(URL(string: text))) }
        let now = Date(timeIntervalSince1970: 1_793_599_271)
        let output = Data("soloist 1.3.10.33 build 1793599271 (20261102)".utf8)
        let (version, date) = try SoloistInstaller.identity(output, now: now)
        #expect(version == "1.3.10.33" && date == now)
        #expect(throws: SoloistFailure.self) {
            try SoloistInstaller.identity(output, now: now.addingTimeInterval(90 * 86_400))
        }
        #expect(throws: SoloistFailure.self) {
            try SoloistInstaller.identity(output, now: now.addingTimeInterval(-2 * 86_400))
        }
    }

    @Test func cancellationReachesDetachedUtilityAndJoinsItsTeardown() async throws {
        let worker = Task.detached {
            try SoloistInstaller.utility("/bin/sleep", ["30"])
        }
        let waiting = Task { try await SoloistInstaller.value(of: worker) }
        // Bound a regression so a missing cancellation bridge cannot hang the test for 30 seconds.
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            worker.cancel()
        }
        defer { watchdog.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        waiting.cancel()
        await #expect(throws: (any Error).self) { try await waiting.value }
        #expect(worker.isCancelled)
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test func cancelledInstallRemovesOnlyItsOwnStaging() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try SoloistInstaller.privateDirectory(directory)
        let previous = directory.appendingPathComponent("existing-slot")
        try SoloistInstaller.privateDirectory(previous)
        let installer = SoloistInstaller()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await installer.install(in: directory)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["existing-slot"]
        )
    }

    private func macho(cpu: UInt32, minimum: UInt32) -> Data {
        let words: [UInt32] = [0xFEED_FACF, cpu, 0, 2, 1, 24, 0, 0, 0x32, 24, 1, minimum, 0, 0]
        return Data(
            words.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } })
    }
    private func archive(_ entries: [(String, UInt8, Data)]) -> Data {
        var result = Data()
        for (name, kind, body) in entries {
            var header = Data(repeating: 0, count: 512)
            func put(_ text: String, at offset: Int) {
                header.replaceSubrange(offset..<offset + text.utf8.count, with: text.utf8)
            }
            put(name, at: 0)
            put(String(format: "%011o", body.count), at: 124)
            put("        ", at: 148)
            header[156] = kind
            put(String(format: "%06o", header.reduce(0) { $0 + Int($1) }), at: 148)
            header[154] = 0
            result.append(header)
            result.append(body)
            result.append(Data(repeating: 0, count: (512 - body.count % 512) % 512))
        }
        result.append(Data(repeating: 0, count: 1024))
        return result
    }
}
