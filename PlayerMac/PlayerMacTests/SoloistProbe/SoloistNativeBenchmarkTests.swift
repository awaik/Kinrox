import Foundation
import Testing

@testable import Kinrox

@Suite("Soloist native Release measurements", .serialized, .timeLimit(.minutes(40)))
@MainActor
struct SoloistNativeBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KINROX_SOLOIST_NATIVE_BENCH"] == "1"))
    func coldWarmAndConfirmedControlsAtZeroGain() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["KINROX_SOLOIST_ROOT"],
            let profilePath = env["KINROX_SOLOIST_PROFILE_ROOT"],
            let binaryPath = env["KINROX_SOLOIST_BINARY"], SoloistProbeProcess.spotifyAbsent
        else { throw SoloistProbeFailure.configuration }
        let root = URL(fileURLWithPath: path)
        let profile = URL(fileURLWithPath: profilePath).appendingPathComponent("profile")
        try Data("started".utf8).write(
            to: root.appendingPathComponent("started"), options: .withoutOverwriting)
        let log = root.appendingPathComponent("measurements.jsonl")
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
        let trace = try SoloistTraceLog(url: root.appendingPathComponent("native-trace.jsonl"))
        var runtime: SoloistRuntime?
        var observations: Task<Void, Never>?
        let status = BenchmarkStatus()
        var stage = "setup"
        @MainActor func engine(cache: URL) -> (SoloistRuntime, SoloistProcessSupervisor) {
            let driver = SoloistProcessSupervisor(
                config: .init(
                    installation: installation, profile: profile, cache: cache,
                    reaper: app.appendingPathComponent("Contents/Helpers/KinroxSoloistHost"),
                    hostRequirement: requirement,
                    deviceName: "Kinrox Bench " + UUID().uuidString.prefix(8), key: { key }))
            let engine = SoloistRuntime(driver: SoloistRecordedDriver(base: driver, log: trace))
            runtime = engine
            observations = Task {
                for await event in engine.events {
                    switch event {
                    case .failure, .availability(.failed), .availability(.expired),
                        .availability(.externalTakeover), .ended:
                        status.failed = true
                    default: break
                    }
                }
            }
            return (engine, driver)
        }
        func measure(
            _ name: String, _ index: Int, _ operation: SoloistRuntime.Operation,
            engine: SoloistRuntime, driver: SoloistProcessSupervisor
        ) async throws {
            stage = name
            guard SoloistProbeProcess.spotifyAbsent, !status.failed else {
                throw SoloistProbeFailure.process
            }
            let began = ContinuousClock.now
            try await engine.perform(operation)
            let duration = began.duration(to: .now).components
            guard await engine.confirmedSnapshot().volume == 0 else {
                throw SoloistProbeFailure.invalidCommand
            }
            try record([
                "operation": name, "sample": index,
                "confirmed_ms": Double(duration.seconds) * 1000 + Double(duration.attoseconds)
                    / 1e15,
            ])
            try JSONSerialization.data(withJSONObject: [
                "ready": true, "pid": await driver.processID() ?? 0,
            ])
            .write(to: root.appendingPathComponent("ready.json"), options: .atomic)
        }
        do {
            let tracks = try await SoloistProbeAccount.tenDistinctTrackURIs()
            try record([
                "stage": "start", "distinct_tracks": tracks.count, "gain": 0,
                "version": installation.version,
                "cold_condition": "new empty audio cache; stored session; OS cache uncontrolled",
            ])
            let starts = env["KINROX_SOLOIST_BENCH_STARTUPS"] == "0" ? 0 : 30
            for index in 0..<starts {
                let (engine, driver) = engine(
                    cache: root.appendingPathComponent("cold-cache-\(index)"))
                try await measure(
                    "cold_load", index,
                    .load(uri: tracks[index % tracks.count], occurrenceID: UUID(), position: 0),
                    engine: engine, driver: driver)
                await engine.shutdown()
                await observations?.value
            }
            let (engine, driver) = engine(cache: root.appendingPathComponent("warm-cache"))
            for (index, uri) in tracks.enumerated() {
                try await measure(
                    "prime_cache", index, .load(uri: uri, occurrenceID: UUID(), position: 0),
                    engine: engine, driver: driver)
            }
            for index in 0..<starts {
                try await measure(
                    "warm_load", index,
                    .load(uri: tracks[index % tracks.count], occurrenceID: UUID(), position: 0),
                    engine: engine, driver: driver)
            }
            for index in 0..<200 {
                try await measure("pause", index, .pause(true), engine: engine, driver: driver)
                try await measure("resume", index, .pause(false), engine: engine, driver: driver)
                try await measure(
                    "seek", index, .seek(index.isMultiple(of: 2) ? 15 : 30), engine: engine,
                    driver: driver)
                try await measure(
                    "volume_zero_idempotent", index, .volume(0), engine: engine, driver: driver)
                try await measure(
                    "next", index,
                    .load(uri: tracks[index % tracks.count], occurrenceID: UUID(), position: 0),
                    engine: engine, driver: driver)
            }
            try record(["stage": "complete"])
            await engine.shutdown()
            await observations?.value
            await trace.close()
        } catch {
            await runtime?.shutdown()
            observations?.cancel()
            await trace.close()
            try record([
                "stage": "failed", "operation": stage,
                "failure": String(describing: error as? SoloistFailure ?? .process),
            ])
            try Data(#"{"stopped":true}"#.utf8).write(
                to: root.appendingPathComponent("stopped.json"))
            throw SoloistProbeFailure.process
        }
        try Data(#"{"stopped":true}"#.utf8).write(to: root.appendingPathComponent("stopped.json"))
    }
}

@MainActor
private final class BenchmarkStatus {
    var failed = false
}
