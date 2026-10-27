import Foundation
import Network
import Testing

@testable import RemoteProtocol
@testable import RemoteTransport

@Suite("Security verification on real socket", .serialized)
@MainActor struct TransportSecurityTests {
    @Test("Client error does not reach player and receives no response", arguments: [false, true])
    func incomingSecureError(_ malformed: Bool) async throws {
        let h = try TransportHarness()
        defer { h.stop() }
        try await h.start()
        let remote = try await AuthorizedWire.connect(h)
        defer { remote.wire.close() }
        let message = Message.error(.init(), .init(code: .internal, message: ""))
        var json = try #require(
            JSONSerialization.jsonObject(with: Codec.encode(message)) as? [String: Any])
        if malformed { json["body"] = [String: String]() }
        let count = remote.wire.frames.count
        try await remote.wire.send(
            remote.channel.sealBytes(JSONSerialization.data(withJSONObject: json)))
        try await eventually {
            !h.incoming.isEmpty || h.server.connectionCount == 0 || remote.wire.frames.count > count
        }
        #expect(h.incoming.isEmpty)
        #expect(h.server.connectionCount == 0)
        #expect(remote.wire.frames.count == count)
    }

    @Test(
        "Tampering, replay, omission, and plaintext JSON close session",
        arguments: ["tamper", "replay", "skip", "plaintext", "reflection"])
    func corruptedFrames(_ attack: String) async throws {
        let h = try TransportHarness()
        defer { h.stop() }
        try await h.start()
        let remote = try await AuthorizedWire.connect(h)
        defer { remote.wire.close() }
        let command = Message.command(.init(), .togglePause)
        var frame = try remote.channel.seal(command)
        switch attack {
        case "tamper": frame[frame.count - 1] ^= 1
        case "replay":
            try await remote.wire.send(frame)
            try await eventually { h.incoming.count == 1 }
        case "skip": frame = try remote.channel.seal(command)
        case "plaintext": frame = try Codec.encode(command)
        default: frame = try #require(remote.wire.frames.last)
        }
        let receivedBefore = remote.wire.frames.count
        try await remote.wire.send(frame)
        try await eventually { h.server.connectionCount == 0 }
        #expect(h.incoming.count == (attack == "replay" ? 1 : 0))
        #expect(remote.wire.frames.count == receivedBefore)
    }

    @Test("Unknown kind receives protected error and preserves next nonce")
    func unknownCommand() async throws {
        let h = try TransportHarness()
        defer { h.stop() }
        try await h.start()
        let remote = try await AuthorizedWire.connect(h)
        defer { remote.wire.close() }
        let command = Message.command(.init(), .togglePause)
        var json = try #require(
            JSONSerialization.jsonObject(with: Codec.encode(command)) as? [String: Any])
        json["body"] = ["kind": "futureCommand"]
        let unknown = try JSONSerialization.data(withJSONObject: json)
        let count = remote.wire.frames.count
        try await remote.wire.send(remote.channel.sealBytes(unknown))
        try await eventually { remote.wire.frames.count == count + 1 }
        guard case .error(_, let error) = try remote.channel.open(remote.wire.frames[count]) else {
            Issue.record("No protected error")
            return
        }
        #expect(error.code == .unknownMessage && error.replyTo == command.header.id)
        try await remote.wire.send(remote.channel.seal(command))
        try await eventually { h.incoming == [command] }
        #expect(h.server.connectionCount == 1)
    }

    @Test("Concurrent sends preserve encrypted frame queue")
    func concurrentSends() async throws {
        let h = try TransportHarness()
        defer { h.stop() }
        try await h.start()
        let client = try await h.pair()
        let messages = (0..<16).map { Message.command(.init(), .setVolume(volume: Double($0))) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for message in messages { group.addTask { try await client.send(message) } }
            try await group.waitForAll()
        }
        try await eventually { h.incoming.count == messages.count }
        #expect(Set(h.incoming.map(\.header.id)) == Set(messages.map(\.header.id)))
        #expect(client.state == .connected)
    }

    @Test("Owner rejection is delivered to client, late rejection preserves channel")
    func rejectPairing() async throws {
        let h = try TransportHarness()
        defer { h.stop() }
        try await h.start()
        let device = UUID()
        let client = h.client(deviceId: device)
        try await eventually { h.deviceConnections[device] != nil && client.state == .awaitingPIN }
        h.server.rejectPairing(connectionId: try #require(h.deviceConnections[device]))
        try await eventually {
            if case .closed = client.state { return true }
            return false
        }
        guard case .closed(.protocolFailure(let error)) = client.state else {
            Issue.record("No rejection")
            return
        }
        #expect(error.code == .pairingRejected)
        try await eventually { h.server.connectionCount == 0 }
        let pairedDevice = UUID()
        let paired = try await h.pair(deviceId: pairedDevice)
        h.server.rejectPairing(connectionId: try #require(h.deviceConnections[pairedDevice]))
        try await paired.send(.requestState(.init()))
        try await eventually { h.incoming.count == 1 }
        #expect(paired.state == .connected)
    }
}

@MainActor private struct AuthorizedWire {
    let wire: WireEndpoint
    let channel: SecureChannel

    static func connect(_ harness: TransportHarness) async throws -> AuthorizedWire {
        let device = UUID()
        let wire = WireEndpoint(
            NWConnection(to: harness.endpoint, using: TransportConfiguration.parameters()))
        wire.start()
        do {
            try await eventually { wire.ready }
            let handshake = ClientHandshake(
                deviceId: device, deviceName: "Security verification", appVersion: "1.0",
                mode: .pair, expectedServerId: harness.id)
            try await wire.send(handshake.start())
            var index = 0
            while true {
                try await eventually { wire.frames.count > index }
                let event = try handshake.receive(wire.frames[index])
                index += 1
                switch event {
                case .send(let frame): try await wire.send(frame)
                case .enterPIN:
                    try await eventually { harness.pins[device] != nil }
                    try await wire.send(handshake.submitPIN(try #require(harness.pins[device])))
                case .authenticated(_, let channel):
                    return AuthorizedWire(wire: wire, channel: channel)
                case .retryPIN: throw TransportTestError.storage
                }
            }
        } catch {
            wire.close()
            throw error
        }
    }
}
