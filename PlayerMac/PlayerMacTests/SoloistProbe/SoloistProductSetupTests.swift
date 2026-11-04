import CryptoKit
import Foundation
import SpotifyWebAPI
import Testing

@testable import Kinrox

/// Explicit local acceptance utility; never included in the application target.
/// Imports only the session created by this task, without exposing its key to tooling.
@Suite("Soloist application setup acceptance", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct SoloistProductSetupTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KINROX_SOLOIST_PREPARE_APP"] == "1"))
    func reuseAuthorizedProbeKeyAndVerifyProductionAccount() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let sourcePath = env["KINROX_SOLOIST_PROFILE_ROOT"],
            let outputPath = env["KINROX_SOLOIST_ROOT"], SoloistProbeProcess.spotifyAbsent,
            let clientID = UserDefaults.standard.string(forKey: SpotifyAccount.preference),
            let refresh = try KeychainSpotifyCredentialStore().refreshToken(clientID: clientID)
        else { throw SoloistProbeFailure.configuration }
        let source = URL(fileURLWithPath: sourcePath).appendingPathComponent("profile")
        guard source.path.contains("/Kinrox/build/soloist-probe/") else {
            throw SoloistProbeFailure.configuration
        }
        let output = URL(fileURLWithPath: outputPath)
        try SoloistInstaller.privateDirectory(output)
        try Data("started".utf8).write(
            to: output.appendingPathComponent("started"), options: .withoutOverwriting)
        let setup = SoloistSetup()
        var client: SpotifyClient?
        do {
            let tokens = try await SpotifyOAuth.refresh(refresh, clientID: clientID)
            if let next = tokens.refreshToken {
                try KeychainSpotifyCredentialStore().save(next, clientID: clientID)
            }
            let connected = SpotifyClient { _ in tokens.accessToken }
            client = connected
            let profile = try await connected.profile()
            await setup.configure(client: connected, clientID: clientID, userID: profile.id)
            guard setup.configured else { throw SoloistProbeFailure.configuration }
            setup.saveKeyAndInstall(try SoloistProbeProcess.key())
            while setup.busy { try await Task.sleep(for: .milliseconds(50)) }
            if setup.availability == .needsPairing {
                let support = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Kinrox/Soloist")
                let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Kinrox/Soloist")
                let storage = SoloistAccountStorage(support: support, caches: caches)
                let binding = SoloistAccountStorage.binding(clientID: clientID, userID: profile.id)
                let destination = try await storage.prepare(binding: binding)
                try copyOwnedSession(from: source, to: destination.profile)
                setup.pair(replaceSession: false)
                while setup.busy { try await Task.sleep(for: .milliseconds(50)) }
            }
            guard setup.availability == .ready, SoloistProbeProcess.spotifyAbsent else {
                throw SoloistProbeFailure.process
            }
            await setup.cancel()
            await connected.close()
            try JSONSerialization.data(withJSONObject: [
                "ready": true, "version": setup.installation?.version ?? "unknown",
            ])
            .write(to: output.appendingPathComponent("result.json"), options: .withoutOverwriting)
        } catch {
            await setup.cancel()
            await client?.close()
            try Data(#"{"ready":false}"#.utf8).write(
                to: output.appendingPathComponent("result.json"))
            throw SoloistProbeFailure.process
        }
    }

    private func copyOwnedSession(from source: URL, to destination: URL) throws {
        let files = FileManager.default
        let entries = try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        let names = Set(entries.map(\.lastPathComponent)).union(["kinrox.lock"])
        guard try files.contentsOfDirectory(atPath: destination.path).allSatisfy(names.contains)
        else {
            throw SoloistProbeFailure.configuration
        }
        for entry in entries {
            let name = entry.lastPathComponent
            if name == "kinrox.lock" { continue }
            guard !["ws.addr", "ws.port", "soloist.pid"].contains(name) else {
                throw SoloistProbeFailure.configuration
            }
            let info = try files.attributesOfItem(atPath: entry.path)
            let target = destination.appendingPathComponent(name)
            switch info[.type] as? FileAttributeType {
            case .typeDirectory:
                try SoloistInstaller.privateDirectory(target)
                try copyOwnedSession(from: entry, to: target)
            case .typeRegular:
                guard info[.ownerAccountID] as? UInt32 == getuid(),
                    (info[.size] as? Int ?? Int.max) < 64 * 1024 * 1024
                else { throw SoloistProbeFailure.configuration }
                if files.fileExists(atPath: target.path) {
                    let existing = try files.attributesOfItem(atPath: target.path)
                    guard existing[.type] as? FileAttributeType == .typeRegular,
                        existing[.size] as? Int == info[.size] as? Int,
                        try SHA256.hash(data: Data(contentsOf: entry))
                            == SHA256.hash(data: Data(contentsOf: target))
                    else { throw SoloistProbeFailure.configuration }
                } else {
                    try files.copyItem(at: entry, to: target)
                }
            default: throw SoloistProbeFailure.configuration
            }
        }
    }
}
