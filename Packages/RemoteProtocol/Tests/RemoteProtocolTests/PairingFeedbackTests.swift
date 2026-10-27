import Testing

@testable import RemoteProtocol

@Suite("Pairing messages for M5 interface")
@MainActor struct PairingFeedbackTests {
    @Test("Server reports remaining attempts, busy state differs from rejection")
    func serverFeedback() throws {
        let gate = PairingGate()
        let first = try HandshakeHarness(gate: gate)
        try first.beginPairing()
        let wrong = try first.client.submitPIN("123456")
        let failure = try #require(throws: SessionFailure.self) { try first.server.receive(wrong) }
        #expect(failure.error.message == "Incorrect code, attempts remaining: 2")
        let second = try HandshakeHarness(gate: gate)
        try second.exchangeHello()
        let busy = try #require(throws: SessionFailure.self) {
            try second.server.receive(second.key)
        }
        let rejected = try #require(first.server.rejectPairing())
        #expect(busy.error.message != rejected.error.message)
        let received = try #require(throws: SessionFailure.self) {
            try first.client.receive(first.errorFrame(rejected))
        }
        #expect(received.error.message == "Connection rejected on Mac.")
    }
}
