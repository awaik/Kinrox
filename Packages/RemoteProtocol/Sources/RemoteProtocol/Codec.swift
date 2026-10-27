import Foundation

/// Single-frame JSON. Secure channel additionally accounts for 28 bytes of AEAD.
public enum Codec {
    public static let maxMessageBytes = 64 * 1024

    /// Transport responds with `error` and respects connection close policy.
    public struct Failure: Error, Sendable, Equatable {
        public let error: ProtocolError
        public let shouldCloseConnection: Bool
    }

    public static func encode(_ message: Message) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        let data: Data
        do {
            data = try encoder.encode(message)
        } catch {
            throw failure(error, replyTo: message.header.id)
        }
        try checkSize(data)
        return data
    }

    public static func decode(_ data: Data) throws -> Message {
        // Check before parsing JSON: oversized frames must not be handled as regular commands.
        try checkSize(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.dataDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let bytes = Data(base64Encoded: string), bytes.base64EncodedString() == string
            else {
                throw ProtocolError(code: .invalidPayload, message: "Invalid Base64.")
            }
            return bytes
        }
        do {
            return try decoder.decode(Message.self, from: data)
        } catch {
            throw failure(error)
        }
    }

    static func decodeEnvelope(_ data: Data) throws -> Message.Envelope {
        try checkSize(data)
        do {
            return try JSONDecoder().decode(Message.Envelope.self, from: data)
        } catch {
            throw failure(error)
        }
    }

    private static func checkSize(_ data: Data) throws {
        guard data.count <= maxMessageBytes else {
            throw Failure(
                error: ProtocolError(code: .invalidPayload, message: "Message exceeds 64 KB."),
                shouldCloseConnection: true)
        }
    }

    private static func failure(_ error: any Error, replyTo: UUID? = nil) -> Failure {
        var protocolError =
            error as? ProtocolError
            ?? ProtocolError(code: .invalidPayload, message: "Invalid message.")
        if let replyTo { protocolError = protocolError.replying(to: replyTo) }
        return Failure(
            error: protocolError, shouldCloseConnection: protocolError.code == .incompatibleVersion)
    }
}
