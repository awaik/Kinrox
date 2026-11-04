import Foundation
import Testing

@testable import Kinrox

@Suite("Soloist probe trace")
@MainActor
struct SoloistProbeTraceTests {
    @Test func nativeTraceNeverPersistsUnexpectedPayloadOrIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KinroxNativeTraceTest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = root.appendingPathComponent("native-trace.jsonl")
        let log = try SoloistTraceLog(url: path)
        let marker = "SYNTHETIC_PRIVATE_NATIVE_MARKER"
        let frame = try SoloistFrame.decode(
            JSONSerialization.data(withJSONObject: [
                "type": marker, "command": marker, "message": marker,
                "item": ["uri": "spotify:track:" + marker, "name": marker],
                "status": "playing", "volume": 0,
            ]))
        await log.input(.frame(frame, epoch: 4), expectedURI: "spotify:track:fixture")
        await log.close()
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(!text.contains(marker))
        #expect(!text.contains("spotify:track:"))
        let value = try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(value["event"] as? String == "other")
        #expect(value["matches_occurrence"] as? Bool == false)
        #expect(value["status"] as? String == "playing")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KINROX_SOLOIST_AUDITION"] != "1"))
    func audibleProbeIsDisabledByDefault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KinroxSoloistAuditionGuard-" + UUID().uuidString, isDirectory: true)
        let process = try SoloistProbeProcess(
            root: root, binary: root.appendingPathComponent("absent-soloist"))
        let traceURL = root.appendingPathComponent("trace.jsonl")
        let socket = try SoloistProbeSocket(
            url: URL(string: "ws://127.0.0.1:9")!, traceURL: traceURL)
        defer { socket.close() }
        do {
            try await SoloistProbeAudition.run(socket: socket, process: process)
            Issue.record("An audible probe must require explicit environment opt-in")
        } catch SoloistProbeFailure.invalidCommand {
            #expect(process.pid == nil)
            let text = try String(contentsOf: traceURL, encoding: .utf8)
            #expect(!text.contains("submit"))
        }
    }

    @Test func traceKeepsOnlyWhitelistedFieldsAndLocalLabels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KinroxSoloistProbeTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = root.appendingPathComponent("trace.jsonl")
        let probe = try SoloistProbeSocket(url: URL(string: "ws://127.0.0.1:9")!, traceURL: path)
        defer { probe.close() }
        let marker = "SYNTHETIC_PRIVATE_MARKER"
        let item: [String: Any] = [
            "uri": "spotify:track:" + marker,
            "decorations": ["identity": ["name": marker], "playback": ["duration_ms": 2000]],
        ]
        for frame: [String: Any] in [
            ["type": "auth_state", "logged_in": true, "device_name": marker],
            [
                "type": "playback_state", "status": "playing", "item": item,
                "position": ["position_ms": 20, "speed": 1], "volume": 0,
            ],
            [
                "type": "queue_changed",
                "upcoming": [["uid": marker, "source": "autoplay", "item": item]],
            ],
            ["type": "error", "message": marker],
        ] {
            try probe.receive(JSONSerialization.data(withJSONObject: frame))
        }
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(!text.contains(marker))
        #expect(!text.contains("spotify:track:"))
        let events = try text.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let queue = try #require(events.first { $0["event"] as? String == "queue_changed" })
        let upcoming = try #require(queue["upcoming"] as? [[String: Any]])
        #expect(upcoming.first?["source"] as? String == "autoplay")
        #expect(upcoming.first?["item_label"] as? Int == 1)
        #expect(upcoming.first?["entry_label"] as? Int == 1)
        #expect(probe.stateRevision == 1)
        #expect(probe.errors == 1)
    }

    @Test func initialPlayingFlagDoesNotConfirmLoadedTrackBeforeBuffering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KinroxSoloistReadiness-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let probe = try SoloistProbeSocket(
            url: URL(string: "ws://127.0.0.1:9")!,
            traceURL: root.appendingPathComponent("trace.jsonl"))
        defer { probe.close() }
        let uri = "spotify:track:SYNTHETIC_READINESS"
        for frame: [String: Any] in [
            ["type": "playback_state", "status": "playing", "item": ["uri": ""]],
            ["type": "track_changed", "item": ["uri": uri]],
        ] {
            try probe.receive(JSONSerialization.data(withJSONObject: frame))
        }
        #expect(probe.status == "playing")
        #expect(probe.uri == uri)
        #expect(probe.confirmedPlayingURI == nil)
        try probe.receive(
            JSONSerialization.data(withJSONObject: [
                "type": "playback_state", "status": "playing", "item": ["uri": uri],
                "position": ["position_ms": 2, "speed": 1],
            ]))
        #expect(probe.confirmedPlayingURI == uri)
        try probe.receive(
            JSONSerialization.data(withJSONObject: [
                "type": "playback_changed", "status": "buffering",
            ]))
        #expect(probe.confirmedPlayingURI == nil)
    }
}
