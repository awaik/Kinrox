import Foundation
import RemoteProtocol
import Testing

@Suite("Codec errors and frame boundaries")
struct CodecFailureTests {
    @Test("Unknown type or kind does not require disconnect", arguments: [false, true])
    func unknownMessage(command: Bool) throws {
        let data = envelope(
            type: command ? "command" : "futureMessage",
            body: command ? #"{"kind":"futureCommand"}"# : "{}")
        let failure = try #require(throws: Codec.Failure.self) { try Codec.decode(data) }
        #expect(failure.error.code == .unknownMessage)
        #expect(failure.error.replyTo == FixtureSamples.id)
        #expect(!failure.shouldCloseConnection)
        // Next frame of same client can be processed normally.
        #expect(
            try Codec.decode(FixtureSamples.data("requestState"))
                == .requestState(FixtureSamples.header))
    }

    @Test(
        "Corrupted body returns invalidPayload",
        arguments: [
            ("command", "{}"), ("command", #"{"kind":1}"#),
            ("command", #"{"kind":"setPaused","paused":1}"#),
            ("command", #"{"kind":"setPaused"}"#),
            ("command", #"{"kind":"seekRelative","seconds":"30"}"#),
            ("command", #"{"kind":"seekRelative","seconds":1e400}"#),
            ("command", #"{"kind":"seekAbsolute","seconds":-1}"#),
            ("command", #"{"kind":"setVolume","volume":101}"#),
            ("command", #"{"kind":"setVolume","volume":-1}"#),
            ("command", #"{"kind":"openRecent","itemId":"bad-uuid"}"#),
            ("command", #"{"kind":"setFullscreen","fullscreen":null}"#),
            ("hello", "{}"), ("helloAck", "{}"), ("pairRequest", #"{"clientPublicKey":"%%%"}"#),
            ("pairProof", "{}"), ("auth", "{}"), ("paired", #"{"token":42}"#),
            ("state", "{}"), ("recent", "{}"), ("ack", "{}"), ("error", "{}"),
            ("requestState", "null"), ("bye", "[]"), ("authOk", "true"), ("pairChallenge", "1"),
        ])
    func malformedBody(type: String, body: String) throws {
        let failure = try #require(throws: Codec.Failure.self) {
            try Codec.decode(envelope(type: type, body: body))
        }
        #expect(failure.error.code == .invalidPayload)
        #expect(failure.error.replyTo == FixtureSamples.id)
    }

    @Test(
        "Corrupted envelope returns typed error",
        arguments: [
            "", "{", "null", "[]", "{}", #"{"v":1,"id":"bad-uuid","type":"bye","body":{}}"#,
            #"{"v":1,"type":"bye","body":{}}"#,
            #"{"v":"1","id":"6F1C0000-0000-4000-8000-000000000001","type":"bye","body":{}}"#,
            #"{"v":1,"id":"6F1C0000-0000-4000-8000-000000000001","type":"bye"}"#,
        ])
    func malformedEnvelope(_ json: String) throws {
        let failure = try #require(throws: Codec.Failure.self) { try Codec.decode(Data(json.utf8)) }
        #expect(failure.error.code == .invalidPayload)
    }

    @Test("Unsupported version requires close", arguments: [-1, 0, 2, Int.max])
    func unsupportedVersion(_ version: Int) throws {
        let failure = try #require(throws: Codec.Failure.self) {
            try Codec.decode(envelope(type: "bye", body: "{}", version: version))
        }
        #expect(failure.error.code == .incompatibleVersion)
        #expect(failure.error.replyTo == FixtureSamples.id)
        #expect(failure.shouldCloseConnection)
        let encodedFailure = try #require(throws: Codec.Failure.self) {
            try Codec.encode(.bye(.init(v: version, id: FixtureSamples.id)))
        }
        #expect(encodedFailure.error.code == .incompatibleVersion)
    }

    @Test("64 KiB inclusive, testing both directions")
    func sizeBoundary() throws {
        let overhead = try Codec.encode(hello(name: "")).count
        let message = hello(name: String(repeating: "a", count: Codec.maxMessageBytes - overhead))
        let data = try Codec.encode(message)
        #expect(data.count == 65_536)
        #expect(try Codec.decode(data) == message)
        let decodeFailure = try #require(throws: Codec.Failure.self) {
            try Codec.decode(data + Data([32]))
        }
        #expect(decodeFailure.error.code == .invalidPayload)
        #expect(decodeFailure.shouldCloseConnection)
        let encodeFailure = try #require(throws: Codec.Failure.self) {
            try Codec.encode(
                hello(name: String(repeating: "a", count: Codec.maxMessageBytes - overhead + 1)))
        }
        #expect(encodeFailure.error.code == .invalidPayload)
        #expect(encodeFailure.shouldCloseConnection)
    }

    @Test("Limit is counted in UTF-8 bytes before decoding")
    func byteLimit() throws {
        let failure = try #require(throws: Codec.Failure.self) {
            try Codec.encode(hello(name: String(repeating: "a", count: 66_000)))
        }
        #expect(failure.shouldCloseConnection)
        let invalidJSON = Data(repeating: 0xff, count: Codec.maxMessageBytes + 1)
        let decodeFailure = try #require(throws: Codec.Failure.self) {
            try Codec.decode(invalidJSON)
        }
        #expect(decodeFailure.shouldCloseConnection)
        #expect(decodeFailure.error.replyTo == nil)
    }

    @Test(
        "Outbound numeric parameters are validated",
        arguments: [
            Command.seekRelative(seconds: .nan), .seekRelative(seconds: .infinity),
            .seekAbsolute(seconds: -.infinity), .seekAbsolute(seconds: -1),
            .setVolume(volume: -.leastNonzeroMagnitude), .setVolume(volume: 100.1),
            .setVolume(volume: .nan),
        ])
    func invalidCommand(_ command: Command) throws {
        let failure = try #require(throws: Codec.Failure.self) {
            try Codec.encode(.command(FixtureSamples.header, command))
        }
        #expect(failure.error.code == .invalidPayload)
    }

    @Test(
        "Volume and position boundaries are preserved",
        arguments: [
            Command.setVolume(volume: 0), .setVolume(volume: 100), .seekAbsolute(seconds: 0),
            .seekRelative(seconds: -30), .seekRelative(seconds: 30), .setPaused(paused: false),
            .setFullscreen(fullscreen: true),
        ])
    func validCommand(_ command: Command) throws {
        let message = Message.command(FixtureSamples.header, command)
        #expect(try Codec.decode(Codec.encode(message)) == message)
    }

    private func envelope(type: String, body: String, version: Int = 1) -> Data {
        Data(
            "{\"v\":\(version),\"id\":\"\(FixtureSamples.id)\",\"type\":\"\(type)\",\"body\":\(body)}"
                .utf8)
    }

    private func hello(name: String) -> Message {
        .hello(
            FixtureSamples.header,
            .init(
                minVersion: 1, maxVersion: 1, deviceId: FixtureSamples.deviceId, deviceName: name,
                appVersion: "1.0"))
    }
}
