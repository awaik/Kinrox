import Foundation

/// v1 envelope: `v`, `id`, `type`, `body`. Type determines body schema.
public enum Message: Codable, Sendable, Equatable {
    public struct Header: Codable, Sendable, Equatable {
        public let v: Int
        public let id: UUID

        public init(v: Int = Version.current, id: UUID = UUID()) {
            self.v = v
            self.id = id
        }
    }

    public enum MessageType: String, Codable, Sendable, CaseIterable {
        case hello, pairRequest, pairProof, auth, command, requestState, bye
        case helloAck, pairChallenge, paired, authOk, state, recent, ack, error
    }

    case hello(Header, Hello)
    case pairRequest(Header, PairRequest)
    case pairProof(Header, PairProof)
    case auth(Header, Auth)
    case command(Header, Command)
    case requestState(Header)
    case bye(Header)
    case helloAck(Header, HelloAck)
    case pairChallenge(Header)
    case paired(Header, Paired)
    case authOk(Header, AuthOk)
    case state(Header, PlayerState)
    case recent(Header, [RecentItem])
    case ack(Header, Acknowledgement)
    case error(Header, ProtocolError)

    public var header: Header {
        switch self {
        case .hello(let header, _), .pairRequest(let header, _), .pairProof(let header, _),
            .auth(let header, _), .command(let header, _), .requestState(let header),
            .bye(let header), .helloAck(let header, _), .pairChallenge(let header),
            .paired(let header, _), .authOk(let header, _), .state(let header, _),
            .recent(let header, _), .ack(let header, _), .error(let header, _):
            header
        }
    }

    public var type: MessageType {
        switch self {
        case .hello: .hello
        case .pairRequest: .pairRequest
        case .pairProof: .pairProof
        case .auth: .auth
        case .command: .command
        case .requestState: .requestState
        case .bye: .bye
        case .helloAck: .helloAck
        case .pairChallenge: .pairChallenge
        case .paired: .paired
        case .authOk: .authOk
        case .state: .state
        case .recent: .recent
        case .ack: .ack
        case .error: .error
        }
    }

    private enum CodingKeys: String, CodingKey { case v, id, type, body }

    /// Allows verifying session stage prior to parsing body and command kind.
    struct Envelope: Decodable {
        let header: Header
        let type: MessageType?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let id = try container.decodeIfPresent(UUID.self, forKey: .id)
            do {
                header = try Header(from: decoder)
                try Message.validateVersion(header.v)
                type = MessageType(rawValue: try container.decode(String.self, forKey: .type))
                guard container.contains(.body) else {
                    throw ProtocolError(
                        code: .invalidPayload, message: "Missing message body.")
                }
            } catch {
                let failure =
                    error as? ProtocolError
                    ?? ProtocolError(code: .invalidPayload, message: "Invalid envelope.")
                throw ProtocolError(replyTo: id, code: failure.code, message: failure.message)
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let envelope = try Envelope(from: decoder)
        let header = envelope.header
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            guard let type = envelope.type else {
                throw ProtocolError(code: .unknownMessage, message: "Unknown message type.")
            }
            switch type {
            case .hello: self = .hello(header, try container.decode(Hello.self, forKey: .body))
            case .pairRequest:
                self = .pairRequest(header, try container.decode(PairRequest.self, forKey: .body))
            case .pairProof:
                self = .pairProof(header, try container.decode(PairProof.self, forKey: .body))
            case .auth: self = .auth(header, try container.decode(Auth.self, forKey: .body))
            case .command:
                self = .command(header, try container.decode(Command.self, forKey: .body))
            case .requestState, .bye, .pairChallenge:
                _ = try container.decode(EmptyBody.self, forKey: .body)
                switch type {
                case .requestState: self = .requestState(header)
                case .bye: self = .bye(header)
                default: self = .pairChallenge(header)
                }
            case .helloAck:
                self = .helloAck(header, try container.decode(HelloAck.self, forKey: .body))
            case .paired: self = .paired(header, try container.decode(Paired.self, forKey: .body))
            case .authOk: self = .authOk(header, try container.decode(AuthOk.self, forKey: .body))
            case .state:
                self = .state(header, try container.decode(PlayerState.self, forKey: .body))
            case .recent:
                self = .recent(header, try container.decode([RecentItem].self, forKey: .body))
            case .ack:
                self = .ack(header, try container.decode(Acknowledgement.self, forKey: .body))
            case .error:
                self = .error(header, try container.decode(ProtocolError.self, forKey: .body))
            }
            try validateHandshakeFields()
        } catch {
            let failure =
                error as? ProtocolError
                ?? ProtocolError(code: .invalidPayload, message: "Invalid message.")
            throw failure.replying(to: header.id)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try Self.validateVersion(header.v)
        try validateHandshakeFields()
        try header.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .hello(_, let body): try container.encode(body, forKey: .body)
        case .pairRequest(_, let body): try container.encode(body, forKey: .body)
        case .pairProof(_, let body): try container.encode(body, forKey: .body)
        case .auth(_, let body): try container.encode(body, forKey: .body)
        case .command(_, let body): try container.encode(body, forKey: .body)
        case .helloAck(_, let body): try container.encode(body, forKey: .body)
        case .paired(_, let body): try container.encode(body, forKey: .body)
        case .authOk(_, let body): try container.encode(body, forKey: .body)
        case .state(_, let body): try container.encode(body, forKey: .body)
        case .recent(_, let body): try container.encode(body, forKey: .body)
        case .ack(_, let body): try container.encode(body, forKey: .body)
        case .error(_, let body): try container.encode(body, forKey: .body)
        case .requestState, .bye, .pairChallenge:
            try container.encode(EmptyBody(), forKey: .body)
        }
    }

    private static func validateVersion(_ version: Int) throws {
        guard Version.supported.contains(version) else {
            throw ProtocolError(
                code: .incompatibleVersion, message: "Unsupported envelope version.")
        }
    }
}

/// Empty body remains an object to accommodate future optional fields.
private struct EmptyBody: Codable {
    private enum CodingKeys: CodingKey { case reserved }

    init() {}

    init(from decoder: any Decoder) throws {
        _ = try decoder.container(keyedBy: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        _ = encoder.container(keyedBy: CodingKeys.self)
    }
}
