import CryptoKit
import Foundation
import Testing

@testable import RemoteProtocol

@MainActor final class HandshakeStorage {
    var token: Data?
    var records: [ServerHandshake.PairingRecord] = []
    var failSave = false
    var instant = ContinuousClock.now

    func save(_ record: ServerHandshake.PairingRecord) throws {
        if failSave { throw SessionFailure(.internal) }
        records.append(record)
        token = record.token
    }
}

@MainActor final class HandshakeHarness {
    let vector: CryptoVector
    let storage: HandshakeStorage
    let client: ClientHandshake
    let server: ServerHandshake
    var hello = Data()
    var ack = Data()
    var key = Data()
    var proof = Data()
    let pairing: Bool

    init(
        pairing: Bool = true, token: Data? = nil, storedToken: Data? = nil,
        gate: PairingGate = PairingGate(), expectedServerId: UUID? = nil,
        authServerId: UUID = FixtureSamples.serverId
    ) throws {
        vector = try CryptoVector.load(pairing ? 0 : 1)
        let vector = vector
        self.pairing = pairing
        let storage = HandshakeStorage()
        storage.token = storedToken
        self.storage = storage
        client = ClientHandshake(
            deviceId: FixtureSamples.deviceId, deviceName: "Remote", appVersion: "1.0",
            mode: pairing
                ? .pair
                : .authenticate(token: token ?? Data(hex: vector.token), serverId: authServerId),
            expectedServerId: expectedServerId,
            privateKey: try .init(rawRepresentation: Data(hex: vector.clientPrivate)))
        server = ServerHandshake(
            serverId: FixtureSamples.serverId, serverName: "Mac", pairingGate: gate,
            loadToken: { _ in storage.token }, saveToken: { try storage.save($0) },
            privateKey: try .init(rawRepresentation: Data(hex: vector.serverPrivate)),
            nonce: CryptoBytes.random32(),
            now: { storage.instant }, makePIN: { vector.pin },
            makeToken: { Data(hex: vector.token) })
    }

    func exchangeHello() throws {
        hello = try client.start()
        guard case .send(let data) = try server.receive(hello) else { throw HarnessError.event }
        ack = data
        guard case .send(let data) = try client.receive(ack) else { throw HarnessError.event }
        key = data
    }

    func beginPairing() throws {
        try exchangeHello()
        guard case .pairingChallenge(let pin, let frame) = try server.receive(key) else {
            throw HarnessError.event
        }
        #expect(pin == vector.pin)
        guard case .enterPIN = try client.receive(frame) else { throw HarnessError.event }
    }

    func finishFrame() throws -> Data {
        let incoming: Data
        if pairing {
            proof = try client.submitPIN(vector.pin)
            incoming = proof
        } else {
            incoming = key
        }
        guard case .sendFinish(let frame) = try server.receive(incoming) else {
            throw HarnessError.event
        }
        return frame
    }

    func keys() throws -> HandshakeKeys {
        try HandshakeKeys(
            transcript: HandshakeTranscript(
                hello: Codec.decode(hello),
                acknowledgement: Codec.decode(ack), keyMessage: Codec.decode(key)),
            privateKey: .init(rawRepresentation: Data(hex: vector.clientPrivate)), role: .client)
    }

    func errorFrame(_ failure: SessionFailure) throws -> Data {
        try Codec.encode(.error(.init(), failure.error))
    }

    enum HarnessError: Error { case event }
}
