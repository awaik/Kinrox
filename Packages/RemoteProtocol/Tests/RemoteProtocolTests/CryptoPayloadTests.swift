import Foundation
import Testing

@testable import RemoteProtocol

@Suite("Handshake binary fields")
struct CryptoPayloadTests {
    @Test(
        "Lengths and canonical Base64",
        arguments: [
            ("helloAck", "serverPublicKey"), ("helloAck", "nonce"),
            ("pairRequest", "clientPublicKey"),
            ("pairProof", "proof"), ("auth", "clientPublicKey"), ("auth", "proof"),
            ("paired", "token"), ("paired", "serverProof"), ("authOk", "serverProof"),
        ])
    func binaryFields(_ name: String, _ field: String) throws {
        let data = try FixtureSamples.data(name)
        let canonical = FixtureSamples.bytes.base64EncodedString()
        let invalid = [
            Data(repeating: 0, count: 31).base64EncodedString(),
            Data(repeating: 0, count: 33).base64EncodedString(), "", "%%%",
            String(canonical.dropLast()),
            canonical + "\n", canonical.replacingOccurrences(of: "8=", with: "9="),
            Data(repeating: 255, count: 32).base64EncodedString().replacingOccurrences(
                of: "/", with: "_"),
        ]
        for value in invalid {
            let failure = try #require(throws: Codec.Failure.self) {
                try Codec.decode(mutateJSON(data, field: field, value: value))
            }
            #expect(failure.error.code == .invalidPayload)
        }
        #expect(throws: Codec.Failure.self) {
            try Codec.decode(mutateJSON(data, field: field, value: nil))
        }
    }

    @Test(
        "Versions bounded by U32 before conversion",
        arguments: [-1, 0, Int(UInt32.max) + 1, Int.max])
    func versions(_ value: Int) throws {
        for (name, field) in [
            ("hello", "minVersion"), ("hello", "maxVersion"), ("helloAck", "version"),
        ] {
            let failure = try #require(throws: Codec.Failure.self) {
                try Codec.decode(mutateJSON(FixtureSamples.data(name), field: field, value: value))
            }
            #expect(failure.error.code == .invalidPayload)
        }
    }

    @Test("Outbound short keys are also rejected")
    func outboundLengths() throws {
        for count in [0, 31, 33] {
            #expect(throws: Codec.Failure.self) {
                try Codec.encode(
                    .pairRequest(.init(), .init(clientPublicKey: Data(repeating: 0, count: count))))
            }
        }
    }
}
