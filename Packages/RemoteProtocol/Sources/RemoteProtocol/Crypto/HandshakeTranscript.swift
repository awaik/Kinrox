import CryptoKit
import Foundation

/// Canonical context representation, without JSON or MAC.
struct HandshakeTranscript {
    let bytes: Data
    let hash: Data
    let hello: Message.Hello
    let acknowledgement: Message.HelloAck
    let clientPublicKey: Data
    let isPairing: Bool

    init(hello: Message, acknowledgement: Message, keyMessage: Message) throws {
        try hello.validateHandshakeFields()
        try acknowledgement.validateHandshakeFields()
        try keyMessage.validateHandshakeFields()
        guard case .hello(let helloHeader, let helloBody) = hello,
            case .helloAck(let ackHeader, let ack) = acknowledgement
        else { throw SessionFailure(.invalidPayload) }
        guard helloHeader.v == 1, ackHeader.v == 1,
            ack.version
                == (try Version.negotiate(
                    minVersion: helloBody.minVersion,
                    maxVersion: helloBody.maxVersion)),
            keyMessage.header.v == ack.version
        else { throw SessionFailure(.incompatibleVersion) }
        let publicKey: Data
        let pairing: Bool
        switch keyMessage {
        case .pairRequest(_, let body):
            publicKey = body.clientPublicKey
            pairing = true
        case .auth(_, let body):
            guard body.deviceId == helloBody.deviceId else { throw SessionFailure(.invalidPayload) }
            publicKey = body.clientPublicKey
            pairing = false
        default: throw SessionFailure(.invalidPayload)
        }
        var data = CryptoBytes.label("transcript")
        data.append(pairing ? 0 : 1)
        data += CryptoBytes.u32(helloHeader.v) + CryptoBytes.uuid(helloHeader.id)
        data += CryptoBytes.u32(helloBody.minVersion) + CryptoBytes.u32(helloBody.maxVersion)
        data += CryptoBytes.uuid(helloBody.deviceId)
        data += CryptoBytes.string(helloBody.deviceName) + CryptoBytes.string(helloBody.appVersion)
        data += CryptoBytes.u32(ackHeader.v) + CryptoBytes.uuid(ackHeader.id)
        data += CryptoBytes.u32(ack.version) + CryptoBytes.uuid(ack.serverId)
        data += CryptoBytes.string(ack.serverName)
        data.append(ack.needsPairing ? 1 : 0)
        data += ack.serverPublicKey + ack.nonce
        data += CryptoBytes.u32(keyMessage.header.v) + CryptoBytes.uuid(keyMessage.header.id)
        data += publicKey
        bytes = data
        hash = Data(SHA256.hash(data: data))
        self.hello = helloBody
        self.acknowledgement = ack
        clientPublicKey = publicKey
        isPairing = pairing
    }
}

enum CryptoBytes {
    static func label(_ suffix: String) -> Data { Data("kinrox/v1/\(suffix)".utf8) + Data([0]) }

    static func u32(_ value: Int) -> Data {
        let value = UInt32(value)
        return Data([
            UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
        ])
    }

    static func uuid(_ value: UUID) -> Data {
        let hex = Array(value.uuidString.filter { $0 != "-" })
        return Data(
            stride(from: 0, to: hex.count, by: 2).map {
                UInt8(String(hex[$0...($0 + 1)]), radix: 16)!
            })
    }

    static func string(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        return u32(bytes.count) + bytes
    }

    static func random32() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func randomPIN() -> String {
        var generator = SystemRandomNumberGenerator()
        let digits = String(Int.random(in: 0...999_999, using: &generator))
        return String(repeating: "0", count: 6 - digits.count) + digits
    }
}
