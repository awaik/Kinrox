import Foundation
import Testing

@testable import RemoteProtocol

@Suite("Session error contracts after M4.2 review")
@MainActor struct SessionContractTests {
    @Test("Closed channel does not offer to send reply to incompatible version")
    func incompatibleSecureVersion() throws {
        let (sender, receiver) = try channels()
        let raw = envelope(type: "bye", version: 2)
        let failure = try #require(throws: SessionFailure.self) {
            try receiver.open(sender.sealBytes(raw))
        }
        #expect(failure.error.code == .incompatibleVersion)
        #expect(failure.error.replyTo == FixtureSamples.id)
        #expect(failure.shouldCloseConnection)
        #expect(!failure.canSendResponse)
        #expect(receiver.isClosed)
    }

    @Test(
        "Local seal error does not require network response",
        arguments: [65_509, 65_536, 65_537, -1])
    func invalidOutbound(_ size: Int) throws {
        let (sender, _) = try channels()
        func errorMessage(_ count: Int) -> Message {
            .error(.init(), .init(code: .internal, message: String(repeating: "a", count: count)))
        }
        let overhead = try Codec.encode(errorMessage(0)).count
        let message: Message =
            size < 0 ? .command(.init(), .setVolume(volume: 101)) : errorMessage(size - overhead)
        let failure = try #require(throws: SessionFailure.self) { try sender.seal(message) }
        #expect(failure.error.code == .invalidPayload)
        #expect(failure.shouldCloseConnection)
        #expect(!failure.canSendResponse)
        #expect(sender.isClosed)
    }

    @Test(
        "Corrupted handshake after cutover closes channel before body parsing",
        arguments: [
            "hello", "helloAck", "pairRequest", "pairChallenge", "pairProof", "auth", "paired",
            "authOk",
        ])
    func malformedHandshakeAfterCutover(_ type: String) throws {
        let (sender, receiver) = try channels()
        let failure = try #require(throws: SessionFailure.self) {
            try receiver.open(sender.sealBytes(envelope(type: type)))
        }
        #expect(failure.error.code == .invalidPayload)
        #expect(failure.shouldCloseConnection)
        #expect(!failure.canSendResponse)
        #expect(receiver.isClosed)
    }

    @Test(
        "Corrupted protected envelope closes channel",
        arguments: [
            "{", "{}", "null", "[]", #"{"v":1,"type":"command","body":{}}"#,
            #"{"v":1,"id":"6F1C0000-0000-4000-8000-000000000001","type":"command"}"#,
        ])
    func malformedSecureEnvelope(_ json: String) throws {
        let (sender, receiver) = try channels()
        let failure = try #require(throws: SessionFailure.self) {
            try receiver.open(sender.sealBytes(Data(json.utf8)))
        }
        #expect(failure.error.code == .invalidPayload)
        #expect(failure.shouldCloseConnection)
        #expect(!failure.canSendResponse)
        #expect(receiver.isClosed)
    }

    @Test(
        "Application error preserves ability for encrypted response and next frame",
        arguments: ["unknownType", "unknownCommand", "invalidCommand"])
    func recoverableApplicationError(_ scenario: String) throws {
        let (sender, receiver) = try channels()
        let raw = envelope(
            type: scenario == "unknownType" ? "futureMessage" : "command",
            body: scenario == "invalidCommand"
                ? #"{"kind":"setVolume","volume":101}"# : #"{"kind":"futureCommand"}"#)
        let failure = try #require(throws: SessionFailure.self) {
            try receiver.open(sender.sealBytes(raw))
        }
        #expect(
            failure.error.code == (scenario == "invalidCommand" ? .invalidPayload : .unknownMessage)
        )
        #expect(failure.error.replyTo == FixtureSamples.id)
        #expect(!failure.shouldCloseConnection)
        #expect(failure.canSendResponse)
        #expect(!receiver.isClosed)
        let reply = Message.error(.init(), failure.error)
        #expect(try sender.open(receiver.seal(reply)) == reply)
        let next = Message.requestState(.init())
        #expect(try receiver.open(sender.seal(next)) == next)
    }

    @Test(
        "Authorization is checked before command kind and parameters",
        arguments: ["hello", "key", "proof"])
    func unauthorizedCommand(_ stage: String) throws {
        let h = try HandshakeHarness()
        if stage == "key" { try h.exchangeHello() }
        if stage == "proof" { try h.beginPairing() }
        for body in [#"{"kind":"futureCommand"}"#, #"{"kind":"setVolume","volume":101}"#, "{}"] {
            let failure = try #require(throws: SessionFailure.self) {
                try h.server.receive(envelope(type: "command", body: body))
            }
            #expect(failure.error.code == .notPaired)
            #expect(failure.error.replyTo == FixtureSamples.id)
            #expect(!failure.shouldCloseConnection)
            #expect(failure.canSendResponse)
        }
        if stage == "hello" { try h.beginPairing() }
        if stage == "key" {
            guard case .pairingChallenge(_, let frame) = try h.server.receive(h.key),
                case .enterPIN = try h.client.receive(frame)
            else { throw HandshakeHarness.HarnessError.event }
        }
        guard case .authenticated = try h.client.receive(h.finishFrame()) else {
            throw HandshakeHarness.HarnessError.event
        }
        _ = try h.server.finishSent()
    }

    @Test("Server does not reply error to incoming error", arguments: [false, true])
    func incomingError(_ malformed: Bool) throws {
        let h = try HandshakeHarness()
        try h.beginPairing()
        let raw = envelope(
            type: "error", body: malformed ? "{}" : #"{"code":"internal","message":""}"#)
        let failure = try #require(throws: SessionFailure.self) { try h.server.receive(raw) }
        #expect(failure.shouldCloseConnection)
        #expect(!failure.canSendResponse)
        #expect(h.storage.records.isEmpty)
    }

    @Test(
        "notPaired does not bypass version and envelope structure checks", arguments: [false, true])
    func invalidUnauthorizedEnvelope(_ incompatible: Bool) throws {
        let h = try HandshakeHarness()
        let raw =
            incompatible
            ? envelope(type: "command", version: 2)
            : Data(#"{"v":1,"type":"command","body":{}}"#.utf8)
        let failure = try #require(throws: SessionFailure.self) { try h.server.receive(raw) }
        #expect(failure.error.code == (incompatible ? .incompatibleVersion : .invalidPayload))
        #expect(failure.shouldCloseConnection)
        #expect(h.storage.records.isEmpty)
    }

    @Test("Rejection of expired PIN returns timeout")
    func expiredRejection() throws {
        let h = try HandshakeHarness()
        try h.beginPairing()
        h.storage.instant = h.storage.instant.advanced(by: .seconds(120))
        let rejection: SessionFailure? = h.server.rejectPairing()
        let failure = try #require(rejection)
        #expect(failure.error.code == .pairingTimeout)
        #expect(failure.shouldCloseConnection)
        #expect(failure.canSendResponse)
        #expect(h.storage.records.isEmpty)
        #expect(h.server.rejectPairing() == nil)
    }

    @Test(
        "Late rejection does not close prepared or active channel",
        arguments: [false, true])
    func lateRejection(_ sent: Bool) throws {
        let h = try HandshakeHarness()
        try h.beginPairing()
        let finish = try h.finishFrame()
        let earlyChannel = sent ? try h.server.finishSent() : nil
        h.storage.instant = h.storage.instant.advanced(by: .seconds(121))
        let failure: SessionFailure? = h.server.rejectPairing()
        #expect(failure == nil)
        let server = try earlyChannel ?? h.server.finishSent()
        guard case .authenticated(_, let client) = try h.client.receive(finish) else {
            throw HandshakeHarness.HarnessError.event
        }
        #expect(!server.isClosed)
        let request = Message.requestState(.init())
        #expect(try server.open(client.seal(request)) == request)
    }

    @Test("Rejection outside PIN wait changes nothing", arguments: ["hello", "key", "closed"])
    func rejectionOutsidePairing(_ stage: String) throws {
        let h = try HandshakeHarness()
        if stage == "key" { try h.exchangeHello() }
        if stage == "closed" { h.server.close() }
        let failure: SessionFailure? = h.server.rejectPairing()
        #expect(failure == nil)
        if stage == "hello" { try h.beginPairing() }
        if stage == "key" {
            guard case .pairingChallenge = try h.server.receive(h.key) else {
                throw HandshakeHarness.HarnessError.event
            }
        }
    }

    private func channels() throws -> (SecureChannel, SecureChannel) {
        let keys = try CryptoVector.load().keys()
        let sender = SecureChannel(keys: keys, role: .client)
        let receiver = SecureChannel(keys: keys, role: .server)
        sender.activate()
        receiver.activate()
        return (sender, receiver)
    }

    @Test("Corrupted protected error closes channel without response")
    func malformedSecureError() throws {
        let (sender, receiver) = try channels()
        let failure = try #require(throws: SessionFailure.self) {
            try receiver.open(sender.sealBytes(envelope(type: "error")))
        }
        #expect(failure.shouldCloseConnection)
        #expect(!failure.canSendResponse)
        #expect(receiver.isClosed)
    }

    private func envelope(type: String, body: String = "{}", version: Int = 1) -> Data {
        Data(
            "{\"v\":\(version),\"id\":\"\(FixtureSamples.id)\",\"type\":\"\(type)\",\"body\":\(body)}"
                .utf8)
    }
}
