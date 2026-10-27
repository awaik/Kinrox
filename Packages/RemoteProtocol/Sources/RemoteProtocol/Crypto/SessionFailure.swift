import Foundation

/// Session failure. Response is only permitted while corresponding send mode remains available.
public struct SessionFailure: Error, Sendable, Equatable {
    public let error: ProtocolError
    public let shouldCloseConnection: Bool
    public let canSendResponse: Bool

    init(
        _ code: ProtocolError.Code, replyTo: UUID? = nil, close: Bool = true,
        respond: Bool = true, message: String = "Secure session error."
    ) {
        error = ProtocolError(replyTo: replyTo, code: code, message: message)
        shouldCloseConnection = close
        canSendResponse = respond
    }

    init(_ failure: Codec.Failure, close: Bool, respond: Bool = true) {
        error = failure.error
        shouldCloseConnection = close
        canSendResponse = respond
    }
}

extension Message {
    var isApplicationMessage: Bool { type.isApplicationMessage }

    func validateHandshakeFields() throws {
        let fields: [Data]
        switch self {
        case .hello(_, let body):
            guard body.minVersion > 0, body.maxVersion >= body.minVersion,
                body.maxVersion <= Int(UInt32.max)
            else { throw ProtocolError(code: .invalidPayload, message: "Invalid versions.") }
            fields = []
        case .helloAck(_, let body):
            guard body.version > 0, body.version <= Int(UInt32.max) else {
                throw ProtocolError(code: .invalidPayload, message: "Invalid version.")
            }
            fields = [body.serverPublicKey, body.nonce]
        case .pairRequest(_, let body): fields = [body.clientPublicKey]
        case .pairProof(_, let body): fields = [body.proof]
        case .auth(_, let body): fields = [body.clientPublicKey, body.proof]
        case .paired(_, let body): fields = [body.token, body.serverProof]
        case .authOk(_, let body): fields = [body.serverProof]
        default: fields = []
        }
        guard fields.allSatisfy({ $0.count == 32 }) else {
            throw ProtocolError(code: .invalidPayload, message: "Expected 32 bytes.")
        }
    }
}

extension Message.MessageType {
    var isApplicationMessage: Bool {
        switch self {
        case .command, .requestState, .bye, .state, .recent, .ack, .error: true
        default: false
        }
    }
}
