import CryptoKit
import Foundation

/// Client does not receive channel or token for storage until serverProof is verified.
@MainActor public final class ClientHandshake {
    public enum Mode: Sendable {
        case pair
        case authenticate(token: Data, serverId: UUID)
    }
    public enum Event {
        case send(Data)
        case enterPIN
        case retryPIN(ProtocolError)
        case authenticated(token: Data?, channel: SecureChannel)
    }
    private enum Stage { case initial, hello, challenge, pin, finish, connected, closed }
    private var stage = Stage.initial
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var mode: Mode?
    private let expectedServerId: UUID?
    private let hello: Message
    private var keys: HandshakeKeys?
    private var channel: SecureChannel?
    private var proofKey: SymmetricKey?
    private var clientProof = Data()
    private var pendingId: UUID?
    private var attempts = 0
    private var pairing = false

    public convenience init(
        deviceId: UUID, deviceName: String, appVersion: String,
        mode: Mode, expectedServerId: UUID? = nil
    ) {
        self.init(
            deviceId: deviceId, deviceName: deviceName, appVersion: appVersion,
            mode: mode, expectedServerId: expectedServerId, privateKey: .init())
    }

    // Secret injection is only available to tests via @testable, not package consumers.
    init(
        deviceId: UUID, deviceName: String, appVersion: String, mode: Mode,
        expectedServerId: UUID? = nil, privateKey: Curve25519.KeyAgreement.PrivateKey,
        helloHeader: Message.Header = .init()
    ) {
        self.privateKey = privateKey
        self.mode = mode
        self.expectedServerId = expectedServerId
        hello = .hello(
            helloHeader,
            .init(
                minVersion: 1, maxVersion: 1,
                deviceId: deviceId, deviceName: deviceName, appVersion: appVersion))
    }

    public func start() throws -> Data {
        guard stage == .initial else { throw fail(.invalidPayload) }
        do {
            let frame = try Codec.encode(hello)
            stage = .hello
            pendingId = hello.header.id
            return frame
        } catch { throw handle(error) }
    }

    public func receive(_ frame: Data) throws -> Event {
        do {
            if stage == .finish, frame.first == 0 { return try finish(frame) }
            guard stage == .hello || stage == .challenge || stage == .pin || stage == .finish else {
                throw SessionFailure(.invalidPayload)
            }
            let message = try Codec.decode(frame)
            if case .error(_, let error) = message { return try receiveError(error) }
            switch stage {
            case .hello: return try acceptHello(message)
            case .challenge:
                guard case .pairChallenge = message else { throw SessionFailure(.invalidPayload) }
                stage = .pin
                return .enterPIN
            default: throw SessionFailure(.invalidPayload)
            }
        } catch { throw handle(error) }
    }

    private func acceptHello(_ message: Message) throws -> Event {
        guard case .helloAck(_, let ack) = message, let privateKey, let mode else {
            throw SessionFailure(.invalidPayload)
        }
        if let expectedServerId, ack.serverId != expectedServerId {
            throw SessionFailure(.authFailed)
        }
        let header = Message.Header(v: ack.version)
        let keyMessage: Message
        switch mode {
        case .pair:
            pairing = true
            keyMessage = .pairRequest(
                header, .init(clientPublicKey: privateKey.publicKey.rawRepresentation))
        case .authenticate(let token, let serverId):
            guard ack.serverId == serverId else { throw SessionFailure(.authFailed) }
            guard token.count == 32 else { throw SessionFailure(.invalidPayload) }
            guard case .hello(_, let body) = hello else { throw SessionFailure(.invalidPayload) }
            keyMessage = .auth(
                header,
                .init(
                    deviceId: body.deviceId,
                    clientPublicKey: privateKey.publicKey.rawRepresentation,
                    proof: Data(repeating: 0, count: 32)))
        }
        let keys = try HandshakeKeys(
            transcript: HandshakeTranscript(
                hello: hello,
                acknowledgement: message, keyMessage: keyMessage), privateKey: privateKey,
            role: .client)
        self.keys = keys
        self.privateKey = nil
        channel = SecureChannel(keys: keys, role: .client)
        pendingId = header.id
        let outbound: Message
        switch mode {
        case .pair:
            outbound = keyMessage
            stage = .challenge
        case .authenticate(let token, _):
            proofKey = try keys.authServerKey(token)
            clientProof = HandshakeKeys.mac(keys.authClientInput, key: SymmetricKey(data: token))
            outbound = .auth(
                header,
                .init(
                    deviceId: keys.transcript.hello.deviceId,
                    clientPublicKey: keys.transcript.clientPublicKey, proof: clientProof))
            stage = .finish
        }
        self.mode = nil
        return .send(try Codec.encode(outbound))
    }

    public func submitPIN(_ pin: String) throws -> Data {
        guard stage == .pin, let keys else { throw fail(.invalidPayload) }
        do {
            let key = try keys.pinKey(pin)
            let id = UUID()
            proofKey = key
            clientProof = HandshakeKeys.mac(keys.pairClientInput(id), key: key)
            pendingId = id
            attempts += 1
            stage = .finish
            return try Codec.encode(
                .pairProof(
                    .init(v: keys.transcript.acknowledgement.version, id: id),
                    .init(proof: clientProof)))
        } catch { throw handle(error) }
    }

    private func finish(_ frame: Data) throws -> Event {
        guard let channel, let keys, let proofKey, let pendingId else {
            throw SessionFailure(.invalidPayload)
        }
        let message = try channel.openHandshake(frame)
        let token: Data?
        let serverProof: Data
        let input: Data
        switch message {
        case .paired(_, let body) where pairing:
            token = body.token
            serverProof = body.serverProof
            input = keys.pairServerInput(pendingId, proof: clientProof, token: body.token)
        case .authOk(_, let body) where !pairing:
            token = nil
            serverProof = body.serverProof
            input = keys.authServerInput(clientProof)
        default: throw SessionFailure(.invalidPayload, respond: false)
        }
        guard HandshakeKeys.verify(serverProof, input: input, key: proofKey) else {
            throw SessionFailure(.authFailed, respond: false)
        }
        channel.activate()
        stage = .connected
        clearSecrets()
        return .authenticated(token: token, channel: channel)
    }

    private func receiveError(_ error: ProtocolError) throws -> Event {
        let common: Set<ProtocolError.Code> = [.invalidPayload, .incompatibleVersion, .internal]
        let allowed: Set<ProtocolError.Code>
        switch stage {
        case .hello: allowed = common
        case .challenge, .pin:
            allowed = common.union([.pairingRejected, .pairingTimeout, .authFailed])
        case .finish where pairing:
            allowed = common.union([
                .authFailed, .tooManyAttempts, .pairingRejected, .pairingTimeout,
            ])
        case .finish: allowed = common.union([.authFailed])
        default: throw SessionFailure(.invalidPayload)
        }
        guard allowed.contains(error.code), error.replyTo == nil || error.replyTo == pendingId
        else {
            throw SessionFailure(.invalidPayload)
        }
        if stage == .finish, pairing, error.code == .authFailed, attempts < 3,
            error.replyTo == pendingId
        {
            proofKey = nil
            clientProof = Data()
            stage = .pin
            return .retryPIN(error)
        }
        throw SessionFailure(
            error.code, replyTo: error.replyTo, respond: false, message: error.message)
    }

    public func close() {
        channel?.close()
        channel = nil
        stage = .closed
        clearSecrets()
    }

    private func clearSecrets() {
        privateKey = nil
        mode = nil
        keys = nil
        proofKey = nil
        clientProof = Data()
    }

    private func fail(_ code: ProtocolError.Code) -> SessionFailure {
        close()
        return SessionFailure(code, respond: false)
    }

    private func handle(_ error: any Error) -> SessionFailure {
        close()
        if let failure = error as? SessionFailure {
            return SessionFailure(
                failure.error.code, replyTo: failure.error.replyTo, respond: false,
                message: failure.error.message)
        }
        if let failure = error as? Codec.Failure {
            return SessionFailure(
                failure.error.code, replyTo: failure.error.replyTo, respond: false,
                message: failure.error.message)
        }
        if let failure = error as? ProtocolError {
            return SessionFailure(
                failure.code, replyTo: failure.replyTo, respond: false, message: failure.message)
        }
        return SessionFailure(.invalidPayload, respond: false)
    }
}
