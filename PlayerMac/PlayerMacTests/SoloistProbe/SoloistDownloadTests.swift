import Foundation
import Testing

@testable import Kinrox

@Suite("Soloist opt-in official download", .timeLimit(.minutes(3)))
struct SoloistDownloadTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KINROX_SOLOIST_DOWNLOAD_LIVE"] == "1"))
    func verifiesFreshInstallationWithoutCredentials() async throws {
        guard let path = ProcessInfo.processInfo.environment["KINROX_SOLOIST_ROOT"] else {
            throw SoloistFailure.installation
        }
        let root = URL(fileURLWithPath: path)
        try SoloistInstaller.privateDirectory(root)
        try Data("started".utf8).write(
            to: root.appendingPathComponent("started"), options: .withoutOverwriting)
        let result = try await SoloistInstaller().install(
            in: root.appendingPathComponent("engines"))
        #expect(FileManager.default.fileExists(atPath: result.binary.path))
        #expect(result.expiryDate > Date())
        try JSONEncoder().encode(result).write(
            to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
    }
}
