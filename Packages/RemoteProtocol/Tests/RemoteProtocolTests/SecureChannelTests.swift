import CryptoKit
import Foundation
import Testing

@testable import RemoteProtocol

@Suite("Protected frames and counters")
@MainActor struct SecureChannelTests {
    @Test(
        "Replay, omission, permutation, and corruption close channel",
        arguments: [
            "replay", "skip", "reorder", "nonce", "ciphertext", "tag", "reflection", "session",
            "direction",
        ])
    func attacks(_ attack: String) throws {
        let v = try CryptoVector.load()
        let keys = try v.keys()
        let sender = SecureChannel(keys: keys, role: .client)
        let receiver = SecureChannel(keys: keys, role: .server)
        sender.activate()
        receiver.activate()
        var frame = try sender.seal(v.command)
        switch attack {
        case "replay": _ = try receiver.open(frame)
        case "skip", "reorder": frame = try sender.seal(v.command)
        case "nonce": frame[11] ^= 1
        case "ciphertext": frame[12] ^= 1
        case "tag": frame[frame.count - 1] ^= 1
        case "reflection": frame = try receiver.seal(v.command)
        case "session":
            let nonce = Data(repeating: 9, count: 32).base64EncodedString()
            let t = try HandshakeTranscript(
                hello: v.hello, acknowledgement: mutate(v.helloAck, field: "nonce", value: nonce),
                keyMessage: v.keyMessage)
            let otherKeys = try HandshakeKeys(
                transcript: t,
                privateKey: Curve25519.KeyAgreement.PrivateKey(
                    rawRepresentation: Data(hex: v.clientPrivate)), role: .client)
            frame = try SecureChannel(keys: otherKeys, role: .client).sealHandshake(v.command)
        case "direction":
            // Valid key, invalid directional AAD is verified separately.
            frame = try ChaChaPoly.seal(
                Codec.encode(v.command), using: keys.clientToServer,
                nonce: .init(data: Data(repeating: 0, count: 12)),
                authenticating: CryptoBytes.label("frame") + keys.transcript.hash + Data([1])
            ).combined
        default: Issue.record("Unknown scenario")
        }
        let failure = try #require(throws: SessionFailure.self) { try receiver.open(frame) }
        #expect(failure.error.code == .authFailed)
        #expect(failure.shouldCloseConnection)
        #expect(!failure.canSendResponse)
        #expect(receiver.isClosed)
        #expect(throws: SessionFailure.self) { try receiver.open(Data(hex: v.clientFrame)) }
    }

    @Test("Unknown command consumes nonce, subsequent frame is accepted")
    func unknownCommand() throws {
        let v = try CryptoVector.load()
        let keys = try v.keys()
        let sender = SecureChannel(keys: keys, role: .client)
        let receiver = SecureChannel(keys: keys, role: .server)
        sender.activate()
        receiver.activate()
        let message = Message.command(v.command.header, .togglePause)
        let raw = try mutateJSON(Codec.encode(message), field: "kind", value: "futureCommand")
        let frame = try sender.sealBytes(raw)
        let failure = try #require(throws: SessionFailure.self) { try receiver.open(frame) }
        #expect(failure.error.code == .unknownMessage)
        #expect(!failure.shouldCloseConnection)
        #expect(failure.canSendResponse)
        #expect(!receiver.isClosed)
        let reply = Message.error(.init(), failure.error)
        #expect(try sender.open(receiver.seal(reply)) == reply)
        let next = try sender.seal(v.command)
        #expect(next.prefix(12) == Data(hex: "000000000000000000000001"))
        #expect(try receiver.open(next) == v.command)
    }

    @Test(
        "8, 32, 64 bit carryovers",
        arguments: [
            ("0000000000000000000000ff", "000000000000000000000100"),
            ("0000000000000000ffffffff", "000000000000000100000000"),
            ("00000000ffffffffffffffff", "000000010000000000000000"),
            ("fffffffffffffffffffffffe", "ffffffffffffffffffffffff"),
        ])
    func carries(_ initial: String, _ next: String) throws {
        let v = try CryptoVector.load()
        let keys = try v.keys()
        let counter = NonceCounter(bytes: Data(hex: initial))
        let sender = SecureChannel(keys: keys, role: .client, sendingCounter: counter)
        let receiver = SecureChannel(keys: keys, role: .server, receivingCounter: counter)
        #expect(try receiver.openBytes(sender.sealBytes(Data([7]))) == Data([7]))
        let second = try sender.sealBytes(Data([8]))
        #expect(second.prefix(12) == Data(hex: next))
        #expect(try receiver.openBytes(second) == Data([8]))
    }

    @Test("Last nonce allowed once; overflow does not reset it")
    func exhaustion() throws {
        let keys = try CryptoVector.load().keys()
        let max = Data(repeating: 255, count: 12)
        var counter = NonceCounter(bytes: max)
        counter.consume()
        #expect(counter.exhausted)
        #expect(counter.bytes == max)
        let sender = SecureChannel(keys: keys, role: .client, sendingCounter: .init(bytes: max))
        let receiver = SecureChannel(keys: keys, role: .server, receivingCounter: .init(bytes: max))
        let frame = try sender.sealBytes(Data([1]))
        #expect(frame.prefix(12) == max)
        #expect(try receiver.openBytes(frame) == Data([1]))
        for operation in [{ try sender.sealBytes(Data([2])) }, { try receiver.openBytes(frame) }] {
            let failure = try #require(throws: SessionFailure.self) { try operation() }
            #expect(failure.error.code == .authFailed)
        }
        #expect(sender.isClosed && receiver.isClosed)
    }

    @Test("Both size limits, including empty AEAD", arguments: [0, 1, 65_508])
    func frameSize(_ size: Int) throws {
        let keys = try CryptoVector.load().keys()
        let sender = SecureChannel(keys: keys, role: .client)
        let receiver = SecureChannel(keys: keys, role: .server)
        let bytes = Data(repeating: 42, count: size)
        let frame = try sender.sealBytes(bytes)
        #expect(frame.count == size + 28)
        #expect(try receiver.openBytes(frame) == bytes)
    }

    @Test("Out-of-bounds frames close before parsing", arguments: [0, 27, 65_537])
    func invalidSize(_ size: Int) throws {
        let receiver = SecureChannel(keys: try CryptoVector.load().keys(), role: .server)
        let failure = try #require(throws: SessionFailure.self) {
            try receiver.openBytes(Data(repeating: 0, count: size))
        }
        #expect(failure.error.code == .invalidPayload)
        #expect(receiver.isClosed)
        #expect(!failure.canSendResponse)
    }

    @Test("Protected JSON 65508 succeeds, 65509 is rejected")
    func messageSize() throws {
        let v = try CryptoVector.load()
        let keys = try v.keys()
        func message(_ count: Int) -> Message {
            .error(
                v.command.header,
                .init(code: .internal, message: String(repeating: "a", count: count)))
        }
        let overhead = try Codec.encode(message(0)).count
        let sender = SecureChannel(keys: keys, role: .server)
        let receiver = SecureChannel(keys: keys, role: .client)
        sender.activate()
        receiver.activate()
        let boundary = message(65_508 - overhead)
        let frame = try sender.seal(boundary)
        #expect(frame.count == 65_536)
        #expect(try receiver.open(frame) == boundary)
        let failure = try #require(throws: SessionFailure.self) {
            try sender.seal(message(65_509 - overhead))
        }
        #expect(failure.error.code == .invalidPayload)
        #expect(sender.isClosed)
    }

    @Test(
        "Close, plaintext JSON, and repeated handshake are forbidden",
        arguments: ["close", "plaintext", "hello", "beforeReady"])
    func cutover(_ scenario: String) throws {
        let v = try CryptoVector.load()
        let sender = SecureChannel(keys: try v.keys(), role: .client)
        let receiver = SecureChannel(keys: try v.keys(), role: .server)
        sender.activate()
        if scenario != "beforeReady" { receiver.activate() }
        let data: Data
        switch scenario {
        case "close":
            receiver.close()
            data = try sender.seal(v.command)
        case "plaintext": data = try Codec.encode(v.command)
        case "hello": data = try sender.sealHandshake(v.hello)
        default: data = try sender.seal(v.command)
        }
        #expect(throws: SessionFailure.self) { try receiver.open(data) }
        #expect(receiver.isClosed)
    }
}
