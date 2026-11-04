import Foundation
import Testing

@testable import Kinrox

@Suite("Soloist account binding", .timeLimit(.minutes(1)))
struct SoloistPairingTests {
    @Test func pairingExitsBeforeIdleAccountVerificationAndAlwaysCloses() async throws {
        let driver = PairingDriver()
        let pairing = SoloistPairing(driver: driver)
        try await pairing.connect(replaceSession: true) {
            await driver.modes == [true, false]
        }
        #expect(await driver.modes == [true, false])
        #expect(await driver.closed)
    }

    @Test func storedProfileVerificationNeverClearsItsSession() async throws {
        let driver = PairingDriver()
        try await SoloistPairing(driver: driver).connect(replaceSession: false) { true }
        #expect(await driver.modes == [false])
        #expect(await driver.closed)
    }

    @Test func wrongAccountCannotBecomeReadyAndProcessIsClosed() async throws {
        let driver = PairingDriver()
        await #expect(throws: SoloistFailure.accountMismatch) {
            try await SoloistPairing(driver: driver).connect(replaceSession: false) { false }
        }
        #expect(await driver.closed)
    }

    @Test func cancellationDuringPhoneWaitClosesTheOwnedProcess() async throws {
        let driver = PairingDriver(waitForPhone: true)
        let pairing = SoloistPairing(driver: driver)
        let task = Task { try await pairing.connect(replaceSession: true) { true } }
        for _ in 0..<100 where await driver.modes.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        await pairing.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await driver.closed)
    }
}

private actor PairingDriver: SoloistSetupDriving {
    let waitForPhone: Bool
    private(set) var modes: [Bool] = []
    private(set) var closed = false
    init(waitForPhone: Bool = false) { self.waitForPhone = waitForPhone }
    func startSetup(
        replaceSession: Bool, epoch: UInt64,
        receive: @escaping @Sendable (SoloistInput) async -> Void
    ) async throws {
        modes.append(replaceSession)
        if replaceSession {
            if !waitForPhone { await receive(.exited(0, epoch: epoch)) }
        } else {
            let frame = try SoloistFrame.decode(
                Data(#"{"type":"auth_state","logged_in":true}"#.utf8))
            await receive(.frame(frame, epoch: epoch))
        }
    }
    func start(
        uri: String, epoch: UInt64, receive: @escaping @Sendable (SoloistInput) async -> Void
    ) async throws { throw SoloistFailure.invalidCommand }
    func send(_ command: SoloistCommand) async throws { throw SoloistFailure.invalidCommand }
    func stop() async {}
    func close() async { closed = true }
}
