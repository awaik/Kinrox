import Foundation
import Testing

@testable import Kinrox

@Suite("Soloist serialized runtime", .timeLimit(.minutes(1)))
struct SoloistRuntimeTests {
    let uri = "spotify:track:" + String(repeating: "A", count: 22)

    @Test func socketLossStopsTheStillRunningChildAndWaitsForExplicitPlay() async throws {
        let driver = FakeSoloistDriver()
        let runtime = SoloistRuntime(driver: driver)
        try await runtime.perform(.load(uri: uri, occurrenceID: UUID(), position: 35))
        await driver.simulateSocketLoss()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await driver.stops == 1)
        #expect(await driver.starts == 1)
        #expect(await runtime.confirmedSnapshot().paused)
        try await runtime.perform(.pause(false))
        #expect(await driver.starts == 2)
        #expect(await runtime.confirmedSnapshot().position >= 35)
        await runtime.shutdown()
    }

    @Test func delayedSocketLossCannotRetireAReplacement() async throws {
        let driver = FakeSoloistDriver()
        let runtime = SoloistRuntime(driver: driver)
        try await runtime.perform(.load(uri: uri, occurrenceID: UUID(), position: 0))
        await driver.simulateSocketLoss()
        let replacement = UUID()
        try await runtime.perform(.load(uri: uri, occurrenceID: replacement, position: 35))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await driver.starts == 2)
        #expect(await driver.stops == 1)
        #expect(await driver.overlaps == 0)
        let snapshot = await runtime.confirmedSnapshot()
        #expect(!snapshot.paused && snapshot.occurrenceID == replacement)
        await runtime.shutdown()
    }

    @Test func externallyObservedPauseAlsoParksAndWaitsForExplicitPlay() async throws {
        let driver = FakeSoloistDriver()
        let runtime = SoloistRuntime(driver: driver, parkDelay: .milliseconds(30))
        try await runtime.perform(.load(uri: uri, occurrenceID: UUID(), position: 35))
        try await driver.simulateExternalPause()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await driver.stops == 1)
        #expect(await driver.starts == 1)
        #expect(await runtime.confirmedSnapshot().paused)
        try await runtime.perform(.pause(false))
        #expect(await driver.starts == 2)
        #expect(await driver.overlaps == 0)
        #expect(await runtime.confirmedSnapshot().position >= 35)
        await runtime.shutdown()
    }

    @Test(arguments: [false, true])
    func externalResumeKeepsPlayingPastTheParkingDeadline(includePosition: Bool) async throws {
        let driver = FakeSoloistDriver()
        let runtime = SoloistRuntime(driver: driver, parkDelay: .milliseconds(50))
        try await runtime.perform(.load(uri: uri, occurrenceID: UUID(), position: 35))
        try await driver.simulateExternalPause()
        try await driver.simulateExternalResume(includePosition: includePosition)
        for _ in 0..<100 where await runtime.confirmedSnapshot().paused {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await !runtime.confirmedSnapshot().paused)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await driver.stops == 0)
        #expect(await driver.starts == 1)
        #expect(await !runtime.confirmedSnapshot().paused)
        await runtime.shutdown()
    }

    @Test func inactiveDeviceAfterConfirmedPauseWaitsForExplicitResume() async throws {
        let driver = FakeSoloistDriver()
        let runtime = SoloistRuntime(driver: driver)
        try await runtime.perform(.load(uri: uri, occurrenceID: UUID(), position: 35))
        await driver.configure(.deactivateAfterPause)
        try await runtime.perform(.pause(true))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await runtime.confirmedSnapshot().paused)
        #expect(await driver.starts == 1)
        try await runtime.perform(.pause(false))
        #expect(await driver.starts == 2)
        #expect(await driver.overlaps == 0)
        #expect(await runtime.confirmedSnapshot().position >= 35)
        await runtime.shutdown()
    }

    @Test func resumeDuringIdleTeardownWaitsForTheOldProcess() async throws {
        let driver = FakeSoloistDriver()
        let runtime = SoloistRuntime(driver: driver, parkDelay: .milliseconds(20))
        try await runtime.perform(.load(uri: uri, occurrenceID: UUID(), position: 35))
        await driver.delayStop(by: .milliseconds(150))
        try await runtime.perform(.pause(true))
        for _ in 0..<100 where await driver.stops == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await driver.stops == 1)
        try await runtime.perform(.pause(false))
        try await Task.sleep(for: .milliseconds(180))
        #expect(await driver.overlaps == 0)
        let state = await runtime.confirmedSnapshot()
        #expect(!state.paused)
        #expect(state.position >= 35)
        await runtime.shutdown()
    }

    @Test func parkedResumeRestoresPositionAndGainWithoutOverlappingProcesses() async throws {
        let driver = FakeSoloistDriver()
        let runtime = SoloistRuntime(driver: driver, parkDelay: .milliseconds(30))
        try await runtime.perform(.load(uri: uri, occurrenceID: UUID(), position: 35))
        try await runtime.perform(.volume(27))
        try await runtime.perform(.pause(true))
        try await Task.sleep(for: .milliseconds(80))
        #expect(await driver.stops == 1)
        try await runtime.perform(.pause(false))
        #expect(await driver.starts == 2)
        #expect(await driver.overlaps == 0)
        #expect(await driver.commands.suffix(2) == [.seek, .volume])
        await runtime.shutdown()
        #expect(await driver.stops == 2)
    }

    @Test func shortPauseReusesNativeProcessAndConcurrentCommandsAreSerialized() async throws {
        let driver = FakeSoloistDriver()
        let id = UUID()
        let runtime = SoloistRuntime(driver: driver)
        try await runtime.perform(.load(uri: uri, occurrenceID: id, position: 0))
        try await runtime.perform(.pause(true))
        try await runtime.perform(.pause(false))
        await driver.configure(.normal, delay: .milliseconds(20))
        async let first: Void = runtime.perform(.seek(10))
        async let second: Void = runtime.perform(.seek(20))
        _ = try await (first, second)
        #expect(await driver.maximumInFlight == 1)
        #expect(await driver.starts == 1)
        await runtime.shutdown()
    }

    @Test func pauseAndSeekNearEndOfTrackConfirmWithoutStoppingProcess() async throws {
        let driver = FakeSoloistDriver()
        let runtime = SoloistRuntime(
            driver: driver, dispatchTimeout: 0.2, observationTimeout: 0.2)
        try await runtime.perform(.load(uri: uri, occurrenceID: UUID(), position: 0))
        try await driver.simulatePositionSync(seconds: 99.4)
        #expect(await !runtime.confirmedSnapshot().paused)
        try await runtime.perform(.pause(true))
        try await runtime.perform(.seek(10))
        let paused = await runtime.confirmedSnapshot()
        #expect(paused.paused && abs(paused.position - 10) < 1)
        #expect(await driver.stops == 0)
        try await runtime.perform(.pause(false))
        #expect(await !runtime.confirmedSnapshot().paused)
        await runtime.shutdown()
    }

    @Test func observationTimeoutQueriesSameProcessButMissingACKRetiresIt() async throws {
        let driver = FakeSoloistDriver()
        let runtime = SoloistRuntime(
            driver: driver, dispatchTimeout: 0.05, observationTimeout: 0.04)
        try await runtime.perform(.load(uri: uri, occurrenceID: UUID(), position: 0))
        await driver.configure(.deferredObservation)
        try await runtime.perform(.seek(20))
        #expect(await driver.commands.suffix(2) == [.seek, .state])
        #expect(await driver.starts == 1)
        #expect(await driver.stops == 0)
        await driver.configure(.dropAcknowledgement)
        await #expect(throws: SoloistFailure.dispatchTimeout) {
            try await runtime.perform(.pause(true))
        }
        #expect(await driver.stops == 1)
        await runtime.shutdown()
    }

    @Test func cancellationAfterDispatchStopsBeforeSubsequentCommands() async throws {
        let driver = FakeSoloistDriver()
        let runtime = SoloistRuntime(driver: driver)
        try await runtime.perform(.load(uri: uri, occurrenceID: UUID(), position: 0))
        await driver.configure(.dropAcknowledgement)
        let command = Task { try await runtime.perform(.pause(true)) }
        for _ in 0..<100 where await !driver.commands.contains(.pause) {
            try await Task.sleep(for: .milliseconds(2))
        }
        command.cancel()
        await #expect(throws: CancellationError.self) { try await command.value }
        #expect(await driver.stops == 1)
        await driver.configure(.normal)
        try await runtime.perform(.pause(false))
        #expect(await driver.starts == 2)
        #expect(await driver.overlaps == 0)
        await runtime.shutdown()
    }

    @Test func stateFloodCoalescesInPlaceWithoutLosingBoundaryEvents() async throws {
        let output = SoloistEventBuffer()
        let id = UUID()
        for position in 0..<10_000 {
            await output.send(
                .state(
                    .init(
                        uri: nil, position: Double(position), duration: 10_000,
                        paused: false, volume: 0, deviceName: "Fixture", occurrenceID: id)))
        }
        await output.send(.ended(occurrenceID: id))
        await output.send(.availability(.ready))
        await output.finish()
        if case .state(let value) = await output.next() {
            #expect(value.position == 9999)
        } else {
            Issue.record("Missing latest coalesced state")
        }
        if case .ended(let value) = await output.next() {
            #expect(value == id)
        } else {
            Issue.record("Missing occurrence boundary")
        }
        if case .availability(.ready) = await output.next() {
        } else {
            Issue.record("Ordering changed")
        }
        #expect(await output.next() == nil)
    }
}
