import Foundation

/// `error` message body. Message text does not contain raw payload or secrets.
public struct ProtocolError: Error, Codable, Sendable, Equatable {
    public enum Code: String, Codable, Sendable, CaseIterable {
        case incompatibleVersion
        case notPaired
        case authFailed
        case pairingRejected
        case pairingTimeout
        case tooManyAttempts
        case unknownMessage
        case invalidPayload
        case noMedia
        case itemNotFound
        case `internal`
    }

    public let replyTo: UUID?
    public let code: Code
    public let message: String

    public init(replyTo: UUID? = nil, code: Code, message: String) {
        self.replyTo = replyTo
        self.code = code
        self.message = message
    }

    func replying(to id: UUID) -> Self {
        Self(replyTo: id, code: code, message: message)
    }
}
