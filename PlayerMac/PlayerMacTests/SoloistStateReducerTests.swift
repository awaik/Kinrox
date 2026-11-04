import Foundation
import Testing

@testable import Kinrox

@Suite("Soloist occurrence state")
struct SoloistStateReducerTests {
    let uri = "spotify:track:" + String(repeating: "A", count: 22)

    @Test func inactivePausedSnapshotIsNotPlayingTakeover() throws {
        for paused in [false, true] {
            var state = SoloistStateReducer()
            let now = ContinuousClock.now
            state.begin(epoch: 1, occurrenceID: UUID(), uri: uri, now: now)
            _ = state.receive(try playing(), epoch: 1, now: now)
            let input = try SoloistFrame.decode(
                JSONSerialization.data(withJSONObject: [
                    "type": "playback_state", "is_active": false,
                    "status": paused ? "paused" : "playing",
                ]))
            let events = state.receive(input, epoch: 1, now: now)
            #expect(state.inactive)
            #expect(
                events.contains {
                    if case .availability(.externalTakeover) = $0 { true } else { false }
                } == !paused)
        }
    }

    @Test func startupRequiresCompleteExpectedPlayingSnapshot() throws {
        var state = SoloistStateReducer()
        let now = ContinuousClock.now
        state.begin(epoch: 1, occurrenceID: UUID(), uri: uri, now: now)
        _ = state.receive(try frame("playback_changed", status: "playing"), epoch: 1, now: now)
        _ = state.receive(try frame("track_changed", item: uri), epoch: 1, now: now)
        _ = state.receive(
            try SoloistFrame.decode(
                Data(
                    #"{"type":"playback_changed","status":"playing","is_active":true,"position":{"position_ms":0,"speed":1}}"#
                        .utf8)),
            epoch: 1, now: now)
        #expect(!state.ready)
        _ = state.receive(
            try frame("playback_state", status: "buffering", item: uri), epoch: 1, now: now)
        #expect(!state.ready)
        _ = state.receive(try playing(), epoch: 1, now: now)
        #expect(state.ready && !state.snapshot.paused)
    }

    @Test func duplicateURIStillHasNewOccurrenceAndRetiresOldExit() throws {
        var state = SoloistStateReducer()
        let now = ContinuousClock.now
        let first = UUID()
        let second = UUID()
        state.begin(epoch: 1, occurrenceID: first, uri: uri, now: now)
        _ = state.receive(try playing(), epoch: 1, now: now)
        state.begin(epoch: 2, occurrenceID: second, uri: uri, now: now)
        #expect(
            state.processExited(code: 0, epoch: 1, now: now.advanced(by: .seconds(100))).isEmpty)
        _ = state.receive(try playing(), epoch: 1, now: now)
        #expect(!state.ready && state.snapshot.occurrenceID == second)
        _ = state.receive(try playing(), epoch: 2, now: now)
        #expect(state.ready && state.snapshot.position == 0)
    }

    @Test func successfulExitNeedsNaturalBoundaryAndIsEmittedOnce() throws {
        var state = SoloistStateReducer()
        let now = ContinuousClock.now
        let id = UUID()
        state.begin(epoch: 1, occurrenceID: id, uri: uri, now: now)
        _ = state.receive(try playing(), epoch: 1, now: now)
        let events = state.processExited(code: 0, epoch: 1, now: now.advanced(by: .seconds(100)))
        #expect(events.contains { if case .ended(let value) = $0 { value == id } else { false } })
        #expect(
            state.processExited(code: 0, epoch: 1, now: now.advanced(by: .seconds(101))).isEmpty)
        state.begin(epoch: 2, occurrenceID: UUID(), uri: uri, now: now)
        _ = state.receive(try playing(), epoch: 2, now: now)
        let early = state.processExited(code: 0, epoch: 2, now: now.advanced(by: .seconds(10)))
        #expect(!early.contains { if case .ended = $0 { true } else { false } })
        #expect(state.snapshot.paused)
    }

    @Test func pauseAndIntentionalRetirementCannotAdvanceQueue() throws {
        for intentional in [false, true] {
            var state = SoloistStateReducer()
            let now = ContinuousClock.now
            state.begin(epoch: 1, occurrenceID: UUID(), uri: uri, now: now)
            _ = state.receive(try playing(position: 99), epoch: 1, now: now)
            state.suppressEnd = true
            if intentional { state.retire(now: now) }
            let events = state.processExited(code: 0, epoch: 1, now: now.advanced(by: .seconds(3)))
            #expect(!events.contains { if case .ended = $0 { true } else { false } })
        }
    }

    @Test func expiryAndGenericFailureNeverBecomeCredentialRevocation() throws {
        for code: Int32 in [1, 10] {
            var state = SoloistStateReducer()
            let now = ContinuousClock.now
            state.begin(epoch: 1, occurrenceID: UUID(), uri: uri, now: now)
            _ = state.receive(try playing(), epoch: 1, now: now)
            let events = state.processExited(code: code, epoch: 1, now: now)
            #expect(
                events.contains {
                    if case .availability(let value) = $0 {
                        code == 10
                            ? value == .expired : value == .failed("Soloist playback stopped.")
                    } else {
                        false
                    }
                })
            #expect(!events.contains { if case .ended = $0 { true } else { false } })
        }
    }

    @Test func foreignPlayingIsTakeoverEvenAtBoundary() throws {
        var state = SoloistStateReducer()
        let now = ContinuousClock.now
        state.begin(epoch: 1, occurrenceID: UUID(), uri: uri, now: now)
        _ = state.receive(try playing(), epoch: 1, now: now)
        let foreign = "spotify:track:" + String(repeating: "B", count: 22)
        let events = state.receive(
            try frame("playback_state", status: "playing", item: foreign, speed: 1),
            epoch: 1, now: now.advanced(by: .seconds(100)))
        #expect(
            events.contains {
                if case .availability(.externalTakeover) = $0 { true } else { false }
            })
        #expect(state.snapshot.uri == uri && state.snapshot.paused)
        #expect(
            !state.processExited(code: 0, epoch: 1, now: now).contains {
                if case .ended = $0 { true } else { false }
            })
    }

    @Test func terminalForeignBufferingDoesNotOverwriteOccurrence() throws {
        var state = SoloistStateReducer()
        let now = ContinuousClock.now
        let id = UUID()
        state.begin(epoch: 1, occurrenceID: id, uri: uri, now: now)
        _ = state.receive(try playing(), epoch: 1, now: now)
        _ = state.receive(
            try frame("playback_state", status: "buffering", item: "foreign"),
            epoch: 1, now: now.advanced(by: .seconds(100)))
        #expect(state.snapshot.uri == uri)
        #expect(
            state.processExited(code: 0, epoch: 1, now: now.advanced(by: .seconds(101))).contains {
                if case .ended(let value) = $0 { value == id } else { false }
            })
    }

    @Test func capturedNaturalExitWithEarlyBufferingKeepsOriginalBoundary() throws {
        var state = SoloistStateReducer()
        let now = ContinuousClock.now
        let id = UUID()
        state.begin(epoch: 1, occurrenceID: id, uri: uri, now: now)
        _ = state.receive(try playing(), epoch: 1, now: now)
        // Live 1.3.10.33 trace: buffering freezes the anchor 942 ms before EOF,
        // then track_changed carries recommendation metadata before a successful exit.
        _ = state.receive(
            try frame("playback_state", status: "buffering", item: uri, position: 99.058),
            epoch: 1, now: now.advanced(by: .seconds(99.035)))
        _ = state.receive(
            try frame("track_changed", item: "foreign"),
            epoch: 1, now: now.advanced(by: .seconds(100.336)))
        _ = state.receive(
            try frame("playback_state", status: "buffering", item: "foreign"),
            epoch: 1, now: now.advanced(by: .seconds(100.337)))
        #expect(state.snapshot.uri == uri)
        #expect(
            state.processExited(code: 0, epoch: 1, now: now.advanced(by: .seconds(100.4))).contains
            {
                if case .ended(let value) = $0 { value == id } else { false }
            })
    }

    @Test func deviceVolumeIsIndependentAndInputIsBounded() throws {
        var state = SoloistStateReducer()
        let now = ContinuousClock.now
        state.begin(epoch: 1, occurrenceID: UUID(), uri: uri, now: now)
        _ = state.receive(
            try SoloistFrame.decode(Data(#"{"type":"volume_changed","volume":37}"#.utf8)), epoch: 1,
            now: now)
        #expect(state.snapshot.volume == 37 && !state.ready)
        #expect(throws: SoloistFailure.self) {
            try SoloistFrame.decode(Data(repeating: 32, count: 65_537))
        }
        #expect(throws: SoloistFailure.self) {
            try SoloistFrame.decode(Data(#"{"type":"volume_changed","volume":101}"#.utf8))
        }
    }

    private func playing(position: Double = 0) throws -> SoloistFrame {
        try frame("playback_state", status: "playing", item: uri, position: position, speed: 1)
    }
    private func frame(
        _ type: String, status: String? = nil, item: String? = nil,
        position: Double = 0, speed: Double = 0
    ) throws -> SoloistFrame {
        var json: [String: Any] = ["type": type]
        json["status"] = status
        if let item {
            json["item"] = ["uri": item, "decorations": ["playback": ["duration_ms": 100_000]]]
        }
        if type == "playback_state" {
            json["position"] = ["position_ms": position * 1000, "speed": speed]
            json["is_active"] = true
        }
        return try SoloistFrame.decode(JSONSerialization.data(withJSONObject: json))
    }
}
