import Foundation
import Network
import RemoteProtocol
import Testing

@testable import RemoteTransport

@Suite("Real WebSocket on localhost", .serialized)
@MainActor struct TransportIntegrationTests {
    @Test("PIN, command, state, and auth on fresh connection")
    func pairAndAuthenticate() async throws {
        let h = try TransportHarness()
        defer { h.stop() }
        try await h.start()
        let device = UUID()
        let client = try await h.pair(deviceId: device)
        let command = Message.command(.init(), .seekRelative(seconds: 30))
        try await client.send(command)
        try await eventually { h.incoming == [command] }
        let reply = Message.ack(.init(), .init(replyTo: command.header.id))
        try await h.server.send(reply, to: #require(h.deviceConnections[device]))
        try await eventually { h.outgoing == [reply] }
        let token = try #require(h.clientTokens[device])
        client.close()
        try await eventually { h.server.connectionCount == 0 }
        let reconnect = h.client(deviceId: device, token: token)
        try await eventually { reconnect.state == .connected }
        #expect(h.authenticated.filter { $0 == device }.count == 2)
        try await reconnect.send(.requestState(.init()))
        try await eventually { h.incoming.count == 2 }
    }

    @Test("Incorrect PIN can be corrected without new connection")
    func wrongPIN() async throws {
        let h = try TransportHarness()
        defer { h.stop() }
        try await h.start()
        let device = UUID()
        let client = h.client(deviceId: device)
        try await eventually { client.state == .awaitingPIN && h.pins[device] != nil }
        let pin = try #require(h.pins[device])
        try await client.submitPIN(pin == "000000" ? "111111" : "000000")
        try await eventually { h.retries == 1 }
        #expect(client.state == .awaitingPIN)
        #expect(h.incoming.isEmpty && h.authenticated.isEmpty)
        try await client.submitPIN(pin)
        try await eventually { client.state == .connected }
    }

    @Test("Unknown token yields authFailed and close")
    func wrongToken() async throws {
        let h = try TransportHarness()
        defer { h.stop() }
        try await h.start()
        let client = h.client(deviceId: UUID(), token: Data(repeating: 7, count: 32))
        try await eventually {
            if case .closed = client.state { return true }
            return false
        }
        guard case .closed(.protocolFailure(let error)) = client.state else {
            Issue.record("No protocol error")
            return
        }
        #expect(error.code == .authFailed)
        #expect(h.pins.isEmpty && h.authenticated.isEmpty)
    }

    @Test("Up to four connections, freeing slots after close")
    func connectionLimit() async throws {
        let h = try TransportHarness()
        defer { h.stop() }
        try await h.start()
        for _ in 0..<4 { _ = try await h.pair() }
        #expect(h.server.connectionCount == 4)
        let extra = h.client(deviceId: UUID())
        try await eventually {
            if case .closed = extra.state { return true }
            return false
        }
        #expect(h.server.connectionCount == 4)
        h.clients[0].close()
        try await eventually { h.server.connectionCount == 3 }
        _ = try await h.pair()
        #expect(h.server.connectionCount == 4)
    }

    @Test("Server closes connections, restart acquires working port")
    func restart() async throws {
        let h = try TransportHarness()
        defer { h.stop() }
        try await h.start()
        let client = try await h.pair()
        h.server.stop()
        try await eventually {
            if case .closed = client.state { return true }
            return false
        }
        #expect(h.server.connectionCount == 0)
        #expect(h.server.state == .stopped)
        try await h.start()
        _ = try await h.pair()
    }

    @Test("Storage failure denies control", arguments: [false, true])
    func storageFailure(_ server: Bool) async throws {
        let h = try TransportHarness()
        defer { h.stop() }
        h.failClientSave = !server
        h.failServerSave = server
        try await h.start()
        let device = UUID()
        let client = h.client(deviceId: device)
        try await eventually { client.state == .awaitingPIN && h.pins[device] != nil }
        try await client.submitPIN(try #require(h.pins[device]))
        try await eventually {
            if case .closed = client.state { return true }
            return false
        }
        #expect(h.clientTokens.isEmpty)
        if !server {
            #expect(client.state == .closed(.storageFailure))
        } else {
            guard case .closed(.protocolFailure(let failure)) = client.state else {
                Issue.record("Server failure must be reported as protocol error")
                return
            }
            #expect(failure.code == .internal)
        }
        await #expect(throws: TransportFailure.self) {
            try await client.send(.command(.init(), .togglePause))
        }
        #expect(h.incoming.isEmpty)
    }
}
