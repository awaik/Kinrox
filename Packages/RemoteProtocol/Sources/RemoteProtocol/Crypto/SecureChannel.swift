import CryptoKit
import Foundation

/// One object per connection. MainActor serializes seal/open without duplicate counters.
/// After a transmission error, transport must call close() without repeated seal calls.
@MainActor public final class SecureChannel {
    enum Role { case client, server }
    public static let overhead = 28
    public static let maxPlaintextBytes = Codec.maxMessageBytes - overhead
    public private(set) var isClosed = false
    private var ready = false
    private var sendingKey: SymmetricKey?
    private var receivingKey: SymmetricKey?
    private let sendingAAD: Data
    private let receivingAAD: Data
    private var sendingCounter: NonceCounter
    private var receivingCounter: NonceCounter

    init(
        keys: HandshakeKeys, role: Role,
        sendingCounter: NonceCounter = NonceCounter(),
        receivingCounter: NonceCounter = NonceCounter()
    ) {
        sendingKey = role == .client ? keys.clientToServer : keys.serverToClient
        receivingKey = role == .client ? keys.serverToClient : keys.clientToServer
        let prefix = CryptoBytes.label("frame") + keys.transcript.hash
        sendingAAD = prefix + Data([role == .client ? 0 : 1])
        receivingAAD = prefix + Data([role == .client ? 1 : 0])
        self.sendingCounter = sendingCounter
        self.receivingCounter = receivingCounter
    }

    public func close() {
        isClosed = true
        ready = false
        sendingKey = nil
        receivingKey = nil
    }

    func activate() { if !isClosed { ready = true } }

    public func seal(_ message: Message) throws -> Data {
        guard ready, message.isApplicationMessage else { throw terminate(.invalidPayload) }
        return try sealHandshake(message)
    }

    public func open(_ frame: Data) throws -> Message {
        guard ready else { throw terminate(.notPaired) }
        let bytes = try openBytes(frame)
        let envelope: Message.Envelope
        do {
            envelope = try Codec.decodeEnvelope(bytes)
        } catch let failure as Codec.Failure {
            close()
            throw SessionFailure(failure, close: true, respond: false)
        }
        // Handshake prohibition applies even to incomplete or corrupt body.
        if let type = envelope.type, !type.isApplicationMessage {
            throw terminate(.invalidPayload)
        }
        return try decodeMessage(bytes, canSendResponse: envelope.type != .error)
    }

    // Only accessible to state machines before granting channel to caller.
    func sealHandshake(_ message: Message) throws -> Data {
        do { return try sealBytes(Codec.encode(message)) } catch let failure as Codec.Failure {
            close()
            throw SessionFailure(failure, close: true, respond: false)
        }
    }

    func openHandshake(_ frame: Data) throws -> Message {
        try decodeMessage(openBytes(frame))
    }

    private func decodeMessage(_ bytes: Data, canSendResponse: Bool = true) throws -> Message {
        do { return try Codec.decode(bytes) } catch let failure as Codec.Failure {
            let shouldClose = failure.shouldCloseConnection || !canSendResponse
            if shouldClose { close() }
            throw SessionFailure(failure, close: shouldClose, respond: canSendResponse && !isClosed)
        }
    }

    func sealBytes(_ bytes: Data) throws -> Data {
        guard !isClosed, let key = sendingKey else { throw terminate(.authFailed) }
        guard bytes.count <= Self.maxPlaintextBytes else { throw terminate(.invalidPayload) }
        guard !sendingCounter.exhausted else { throw terminate(.authFailed) }
        do {
            let sealed = try ChaChaPoly.seal(
                bytes, using: key,
                nonce: ChaChaPoly.Nonce(data: sendingCounter.bytes), authenticating: sendingAAD)
            sendingCounter.consume()
            return sealed.combined
        } catch { throw terminate(.authFailed) }
    }

    func openBytes(_ frame: Data) throws -> Data {
        guard !isClosed, let key = receivingKey else { throw terminate(.authFailed) }
        guard (Self.overhead...Codec.maxMessageBytes).contains(frame.count) else {
            throw terminate(.invalidPayload)
        }
        guard !receivingCounter.exhausted, frame.prefix(12) == receivingCounter.bytes else {
            throw terminate(.authFailed)
        }
        do {
            let bytes = try ChaChaPoly.open(
                ChaChaPoly.SealedBox(combined: frame),
                using: key, authenticating: receivingAAD)
            // Even an unknown command has consumed this nonce.
            receivingCounter.consume()
            return bytes
        } catch { throw terminate(.authFailed) }
    }

    private func terminate(_ code: ProtocolError.Code) -> SessionFailure {
        close()
        return SessionFailure(code, respond: false)
    }
}

/// Full 96 bits without arithmetic overflow or wrapping back to zero.
struct NonceCounter {
    private(set) var bytes: Data
    private(set) var exhausted = false

    init(bytes: Data = Data(repeating: 0, count: 12)) {
        precondition(bytes.count == 12)
        self.bytes = Data(bytes)
    }

    mutating func consume() {
        precondition(!exhausted)
        if bytes.allSatisfy({ $0 == 255 }) {
            exhausted = true
            return
        }
        for index in (0..<12).reversed() {
            if bytes[index] != 255 {
                bytes[index] += 1
                return
            }
            bytes[index] = 0
        }
    }
}
