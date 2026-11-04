import Foundation
import Testing

@testable import Kinrox

/// Real-key check of the prepared native installer/supervisor/runtime path. Explicitly opt-in.
@Suite("Soloist native driver live acceptance", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct SoloistNativeDriverTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KINROX_SOLOIST_DRIVER_LIVE"] == "1"))
    func ownedRuntimeRestoresAndControlsWithoutDesktopSpotify() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["KINROX_SOLOIST_ROOT"],
            let profilePath = env["KINROX_SOLOIST_PROFILE_ROOT"],
            let binaryPath = env["KINROX_SOLOIST_BINARY"],
            let reaperPath = env["KINROX_SOLOIST_REAPER"]
        else { throw SoloistProbeFailure.configuration }
        let root = URL(fileURLWithPath: rootPath)
        try Data("{\"started\":true}".utf8).write(
            to: root.appendingPathComponent("started.json"), options: .withoutOverwriting)
        let profile = URL(fileURLWithPath: profilePath)
        let process = try SoloistProbeProcess(
            root: profile, binary: URL(fileURLWithPath: binaryPath))
        let key = try SoloistProbeProcess.key()
        var bootstrap: SoloistProbeSocket?
        var runtime: SoloistRuntime?
        var observation: Task<Void, Never>?
        var ended = false
        var samples: [[String: Any]] = []
        var stage = "bootstrap"
        do {
            let endpoint = try await process.start(
                key: key, reaperURL: URL(fileURLWithPath: reaperPath))
            bootstrap = try SoloistProbeSocket(
                url: endpoint, traceURL: root.appendingPathComponent("bootstrap.jsonl"))
            try await bootstrap?.wait {
                bootstrap?.loggedIn == true && bootstrap?.uri?.isEmpty == false
            }
            guard let uri = bootstrap?.uri else { throw SoloistProbeFailure.configuration }
            bootstrap?.close()
            await process.stop()
            stage = "host_identity"
            let app = Bundle.main.bundleURL
            let host = app.appendingPathComponent("Contents/Helpers/KinroxSoloistHost")
            let identifier = (Bundle.main.bundleIdentifier ?? "app.kinrox.player")
                .replacingOccurrences(of: ".player", with: ".soloist-host")
            let requirement = try await Task.detached {
                try SoloistProcessSupervisor.hostRequirement(appURL: app, identifier: identifier)
            }.value
            let driver = SoloistProcessSupervisor(
                config: .init(
                    installation: try Self.installation(environment: env, binaryPath: binaryPath),
                    profile: profile.appendingPathComponent("profile"),
                    cache: profile.appendingPathComponent("cache"),
                    reaper: host, hostRequirement: requirement, deviceName: process.deviceName,
                    key: { key }))
            let engine = SoloistRuntime(driver: driver, parkDelay: .milliseconds(200))
            runtime = engine
            let first = UUID()
            let second = UUID()
            observation = Task {
                for await event in engine.events {
                    if case .ended(let id) = event, id == second { ended = true }
                }
            }
            func perform(_ name: String, _ operation: SoloistRuntime.Operation) async throws {
                stage = name
                guard SoloistProbeProcess.spotifyAbsent else {
                    throw SoloistProbeFailure.spotifyRunning
                }
                let began = ContinuousClock.now
                try await engine.perform(operation)
                let duration = began.duration(to: .now).components
                let state = await engine.confirmedSnapshot()
                samples.append([
                    "operation": name,
                    "elapsed_ms": Double(duration.seconds) * 1000 + Double(duration.attoseconds)
                        / 1e15,
                    "position": state.position, "duration": state.duration, "paused": state.paused,
                    "volume": state.volume ?? -1, "pid": await driver.processID() ?? 0,
                ])
                try write(
                    ["ready": true, "pid": await driver.processID() ?? 0],
                    root.appendingPathComponent("ready.json"))
                #expect(state.volume == 0)
            }
            try await perform("load_at_35", .load(uri: uri, occurrenceID: first, position: 35))
            try await perform("pause", .pause(true))
            for _ in 0..<100 where await driver.processID() != nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(await driver.processID() == nil)
            try await perform("parked_resume", .pause(false))
            #expect(await engine.confirmedSnapshot().position >= 35)
            try await perform(
                "duplicate_occurrence", .load(uri: uri, occurrenceID: second, position: 0))
            #expect(await engine.confirmedSnapshot().occurrenceID == second)
            try await perform("volume_zero", .volume(0))
            let duration = await engine.confirmedSnapshot().duration
            try await perform("near_end_seek", .seek(max(0, duration - 3)))
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            stage = "natural_exit"
            while !ended, ContinuousClock.now < deadline {
                guard SoloistProbeProcess.spotifyAbsent else {
                    throw SoloistProbeFailure.spotifyRunning
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(ended)
            await engine.shutdown()
            await observation?.value
            try write(
                ["samples": samples, "ended": ended],
                root.appendingPathComponent("native-driver-results.json"))
            try write(["stopped": true], root.appendingPathComponent("stopped.json"))
        } catch {
            bootstrap?.close()
            await process.stop()
            await runtime?.shutdown()
            observation?.cancel()
            try write(
                [
                    "samples": samples, "failed": true, "stage": stage,
                    "failure": String(describing: error as? SoloistFailure ?? .process),
                ],
                root.appendingPathComponent("native-driver-results.json"))
            try write(["stopped": true], root.appendingPathComponent("stopped.json"))
            // Never let Foundation/Security or server errors expose arbitrary payloads in test logs.
            throw SoloistProbeFailure.process
        }
    }
    static func installation(environment: [String: String], binaryPath: String) throws
        -> SoloistInstallation
    {
        if let path = environment["KINROX_SOLOIST_INSTALLATION"] {
            let value = try JSONDecoder().decode(
                SoloistInstallation.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard value.binary.path == binaryPath else { throw SoloistProbeFailure.configuration }
            return value
        }
        return .init(
            binary: URL(fileURLWithPath: binaryPath),
            digest: "2a4f1b9474b8799c8fe79376e90ae4976afe51e169918497859305baa2df8d40",
            version: "1.3.10.33", buildDate: Date(timeIntervalSince1970: 1_793_599_271))
    }
    private func write(_ data: [String: Any], _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
