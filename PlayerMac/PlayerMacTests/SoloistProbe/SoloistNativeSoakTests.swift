import Foundation
import Testing

@testable import Kinrox

@Suite("Soloist native sustained playback", .serialized, .timeLimit(.minutes(40)))
@MainActor
struct SoloistNativeSoakTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KINROX_SOLOIST_NATIVE_SOAK"] == "1"))
    func tenDistinctTracksAtZeroGain() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["KINROX_SOLOIST_ROOT"],
            let profilePath = env["KINROX_SOLOIST_PROFILE_ROOT"],
            let binaryPath = env["KINROX_SOLOIST_BINARY"], SoloistProbeProcess.spotifyAbsent
        else { throw SoloistProbeFailure.configuration }
        let root = URL(fileURLWithPath: path)
        let profile = URL(fileURLWithPath: profilePath)
        try Data("started".utf8).write(
            to: root.appendingPathComponent("started"), options: .withoutOverwriting)
        let log = root.appendingPathComponent("soak.jsonl")
        FileManager.default.createFile(
            atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        func record(_ value: [String: Any]) throws {
            var value = value
            value["time"] = Date().timeIntervalSince1970
            var data = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
            data.append(10)
            try handle.write(contentsOf: data)
        }
        let app = Bundle.main.bundleURL
        let identifier = (Bundle.main.bundleIdentifier ?? "app.kinrox.player")
            .replacingOccurrences(of: ".player", with: ".soloist-host")
        let requirement = try await Task.detached {
            try SoloistProcessSupervisor.hostRequirement(appURL: app, identifier: identifier)
        }.value
        let installation = try SoloistNativeDriverTests.installation(
            environment: env, binaryPath: binaryPath)
        let key = try SoloistProbeProcess.key()
        let driver = SoloistProcessSupervisor(
            config: .init(
                installation: installation, profile: profile.appendingPathComponent("profile"),
                cache: profile.appendingPathComponent("cache"),
                reaper: app.appendingPathComponent("Contents/Helpers/KinroxSoloistHost"),
                hostRequirement: requirement,
                deviceName: "Kinrox Soak " + UUID().uuidString.prefix(8),
                key: { key }))
        let runtime = SoloistRuntime(driver: driver)
        var failed = false
        let observations = Task {
            for await event in runtime.events {
                switch event {
                case .failure, .availability(.failed), .availability(.expired),
                    .availability(.externalTakeover), .ended:
                    failed = true
                default: break
                }
            }
        }
        func ready() async throws {
            let value: [String: Any] = ["ready": true, "pid": await driver.processID() ?? 0]
            try JSONSerialization.data(withJSONObject: value).write(
                to: root.appendingPathComponent("ready.json"), options: .atomic)
        }
        func wait(_ seconds: Int) async throws {
            for _ in 0..<seconds {
                guard SoloistProbeProcess.spotifyAbsent, !failed else {
                    throw SoloistProbeFailure.process
                }
                guard await runtime.confirmedSnapshot().volume == 0 else {
                    throw SoloistProbeFailure.invalidCommand
                }
                try await Task.sleep(for: .seconds(1))
            }
        }
        do {
            let tracks = try await SoloistProbeAccount.tenDistinctTrackURIs()
            try record([
                "stage": "start", "distinct_tracks": tracks.count,
                "occurrences": tracks.count, "gain": 0, "version": installation.version,
            ])
            for (index, uri) in tracks.enumerated() {
                let began = ContinuousClock.now
                try await runtime.perform(.load(uri: uri, occurrenceID: UUID(), position: 0))
                let elapsed = began.duration(to: .now).components
                try await ready()
                try record([
                    "stage": "playing", "occurrence": index + 1,
                    "load_ms": Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
                ])
                try await wait(150)
                try await runtime.perform(.pause(true))
                try record(["stage": "paused", "occurrence": index + 1])
                try await wait(22)
                guard await driver.processID() == nil else { throw SoloistProbeFailure.process }
                try await ready()
                try record(["stage": "parked", "occurrence": index + 1])
                try await wait(8)
            }
            try record(["stage": "complete"])
            await runtime.shutdown()
            await observations.value
            try Data(#"{"stopped":true}"#.utf8).write(
                to: root.appendingPathComponent("stopped.json"))
        } catch {
            await runtime.shutdown()
            observations.cancel()
            try record([
                "stage": "failed",
                "failure": String(describing: error as? SoloistFailure ?? .process),
            ])
            try Data(#"{"stopped":true}"#.utf8).write(
                to: root.appendingPathComponent("stopped.json"))
            throw SoloistProbeFailure.process
        }
    }
}
