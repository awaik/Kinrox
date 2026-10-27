import Foundation
import Testing

@testable import RemoteProtocol

@Suite("Tampering and handshake ordering")
@MainActor struct HandshakeAttackTests {
    @Test("AEAD does not substitute serverProof", arguments: [true, false])
    func falseServer(_ pairing: Bool) throws {
        for attack in [
            "wrongProof", "missingProof", "plaintext", "state", "recent", "nonce", "tag", "short",
            "wrongType", "token",
        ] {
            if !pairing && attack == "token" { continue }
            let token = Data(hex: try CryptoVector.load().token)
            let h = try HandshakeHarness(pairing: pairing, storedToken: pairing ? nil : token)
            if pairing { try h.beginPairing() } else { try h.exchangeHello() }
            let genuine = try h.finishFrame()
            let keys = try h.keys()
            let inspector = SecureChannel(keys: keys, role: .client)
            let message = try inspector.openHandshake(genuine)
            let impostor = SecureChannel(keys: keys, role: .server)
            let frame: Data
            switch attack {
            case "wrongProof":
                frame = try impostor.sealBytes(
                    mutateJSON(
                        Codec.encode(message), field: "serverProof",
                        value: Data(repeating: 77, count: 32).base64EncodedString()))
            case "missingProof":
                frame = try impostor.sealBytes(
                    mutateJSON(Codec.encode(message), field: "serverProof", value: nil))
            case "plaintext": frame = try Codec.encode(message)
            case "state": frame = try impostor.sealHandshake(.state(.init(), FixtureSamples.state))
            case "recent": frame = try impostor.sealHandshake(.recent(.init(), []))
            case "nonce":
                _ = try impostor.sealHandshake(message)
                frame = try impostor.sealHandshake(message)
            case "tag":
                var changed = genuine
                changed[changed.count - 1] ^= 1
                frame = changed
            case "short": frame = Data([0, 123, 125])
            case "token":
                frame = try impostor.sealBytes(
                    mutateJSON(
                        Codec.encode(message), field: "token",
                        value: Data(repeating: 77, count: 32).base64EncodedString()))
            default:
                let wrong: Message =
                    pairing
                    ? .authOk(.init(), .init(serverProof: Data(repeating: 0, count: 32)))
                    : .paired(
                        .init(), .init(token: token, serverProof: Data(repeating: 0, count: 32)))
                frame = try impostor.sealHandshake(wrong)
            }
            let failure = try #require(throws: SessionFailure.self) { try h.client.receive(frame) }
            #expect(failure.shouldCloseConnection)
            #expect(!failure.canSendResponse)
            if ["wrongProof", "token", "nonce", "tag"].contains(attack) {
                #expect(failure.error.code == .authFailed)
            }
            // Neither genuine replay nor JSON error should resurrect state machine.
            #expect(throws: SessionFailure.self) { try h.client.receive(genuine) }
            #expect(throws: SessionFailure.self) {
                try h.client.receive(
                    Codec.encode(.error(.init(), .init(code: .authFailed, message: ""))))
            }
        }
    }

    @Test("No JSON fallback for AEAD candidate")
    func noFallback() throws {
        let h = try HandshakeHarness()
        try h.beginPairing()
        let proof = try h.client.submitPIN("123456")
        let id = try Codec.decode(proof).header.id
        let error = try Codec.encode(
            .error(.init(), .init(replyTo: id, code: .authFailed, message: "")))
        let failure = try #require(throws: SessionFailure.self) {
            try h.client.receive(
                Data(repeating: 0, count: 12) + error + Data(repeating: 0, count: 16))
        }
        #expect(failure.error.code == .authFailed)
        #expect(failure.shouldCloseConnection)
        #expect(throws: SessionFailure.self) { try h.client.submitPIN(h.vector.pin) }
    }

    @Test("Mac ID is verified against Bonjour and saved server", arguments: [true, false])
    func identity(_ bonjour: Bool) throws {
        let h = try HandshakeHarness(
            pairing: bonjour,
            expectedServerId: bonjour ? UUID() : nil,
            authServerId: bonjour ? FixtureSamples.serverId : UUID())
        let failure = try #require(throws: SessionFailure.self) { try h.exchangeHello() }
        #expect(failure.error.code == .authFailed)
        #expect(failure.shouldCloseConnection)
    }

    @Test("Server selected version is validated")
    func selectedVersion() throws {
        let h = try HandshakeHarness()
        let hello = try h.client.start()
        guard case .send(let ack) = try h.server.receive(hello) else {
            Issue.record("No helloAck")
            return
        }
        let failure = try #require(throws: SessionFailure.self) {
            try h.client.receive(mutateJSON(ack, field: "version", value: 2))
        }
        #expect(failure.error.code == .incompatibleVersion)
    }

    @Test("auth.deviceId must match hello.deviceId")
    func changedDevice() throws {
        let token = Data(hex: try CryptoVector.load().token)
        let h = try HandshakeHarness(pairing: false, storedToken: token)
        try h.exchangeHello()
        let failure = try #require(throws: SessionFailure.self) {
            try h.server.receive(mutateJSON(h.key, field: "deviceId", value: UUID().uuidString))
        }
        #expect(failure.error.code == .invalidPayload)
    }

    @Test("PIN MAC binds UUID of pairProof")
    func changedProofId() throws {
        let h = try HandshakeHarness()
        try h.beginPairing()
        let proof = try h.client.submitPIN(h.vector.pin)
        let failure = try #require(throws: SessionFailure.self) {
            try h.server.receive(mutateJSON(proof, field: "id", value: UUID().uuidString))
        }
        #expect(failure.error.code == .authFailed)
        #expect(!failure.shouldCloseConnection)
        #expect(h.storage.records.isEmpty)
    }

    @Test(
        "Plaintext error does not authenticate, replyTo and code verified",
        arguments: ["id", "code"])
    func unexpectedError(_ attack: String) throws {
        let h = try HandshakeHarness()
        try h.beginPairing()
        let proof = try h.client.submitPIN(h.vector.pin)
        let error = Message.error(
            .init(),
            .init(
                replyTo: attack == "id" ? UUID() : try Codec.decode(proof).header.id,
                code: attack == "code" ? .noMedia : .authFailed, message: ""))
        let failure = try #require(throws: SessionFailure.self) {
            try h.client.receive(Codec.encode(error))
        }
        #expect(failure.error.code == .invalidPayload)
    }

    @Test(
        "Replay hello, proof before challenge, and mode change close server",
        arguments: ["hello", "proof", "mode", "malformed"])
    func order(_ attack: String) throws {
        let h = try HandshakeHarness()
        try h.exchangeHello()
        let frame: Data
        switch attack {
        case "hello": frame = h.hello
        case "proof":
            frame = try Codec.encode(
                .pairProof(.init(), .init(proof: Data(repeating: 0, count: 32))))
        case "mode":
            _ = try h.server.receive(h.key)
            frame = try Codec.encode(
                .auth(
                    .init(),
                    .init(
                        deviceId: FixtureSamples.deviceId,
                        clientPublicKey: Data(repeating: 1, count: 32),
                        proof: Data(repeating: 0, count: 32))))
        default: frame = Data("{".utf8)
        }
        let failure = try #require(throws: SessionFailure.self) { try h.server.receive(frame) }
        #expect(failure.error.code == .invalidPayload)
        #expect(failure.shouldCloseConnection)
        #expect(h.storage.records.isEmpty)
    }

    @Test("Client accepts only helloAck then challenge; start is one-shot")
    func clientOrder() throws {
        for stage in 0...2 {
            let h = try HandshakeHarness()
            if stage == 0 { _ = try h.client.start() } else { try h.exchangeHello() }
            if stage == 2 {
                #expect(throws: SessionFailure.self) { try h.client.start() }
            } else {
                let frame = try Codec.encode(
                    stage == 0 ? Message.pairChallenge(.init()) : Codec.decode(h.ack))
                let failure = try #require(throws: SessionFailure.self) {
                    try h.client.receive(frame)
                }
                #expect(failure.error.code == .invalidPayload)
            }
        }
    }

    @Test("New session rejects proof of previous session even with same test private keys")
    func crossSessionProof() throws {
        let first = try HandshakeHarness()
        try first.beginPairing()
        let oldProof = try first.client.submitPIN(first.vector.pin)
        first.server.close()
        let second = try HandshakeHarness()
        try second.beginPairing()
        let failure = try #require(throws: SessionFailure.self) {
            try second.server.receive(oldProof)
        }
        #expect(failure.error.code == .authFailed)
        #expect(second.storage.records.isEmpty)
    }

    @Test("Public constructors produce fresh nonces and ephemeral keys")
    func freshConnections() throws {
        var nonces = Set<Data>()
        var keys = Set<Data>()
        for _ in 0..<2 {
            let client = ClientHandshake(
                deviceId: FixtureSamples.deviceId, deviceName: "Remote", appVersion: "1",
                mode: .pair
            )
            let server = ServerHandshake(
                serverId: FixtureSamples.serverId, serverName: "Mac", pairingGate: PairingGate(),
                loadToken: { _ in nil }, saveToken: { _ in })
            guard case .send(let ack) = try server.receive(client.start()),
                case .helloAck(_, let body) = try Codec.decode(ack),
                case .send(let request) = try client.receive(ack),
                case .pairRequest(_, let key) = try Codec.decode(request)
            else {
                Issue.record("Handshake did not begin")
                return
            }
            nonces.insert(body.nonce)
            keys.insert(body.serverPublicKey)
            keys.insert(key.clientPublicKey)
        }
        #expect(nonces.count == 2)
        #expect(keys.count == 4)
    }
}
