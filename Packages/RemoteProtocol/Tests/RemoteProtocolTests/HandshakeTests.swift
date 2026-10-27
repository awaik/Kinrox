import Foundation
import Testing

@testable import RemoteProtocol

@Suite("Handshake state machines without network")
@MainActor struct HandshakeTests {
    @Test("Pairing and auth establish bidirectional channel", arguments: [true, false])
    func success(_ pairing: Bool) throws {
        let token = Data(hex: try CryptoVector.load().token)
        let h = try HandshakeHarness(pairing: pairing, storedToken: pairing ? nil : token)
        if pairing { try h.beginPairing() } else { try h.exchangeHello() }
        let frame = try h.finishFrame()
        #expect(frame.prefix(12) == Data(repeating: 0, count: 12))
        #expect(h.storage.records.count == (pairing ? 1 : 0))
        guard case .authenticated(let received, let client) = try h.client.receive(frame) else {
            Issue.record("No server confirmation")
            return
        }
        #expect(received == (pairing ? token : nil))
        let server = try h.server.finishSent()
        let command = Message.command(.init(), .seekRelative(seconds: 30))
        let commandFrame = try client.seal(command)
        #expect(commandFrame.prefix(12) == Data(repeating: 0, count: 12))
        #expect(try server.open(commandFrame) == command)
        let reply = Message.ack(.init(), .init(replyTo: command.header.id))
        let response = try server.seal(reply)
        #expect(response.prefix(12) == Data(hex: "000000000000000000000001"))
        #expect(try client.open(response) == reply)
        h.client.close()
        h.server.close()
        #expect(client.isClosed && server.isClosed)
    }

    @Test("Two PIN errors allow retry, third closes", arguments: [false, true])
    func attempts(_ eventuallyCorrect: Bool) throws {
        let h = try HandshakeHarness()
        try h.beginPairing()
        var previousId: UUID?
        for index in 1...3 {
            let input = try h.client.submitPIN(
                index == 3 && eventuallyCorrect ? h.vector.pin : "123456")
            let id = try Codec.decode(input).header.id
            #expect(id != previousId)
            previousId = id
            if index == 3 && eventuallyCorrect {
                guard case .sendFinish(let frame) = try h.server.receive(input) else {
                    Issue.record("No success")
                    return
                }
                guard case .authenticated = try h.client.receive(frame) else {
                    Issue.record("No channel")
                    return
                }
                _ = try h.server.finishSent()
            } else {
                let failure = try #require(throws: SessionFailure.self) {
                    try h.server.receive(input)
                }
                #expect(failure.error.replyTo == id)
                #expect(failure.error.code == (index == 3 ? .tooManyAttempts : .authFailed))
                #expect(failure.shouldCloseConnection == (index == 3))
                if index < 3 {
                    guard case .retryPIN = try h.client.receive(h.errorFrame(failure)) else {
                        Issue.record("No retry")
                        return
                    }
                } else {
                    #expect(throws: SessionFailure.self) {
                        try h.client.receive(h.errorFrame(failure))
                    }
                    #expect(throws: SessionFailure.self) { try h.client.submitPIN(h.vector.pin) }
                }
            }
        }
        #expect(h.storage.records.count == (eventuallyCorrect ? 1 : 0))
    }

    @Test("Proof retry also consumes an attempt")
    func replayProof() throws {
        let h = try HandshakeHarness()
        try h.beginPairing()
        let proof = try h.client.submitPIN("123456")
        for index in 1...3 {
            let failure = try #require(throws: SessionFailure.self) { try h.server.receive(proof) }
            #expect(failure.error.code == (index == 3 ? .tooManyAttempts : .authFailed))
        }
        #expect(h.storage.records.isEmpty)
    }

    @Test("120s timeout is not extended by error; checked without inbound frame")
    func expiry() throws {
        let h = try HandshakeHarness()
        try h.beginPairing()
        h.storage.instant = h.storage.instant.advanced(by: .seconds(119))
        let wrong = try h.client.submitPIN("123456")
        let first = try #require(throws: SessionFailure.self) { try h.server.receive(wrong) }
        guard case .retryPIN = try h.client.receive(h.errorFrame(first)) else {
            Issue.record("No retry")
            return
        }
        h.storage.instant = h.storage.instant.advanced(by: .seconds(1))
        let failure = try #require(throws: SessionFailure.self) { try h.server.checkDeadline() }
        #expect(failure.error.code == .pairingTimeout)
        let remote = try #require(throws: SessionFailure.self) {
            try h.client.receive(h.errorFrame(failure))
        }
        #expect(remote.error.code == .pairingTimeout)
        #expect(h.storage.records.isEmpty)
    }

    @Test("Shared gate, owner rejection, and release on close")
    func pairingGate() throws {
        let gate = PairingGate()
        let first = try HandshakeHarness(gate: gate)
        try first.beginPairing()
        let second = try HandshakeHarness(gate: gate)
        try second.exchangeHello()
        let busy = try #require(throws: SessionFailure.self) {
            try second.server.receive(second.key)
        }
        #expect(busy.error.code == .pairingRejected)
        let rejected = try #require(first.server.rejectPairing())
        let error = try #require(throws: SessionFailure.self) {
            try first.client.receive(first.errorFrame(rejected))
        }
        #expect(error.error.code == .pairingRejected)
        let third = try HandshakeHarness(gate: gate)
        try third.beginPairing()
        third.server.close()
        let fourth = try HandshakeHarness(gate: gate)
        try fourth.beginPairing()
    }

    @Test("Write error does not send success and preserves old token")
    func persistenceFailure() throws {
        let old = Data(repeating: 77, count: 32)
        let h = try HandshakeHarness(storedToken: old)
        h.storage.failSave = true
        try h.beginPairing()
        let failure = try #require(throws: SessionFailure.self) { try h.finishFrame() }
        #expect(failure.error.code == .internal)
        #expect(h.storage.token == old)
        #expect(h.storage.records.isEmpty)
        #expect(throws: SessionFailure.self) { try h.server.finishSent() }
    }

    @Test(
        "Missing/foreign token equally rejected without PIN transition", arguments: [false, true])
    func wrongToken(_ missing: Bool) throws {
        let token = Data(hex: try CryptoVector.load().token)
        let h = try HandshakeHarness(
            pairing: false, token: token,
            storedToken: missing ? nil : Data(repeating: 99, count: 32))
        try h.exchangeHello()
        let failure = try #require(throws: SessionFailure.self) { try h.server.receive(h.key) }
        #expect(failure.error.code == .authFailed)
        #expect(failure.shouldCloseConnection)
        let clientError = try #require(throws: SessionFailure.self) {
            try h.client.receive(h.errorFrame(failure))
        }
        #expect(clientError.error.code == .authFailed)
        #expect(throws: SessionFailure.self) { try h.client.submitPIN(h.vector.pin) }
        #expect(throws: SessionFailure.self) {
            try h.server.receive(
                Codec.encode(
                    .pairRequest(
                        .init(), .init(clientPublicKey: h.vector.keys().transcript.clientPublicKey))
                ))
        }
        #expect(h.storage.records.isEmpty)
    }

    @Test("Commands before proof are not executed, success cannot be confirmed in advance")
    func unauthenticatedCommand() throws {
        let h = try HandshakeHarness()
        let command = try Codec.encode(Message.command(.init(), .togglePause))
        for advance in [false, true] {
            if advance { try h.beginPairing() }
            let failure = try #require(throws: SessionFailure.self) {
                try h.server.receive(command)
            }
            #expect(failure.error.code == .notPaired)
            #expect(!failure.shouldCloseConnection)
        }
        #expect(h.storage.records.isEmpty)
        #expect(throws: SessionFailure.self) { try h.server.finishSent() }
    }

    @Test("After confirmation prep, input is disallowed until finishSent")
    func pendingFinish() throws {
        let h = try HandshakeHarness()
        try h.beginPairing()
        _ = try h.finishFrame()
        let failure = try #require(throws: SessionFailure.self) {
            try h.server.receive(Codec.encode(.command(.init(), .togglePause)))
        }
        #expect(failure.shouldCloseConnection)
        #expect(throws: SessionFailure.self) { try h.server.finishSent() }
    }
}
