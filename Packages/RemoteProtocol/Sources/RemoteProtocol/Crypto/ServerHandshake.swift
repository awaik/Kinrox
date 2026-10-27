import CryptoKit
import Foundation

/// Shared instance for all connections of a server: only one PIN display at a time.
@MainActor public final class PairingGate {
    private weak var owner: ServerHandshake?
    public init() {}
    func acquire(_ candidate: ServerHandshake) -> Bool {
        guard owner == nil else { return false }
        owner = candidate
        return true
    }
    func release(_ candidate: ServerHandshake) { if owner === candidate { owner = nil } }
}

/// Persistent storage is injected by the app; actual Keychain persistence is in M4.4.
@MainActor public final class ServerHandshake {
    public struct PairingRecord: Sendable {
        public let deviceId: UUID
        public let deviceName: String
        public let token: Data
    }
    public enum Event {
        case send(Data)
        case pairingChallenge(pin: String, frame: Data)
        /// Transport transmits frame once, then calls finishSent().
        case sendFinish(Data)
    }
    private enum Stage { case hello, key, proof, finish, connected, closed }
    private var stage = Stage.hello
    private let serverId: UUID
    private let serverName: String
    private let gate: PairingGate
    private let loadToken: (UUID) throws -> Data?
    private let saveToken: (PairingRecord) throws -> Void
    private let now: () -> ContinuousClock.Instant
    private let makePIN: () -> String
    private let makeToken: () -> Data
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var nonce: Data
    private var hello: Message?
    private var acknowledgement: Message?
    private var keys: HandshakeKeys?
    private var pinKey: SymmetricKey?
    private var deadline: ContinuousClock.Instant?
    private var attempts = 0
    private var channel: SecureChannel?

    /// Received hello data is accessible until handshake temporary state is cleared.
    public var peerIdentity: Message.Hello? {
        guard case .hello(_, let body) = hello else { return nil }
        return body
    }

    public convenience init(
        serverId: UUID, serverName: String, pairingGate: PairingGate,
        loadToken: @escaping (UUID) throws -> Data?,
        saveToken: @escaping (PairingRecord) throws -> Void
    ) {
        self.init(
            serverId: serverId, serverName: serverName, pairingGate: pairingGate,
            loadToken: loadToken, saveToken: saveToken, privateKey: .init(),
            nonce: CryptoBytes.random32())
    }

    init(
        serverId: UUID, serverName: String, pairingGate: PairingGate,
        loadToken: @escaping (UUID) throws -> Data?,
        saveToken: @escaping (PairingRecord) throws -> Void,
        privateKey: Curve25519.KeyAgreement.PrivateKey, nonce: Data,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        makePIN: @escaping () -> String = { CryptoBytes.randomPIN() },
        makeToken: @escaping () -> Data = { CryptoBytes.random32() }
    ) {
        self.serverId = serverId
        self.serverName = serverName
        gate = pairingGate
        self.loadToken = loadToken
        self.saveToken = saveToken
        self.privateKey = privateKey
        self.nonce = nonce
        self.now = now
        self.makePIN = makePIN
        self.makeToken = makeToken
    }

    public func receive(_ frame: Data) throws -> Event {
        var replyTo: UUID?
        do {
            try checkDeadline()
            guard stage != .closed, stage != .connected, stage != .finish else {
                throw SessionFailure(.invalidPayload)
            }
            let envelope = try Codec.decodeEnvelope(frame)
            replyTo = envelope.header.id
            switch envelope.type {
            case .command, .requestState, .bye:
                throw SessionFailure(.notPaired, replyTo: replyTo, close: false)
            case .error:
                throw SessionFailure(.invalidPayload, respond: false)
            default: break
            }
            let message = try Codec.decode(frame)
            switch stage {
            case .hello: return try acceptHello(message)
            case .key: return try acceptKey(message)
            case .proof: return try acceptProof(message)
            default: throw SessionFailure(.invalidPayload)
            }
        } catch {
            let failure: SessionFailure
            if let value = error as? SessionFailure {
                failure = SessionFailure(
                    value.error.code, replyTo: replyTo ?? value.error.replyTo,
                    close: value.shouldCloseConnection, respond: value.canSendResponse,
                    message: value.error.message)
            } else if let value = error as? Codec.Failure {
                failure = SessionFailure(value, close: true)
            } else if let value = error as? ProtocolError {
                failure = SessionFailure(value.code, replyTo: replyTo)
            } else {
                failure = SessionFailure(.internal, replyTo: replyTo)
            }
            if failure.shouldCloseConnection { close() }
            throw failure
        }
    }

    private func acceptHello(_ message: Message) throws -> Event {
        guard case .hello(_, let body) = message, let privateKey else {
            throw SessionFailure(.invalidPayload)
        }
        let version = try Version.negotiate(
            minVersion: body.minVersion, maxVersion: body.maxVersion)
        let token = try loadToken(body.deviceId)
        let ack = Message.helloAck(
            .init(),
            .init(
                version: version, serverId: serverId,
                serverName: serverName, needsPairing: token == nil,
                serverPublicKey: privateKey.publicKey.rawRepresentation, nonce: nonce))
        let frame = try Codec.encode(ack)
        hello = message
        acknowledgement = ack
        stage = .key
        return .send(frame)
    }

    private func acceptKey(_ message: Message) throws -> Event {
        guard let hello, let acknowledgement, let privateKey else {
            throw SessionFailure(.invalidPayload)
        }
        let keys = try HandshakeKeys(
            transcript: HandshakeTranscript(
                hello: hello,
                acknowledgement: acknowledgement, keyMessage: message), privateKey: privateKey,
            role: .server)
        self.keys = keys
        self.privateKey = nil
        channel = SecureChannel(keys: keys, role: .server)
        switch message {
        case .pairRequest:
            guard gate.acquire(self) else {
                throw SessionFailure(
                    .pairingRejected,
                    message: "Another remote is already connecting to the Mac. Try again later.")
            }
            let pin = makePIN()
            pinKey = try keys.pinKey(pin)
            deadline = now().advanced(by: .seconds(120))
            stage = .proof
            return .pairingChallenge(pin: pin, frame: try Codec.encode(.pairChallenge(.init())))
        case .auth(_, let body):
            guard let token = try loadToken(body.deviceId), token.count == 32,
                HandshakeKeys.verify(
                    body.proof, input: keys.authClientInput, key: SymmetricKey(data: token))
            else { throw SessionFailure(.authFailed) }
            let proof = HandshakeKeys.mac(
                keys.authServerInput(body.proof), key: try keys.authServerKey(token))
            return try prepareFinish(.authOk(.init(), .init(serverProof: proof)))
        default: throw SessionFailure(.invalidPayload)
        }
    }

    private func acceptProof(_ message: Message) throws -> Event {
        guard case .pairProof(let header, let body) = message, let keys, let pinKey else {
            throw SessionFailure(.invalidPayload)
        }
        attempts += 1
        guard HandshakeKeys.verify(body.proof, input: keys.pairClientInput(header.id), key: pinKey)
        else {
            throw SessionFailure(
                attempts >= 3 ? .tooManyAttempts : .authFailed, close: attempts >= 3,
                message: attempts >= 3
                    ? "No attempts remaining. Request a new code."
                    : "Incorrect code, attempts remaining: \(3 - attempts)")
        }
        let token = makeToken()
        guard token.count == 32 else { throw SessionFailure(.internal) }
        let proof = HandshakeKeys.mac(
            keys.pairServerInput(header.id, proof: body.proof, token: token), key: pinKey)
        // Synchronous contract: storage exception prevents sending success.
        try saveToken(
            .init(
                deviceId: keys.transcript.hello.deviceId,
                deviceName: keys.transcript.hello.deviceName, token: token))
        return try prepareFinish(.paired(.init(), .init(token: token, serverProof: proof)))
    }

    private func prepareFinish(_ message: Message) throws -> Event {
        guard let channel else { throw SessionFailure(.internal) }
        let frame = try channel.sealHandshake(message)
        stage = .finish
        gate.release(self)
        clearSecrets()
        return .sendFinish(frame)
    }

    /// Call only after successful transmission of the first protected frame.
    public func finishSent() throws -> SecureChannel {
        guard stage == .finish, let channel else {
            close()
            throw SessionFailure(.invalidPayload)
        }
        stage = .connected
        channel.activate()
        return channel
    }

    /// Transport also calls on timeout when client stops sending data.
    public func checkDeadline() throws {
        if pairingExpired {
            close()
            throw SessionFailure(.pairingTimeout, message: "Code expired. Request a new code.")
        }
    }

    /// nil indicates late UI invocation: no active PIN prompt remains.
    public func rejectPairing() -> SessionFailure? {
        guard stage == .proof else { return nil }
        let code: ProtocolError.Code = pairingExpired ? .pairingTimeout : .pairingRejected
        close()
        return SessionFailure(
            code,
            message: code == .pairingTimeout
                ? "Code expired. Request a new code." : "Connection rejected on Mac.")
    }

    private var pairingExpired: Bool {
        stage == .proof && deadline.map { now() >= $0 } == true
    }

    public func close() {
        gate.release(self)
        channel?.close()
        channel = nil
        stage = .closed
        clearSecrets()
    }

    private func clearSecrets() {
        privateKey = nil
        keys = nil
        pinKey = nil
        deadline = nil
        hello = nil
        acknowledgement = nil
        nonce = Data()
    }
}
