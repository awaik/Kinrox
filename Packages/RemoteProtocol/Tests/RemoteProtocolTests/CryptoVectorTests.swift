import CryptoKit
import Foundation
import Testing

@testable import RemoteProtocol

struct CryptoVector: Decodable {
    let mode: Int
    let hello: Message
    let helloAck: Message
    let keyMessage: Message
    let pairProofId: UUID
    let finish: Message
    let command: Message
    let clientPrivate: String
    let serverPrivate: String
    let sharedSecret: String
    let pin: String
    let token: String
    let transcript: String
    let hash: String
    let c2s: String
    let s2c: String
    let confirmation: String
    let proofKey: String
    let clientProof: String
    let serverProof: String
    let clientFrame: String
    let serverFrame: String

    static func load(_ mode: Int = 0) throws -> CryptoVector {
        let url = Bundle.module.resourceURL!.appending(path: "Fixtures/crypto/v1.json")
        return try JSONDecoder().decode([CryptoVector].self, from: Data(contentsOf: url))[mode]
    }

    func keys(_ role: SecureChannel.Role = .client) throws -> HandshakeKeys {
        try HandshakeKeys(
            transcript: HandshakeTranscript(
                hello: hello,
                acknowledgement: helloAck, keyMessage: keyMessage),
            privateKey: Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: Data(hex: role == .client ? clientPrivate : serverPrivate)),
            role: role)
    }
}

extension Data {
    init(hex: String) {
        let chars = Array(hex)
        self.init(
            stride(from: 0, to: chars.count, by: 2).map {
                UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
            })
    }
}

@Suite("Independent OpenSSL/Python vectors")
struct CryptoVectorTests {
    @Test("Transcript, ECDH, HKDF, both MACs and first frames", arguments: [0, 1])
    @MainActor func vectors(_ mode: Int) throws {
        let v = try CryptoVector.load(mode)
        let keys = try v.keys()
        let peer = try v.keys(.server)
        #expect(keys.transcript.bytes == Data(hex: v.transcript))
        #expect(keys.transcript.hash == Data(hex: v.hash))
        #expect(keys.clientToServer.withUnsafeBytes { Data($0) } == Data(hex: v.c2s))
        #expect(keys.serverToClient.withUnsafeBytes { Data($0) } == Data(hex: v.s2c))
        #expect(keys.confirmation.withUnsafeBytes { Data($0) } == Data(hex: v.confirmation))
        #expect(keys.clientToServer == peer.clientToServer)
        #expect(keys.serverToClient == peer.serverToClient)
        #expect(keys.confirmation == peer.confirmation)
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(hex: v.clientPrivate))
        let publicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: keys.transcript.acknowledgement.serverPublicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        #expect(secret.withUnsafeBytes { Data($0) } == Data(hex: v.sharedSecret))
        let proofKey = try mode == 0 ? keys.pinKey(v.pin) : keys.authServerKey(Data(hex: v.token))
        #expect(proofKey.withUnsafeBytes { Data($0) } == Data(hex: v.proofKey))
        let clientInput = mode == 0 ? keys.pairClientInput(v.pairProofId) : keys.authClientInput
        let clientKey = mode == 0 ? proofKey : SymmetricKey(data: Data(hex: v.token))
        #expect(HandshakeKeys.mac(clientInput, key: clientKey) == Data(hex: v.clientProof))
        let serverInput =
            mode == 0
            ? keys.pairServerInput(
                v.pairProofId, proof: Data(hex: v.clientProof), token: Data(hex: v.token))
            : keys.authServerInput(Data(hex: v.clientProof))
        #expect(HandshakeKeys.mac(serverInput, key: proofKey) == Data(hex: v.serverProof))
        #expect(HandshakeKeys.verify(Data(hex: v.serverProof), input: serverInput, key: proofKey))
        let client = SecureChannel(keys: keys, role: .client)
        let server = SecureChannel(keys: peer, role: .server)
        #expect(try server.sealHandshake(v.finish) == Data(hex: v.serverFrame))
        #expect(try client.openHandshake(Data(hex: v.serverFrame)) == v.finish)
        client.activate()
        server.activate()
        #expect(try client.seal(v.command) == Data(hex: v.clientFrame))
        #expect(try server.open(Data(hex: v.clientFrame)) == v.command)
    }

    @Test("Every transcript field is bound to confirmation", arguments: [0, 1])
    func transcriptMutations(_ mode: Int) throws {
        let v = try CryptoVector.load(mode)
        let original = try v.keys()
        let mutations: [(Int, String, Any)] = [
            (0, "v", 2), (0, "id", UUID().uuidString), (0, "minVersion", 2),
            (0, "maxVersion", 4), (0, "deviceId", UUID().uuidString),
            (0, "deviceName", "iPhone"), (0, "appVersion", "1.1"),
            (1, "v", 2), (1, "id", UUID().uuidString), (1, "version", 2),
            (1, "serverId", UUID().uuidString), (1, "serverName", "Mac é"),
            (1, "needsPairing", mode != 0),
            (1, "serverPublicKey", Data(repeating: 7, count: 32).base64EncodedString()),
            (1, "nonce", Data(repeating: 7, count: 32).base64EncodedString()),
            (2, "v", 2), (2, "id", UUID().uuidString),
            (2, "clientPublicKey", Data(repeating: 7, count: 32).base64EncodedString()),
        ]
        for (index, field, value) in mutations {
            var messages = [v.hello, v.helloAck, v.keyMessage]
            do {
                messages[index] = try mutate(messages[index], field: field, value: value)
                let t = try HandshakeTranscript(
                    hello: messages[0], acknowledgement: messages[1], keyMessage: messages[2])
                #expect(t.bytes != original.transcript.bytes)
                #expect(t.hash != original.transcript.hash)
                let input =
                    (mode == 0
                        ? CryptoBytes.label("pair/client") : CryptoBytes.label("auth/client"))
                    + t.bytes + (mode == 0 ? CryptoBytes.uuid(v.pairProofId) : Data())
                let key =
                    try mode == 0 ? original.pinKey(v.pin) : SymmetricKey(data: Data(hex: v.token))
                #expect(!HandshakeKeys.verify(Data(hex: v.clientProof), input: input, key: key))
            } catch {
                #expect(error is SessionFailure || error is Codec.Failure || error is ProtocolError)
            }
        }
        let alternate: Message =
            mode == 0
            ? .auth(
                v.keyMessage.header,
                .init(
                    deviceId: original.transcript.hello.deviceId,
                    clientPublicKey: original.transcript.clientPublicKey,
                    proof: Data(repeating: 0, count: 32)))
            : .pairRequest(
                v.keyMessage.header, .init(clientPublicKey: original.transcript.clientPublicKey))
        let changedMode = try HandshakeTranscript(
            hello: v.hello, acknowledgement: v.helloAck, keyMessage: alternate)
        #expect(changedMode.hash != original.transcript.hash)
        let unknown = try mutate(v.hello, field: "future", value: true)
        #expect(
            try HandshakeTranscript(
                hello: unknown, acknowledgement: v.helloAck,
                keyMessage: v.keyMessage
            ).bytes == original.transcript.bytes)
    }

    @Test("Zero and low-order ECDH keys are rejected", arguments: [0, 1])
    func zeroSecret(_ firstByte: UInt8) throws {
        let v = try CryptoVector.load()
        var bytes = Data(repeating: 0, count: 32)
        bytes[0] = firstByte
        let ack = try mutate(
            v.helloAck, field: "serverPublicKey", value: bytes.base64EncodedString())
        let t = try HandshakeTranscript(
            hello: v.hello, acknowledgement: ack, keyMessage: v.keyMessage)
        let error = try #require(throws: SessionFailure.self) {
            try HandshakeKeys(
                transcript: t,
                privateKey: Curve25519.KeyAgreement.PrivateKey(
                    rawRepresentation: Data(hex: v.clientPrivate)), role: .client)
        }
        #expect(error.error.code == .authFailed)
    }

    @Test(
        "PIN is exactly six ASCII digits",
        arguments: ["", "12345", "1234567", "123 456", "１２３４５６", "١٢٣٤٥٦", "12345a"])
    func invalidPIN(_ pin: String) throws {
        #expect(throws: SessionFailure.self) { try CryptoVector.load().keys().pinKey(pin) }
    }

    @Test("Generation preserves sizes and leading zeros")
    func randomness() throws {
        for _ in 0..<100 {
            let pin = CryptoBytes.randomPIN()
            #expect(pin.utf8.count == 6)
            #expect(pin.utf8.allSatisfy { (48...57).contains($0) })
            #expect(CryptoBytes.random32().count == 32)
        }
        #expect(throws: Never.self) { try CryptoVector.load().keys().pinKey("000000") }
    }
}

func mutate(_ message: Message, field: String, value: Any) throws -> Message {
    try Codec.decode(mutateJSON(Codec.encode(message), field: field, value: value))
}

func mutateJSON(_ data: Data, field: String, value: Any?) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    if ["v", "id", "type"].contains(field) {
        object[field] = value
    } else {
        var body = try #require(object["body"] as? [String: Any])
        body[field] = value
        object["body"] = body
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
