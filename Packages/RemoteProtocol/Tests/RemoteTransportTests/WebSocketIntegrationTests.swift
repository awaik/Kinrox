import Foundation
import Network
import RemoteProtocol
import Testing

@testable import RemoteTransport

@Suite("WebSocket and heartbeat boundaries", .serialized)
@MainActor struct WebSocketIntegrationTests {
    @Test("Two messages remain separated, 65536 bytes pass both directions")
    func messageBoundaries() async throws {
        let h = try WireHarness()
        defer { h.stop() }
        try await h.start()
        let peer = try #require(h.peer)
        let wire = try #require(h.wire)
        let first = Data(repeating: 7, count: 65_536)
        let second = Data(repeating: 9, count: 65_536)
        try await wire.send(first)
        try await wire.send(second)
        try await eventually { h.received.count == 2 }
        #expect(h.received == [first, second])
        try await peer.send(second)
        try await peer.send(first)
        try await eventually { wire.frames.count == 2 }
        #expect(wire.frames == [second, first])
    }

    @Test("Packet over 64 KiB and text close receiver", arguments: [false, true])
    func rejectFrames(_ oversized: Bool) async throws {
        let h = try WireHarness()
        defer { h.stop() }
        try await h.start()
        try await h.wire?.send(
            Data(repeating: 65, count: oversized ? 65_537 : 3), opcode: oversized ? .binary : .text)
        try await eventually { h.peerFailure != nil }
        #expect(h.received.isEmpty)
        #expect(h.peer?.isClosed == true)
        if !oversized { #expect(h.peerFailure == .invalidMessage) }
    }

    @Test(
        "Automatic pong preserves connection without application data", arguments: [false, true])
    func autoPong(_ client: Bool) async throws {
        let role: WebSocketPeer.Role = client ? .client : .server
        let h = try WireHarness(role: role)
        defer { h.stop() }
        try await h.start(role: role)
        try await Task.sleep(for: .milliseconds(1300))
        #expect(h.peerFailure == nil)
        #expect(h.received.isEmpty)
        try await h.wire?.send(Data([42]))
        try await eventually { h.received == [Data([42])] }
    }

    @Test("Silence after ping leads to timeout", arguments: [false, true])
    func missingPong(_ client: Bool) async throws {
        let role: WebSocketPeer.Role = client ? .client : .server
        let h = try WireHarness(role: role, replies: false)
        defer { h.stop() }
        try await h.start(role: role, replies: false)
        try await eventually { h.peerFailure != nil }
        #expect(h.peerFailure == .timeout)
        #expect(h.wire?.opcodes.contains(.ping) == true)
        #expect(h.received.isEmpty)
    }

    @Test("Pending callback does not halt heartbeat")
    func waitingTick() async throws {
        let h = try WireHarness(replies: false)
        defer { h.stop() }
        try await h.start(replies: false)
        h.peer?.onTick = { try? await Task.sleep(for: .seconds(30)) }
        try await eventually { h.peerFailure != nil }
        #expect(h.peerFailure == .timeout)
    }

    @Test("Cancellation frees pending sends and does not retry them")
    func cancelPendingSend() async throws {
        let h = try WireHarness()
        defer { h.stop() }
        try await h.start()
        let peer = try #require(h.peer)
        let pending = Task { try await peer.send(Data(repeating: 3, count: 65_536)) }
        pending.cancel()
        await #expect(throws: (any Error).self) { try await pending.value }
        try await eventually { peer.isClosed }
        await #expect(throws: TransportFailure.self) { try await peer.send(Data([7])) }
    }

    @Test("Command before authorization yields notPaired, ping does not grant control")
    func notPaired() async throws {
        let h = try TransportHarness()
        defer { h.stop() }
        try await h.start()
        let wire = WireEndpoint(
            NWConnection(to: h.endpoint, using: TransportConfiguration.parameters()))
        defer { wire.close() }
        wire.start()
        try await eventually { wire.ready }
        try await wire.send(Data(), opcode: .ping)
        let command = Message.command(.init(), .togglePause)
        try await wire.send(Codec.encode(command))
        try await eventually { wire.frames.count == 1 }
        guard case .error(_, let error) = try Codec.decode(wire.frames[0]) else {
            Issue.record("No error")
            return
        }
        #expect(error.code == .notPaired && error.replyTo == command.header.id)
        #expect(h.incoming.isEmpty && h.authenticated.isEmpty)
        #expect(h.server.connectionCount == 1)
    }
}
