import AppKit
import Foundation
import SpotifyWebAPI
import Testing

@testable import Kinrox

/// Disabled by default. The explicit env flag is not a key and never contains one.
@Suite("Soloist live feasibility", .serialized, .timeLimit(.minutes(60)))
@MainActor
struct SoloistLiveProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KINROX_SOLOIST_LIVE"] == "1"))
    func controlledProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["KINROX_SOLOIST_ROOT"],
            let binaryPath = env["KINROX_SOLOIST_BINARY"],
            let reaperPath = env["KINROX_SOLOIST_REAPER"]
        else { throw SoloistProbeFailure.configuration }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let marker = root.appendingPathComponent("started.json")
        try Data("{\"started\":true}".utf8).write(to: marker, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        let profileRoot = URL(
            fileURLWithPath: env["KINROX_SOLOIST_PROFILE_ROOT"] ?? rootPath, isDirectory: true)
        let process = try SoloistProbeProcess(
            root: profileRoot, binary: URL(fileURLWithPath: binaryPath))
        let key = try SoloistProbeProcess.key()
        var socket: SoloistProbeSocket?
        var launch = 0
        var singleTrackMode = false
        var parked = false
        var savedPosition: Double = 0
        var capturedURIs: [Int: String] = [:]
        do {
            let endpoint = try await process.start(
                key: key, reaperURL: URL(fileURLWithPath: reaperPath))
            socket = try SoloistProbeSocket(
                url: endpoint, traceURL: root.appendingPathComponent("trace-0.jsonl"))
            try write(
                ["ready": true, "device_name": process.deviceName, "pid": process.pid ?? 0],
                to: root.appendingPathComponent("ready.json"))
            print("SOLOIST_PROBE ready for phone pairing; gain zero; diagnostics suppressed.")
            var index = 1
            let deadline = ContinuousClock.now.advanced(by: .seconds(3300))
            while .now < deadline {
                guard SoloistProbeProcess.spotifyAbsent else {
                    throw SoloistProbeFailure.spotifyRunning
                }
                if process.pid == nil, singleTrackMode, !parked {
                    try write(
                        [
                            "single_track_process_exited": true,
                            "exit_code": process.exitCode ?? -999,
                            "last_state": socket?.snapshot ?? [:],
                        ], to: root.appendingPathComponent("single-track-exit.json"))
                    #expect(process.exitCode == 0)
                    break
                }
                guard process.pid != nil || parked else { throw SoloistProbeFailure.process }
                guard let current = socket else { throw SoloistProbeFailure.socket }
                let path = root.appendingPathComponent(String(format: "command-%04d.json", index))
                if let data = try? Data(contentsOf: path), data.count <= 8192,
                    let command = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let operation = command["operation"] as? String
                {
                    let began = ContinuousClock.now
                    var reply: [String: Any] = ["index": index]
                    do {
                        if operation == "shutdown" { break }
                        if operation == "suspend" {
                            guard singleTrackMode, !parked else {
                                throw SoloistProbeFailure.invalidCommand
                            }
                            try await current.send("pause")
                            try await current.wait { current.status == "paused" }
                            let revision = current.stateRevision
                            try await current.send("get_state")
                            try await current.wait { current.stateRevision > revision }
                            savedPosition = current.position
                            current.close()
                            await process.stop()
                            parked = true
                            reply["saved_position_ms"] = savedPosition
                        } else if ["restart", "single_track", "resume_captured"].contains(operation)
                        {
                            if capturedURIs[0] == nil { capturedURIs[0] = current.uri }
                            let singleURI: String?
                            if operation != "restart" {
                                guard let captured = capturedURIs[0] else {
                                    throw SoloistProbeFailure.invalidCommand
                                }
                                singleURI = captured
                            } else {
                                singleURI = nil
                            }
                            current.close()
                            await process.stop()
                            launch += 1
                            singleTrackMode = singleURI != nil
                            parked = false
                            let endpoint = try await process.start(
                                key: key, reaperURL: URL(fileURLWithPath: reaperPath),
                                singleTrack: singleURI)
                            socket = try SoloistProbeSocket(
                                url: endpoint,
                                traceURL: root.appendingPathComponent("trace-\(launch).jsonl"))
                            try await socket?.wait(seconds: 15) { socket?.loggedIn == true }
                            if singleTrackMode {
                                try await socket?.wait(seconds: 15) {
                                    socket?.confirmedPlayingURI == singleURI
                                }
                            }
                            let ready = began.duration(to: .now).components
                            reply["ready_ms"] =
                                Double(ready.seconds) * 1000
                                + Double(ready.attoseconds) / 1e15
                            if operation == "resume_captured", savedPosition >= 1,
                                let resumed = socket
                            {
                                let acks = resumed.acknowledgements
                                let revision = resumed.stateRevision
                                try await resumed.send(
                                    "seek", fields: ["position_ms": savedPosition])
                                try await resumed.wait(seconds: 2) {
                                    resumed.acknowledgements > acks
                                }
                                try await resumed.send("get_state")
                                try await resumed.wait {
                                    resumed.stateRevision > revision
                                        && abs(resumed.position - savedPosition) <= 1000
                                        && resumed.confirmedPlayingURI == singleURI
                                }
                                reply["restored_position_ms"] = savedPosition
                            }
                            reply["session_restored"] = socket?.loggedIn == true
                            reply["single_track_mode"] = singleTrackMode
                        } else if operation == "bind_account" {
                            reply["binding"] = try await SoloistProbeAccount.verify(
                                deviceName: process.deviceName)
                        } else if operation == "audition" {
                            try await SoloistProbeAudition.run(socket: current, process: process)
                            reply["audition_gain_percent"] = 5
                            reply["audition_seconds"] = 5
                        } else if operation == "snapshot" {
                            if current.loggedIn {
                                let revision = current.stateRevision
                                try await current.send("get_state")
                                try await current.wait { current.stateRevision > revision }
                            }
                        } else if operation == "capture_track" {
                            guard let uri = current.uri, uri.hasPrefix("spotify:track:") else {
                                throw SoloistProbeFailure.invalidCommand
                            }
                            let slot = command["slot"] as? Int ?? 0
                            guard (0...1).contains(slot) else {
                                throw SoloistProbeFailure.invalidCommand
                            }
                            capturedURIs[slot] = uri
                            reply["captured"] = true
                        } else {
                            let name = operation == "play_captured" ? "play" : operation
                            var fields = command["fields"] as? [String: Any] ?? [:]
                            if operation == "play_captured" {
                                let slot = command["slot"] as? Int ?? 0
                                guard let capturedURI = capturedURIs[slot] else {
                                    throw SoloistProbeFailure.invalidCommand
                                }
                                fields["uri"] = capturedURI
                            }
                            // Probe remains muted. Nonzero gain requires a separate output-verification decision.
                            if name == "set_volume", fields["volume"] as? Double != 0 {
                                throw SoloistProbeFailure.invalidCommand
                            }
                            let acks = current.acknowledgements
                            let errors = current.errors
                            let stateRevision = current.stateRevision
                            try await current.send(name, fields: fields)
                            try await current.wait(seconds: 2) {
                                current.acknowledgements > acks || current.errors > errors
                            }
                            guard current.errors == errors else {
                                throw SoloistProbeFailure.rejected
                            }
                            reply["accepted"] = true
                            let accepted = began.duration(to: .now).components
                            reply["accepted_ms"] =
                                Double(accepted.seconds) * 1000 + Double(accepted.attoseconds)
                                / 1e15
                            if name == "pause" {
                                try await current.wait {
                                    current.status == "paused" || current.status == "idle"
                                }
                            }
                            if name == "play" {
                                try await current.wait(seconds: 15) {
                                    current.status == "playing"
                                        && current.confirmedPlayingURI != nil
                                        && current.stateRevision > stateRevision
                                        && (fields["uri"] == nil
                                            || (current.confirmedPlayingURI == fields["uri"]
                                                as? String
                                                && current.position < 1000))
                                }
                            }
                            if name == "seek", let target = fields["position_ms"] as? Double {
                                try await current.wait { abs(current.position - target) <= 1000 }
                            }
                            if name == "set_volume" {
                                try await current.wait { current.volume == 0 }
                            }
                            if name == "activate" { try await current.wait { current.active } }
                            if name == "deactivate" { try await current.wait { !current.active } }
                        }
                        reply["success"] = true
                    } catch {
                        reply["success"] = false
                        reply["failure"] =
                            error is SoloistProbeFailure
                            ? String(describing: error) : "operation_failed"
                    }
                    let elapsed = began.duration(to: .now).components
                    reply["elapsed_ms"] =
                        Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                    reply["state"] = socket?.snapshot
                    reply["pid"] = process.pid
                    try write(
                        reply,
                        to: root.appendingPathComponent(String(format: "reply-%04d.json", index)))
                    index += 1
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            socket?.close()
            await process.stop()
            try write(
                ["stopped": true, "exit_code": process.exitCode ?? -999],
                to: root.appendingPathComponent("stopped.json"))
        } catch {
            socket?.close()
            await process.stop()
            throw error
        }
    }

    private func write(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
