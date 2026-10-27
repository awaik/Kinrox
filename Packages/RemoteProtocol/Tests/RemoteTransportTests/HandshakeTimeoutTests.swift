import Foundation
import Network
import RemoteProtocol
import Testing

@testable import RemoteTransport

@Suite("Handshake timeout independent of pong")
@MainActor struct HandshakeTimeoutTests {
    @Test("PIN wait and connected channel survive network handshake timeout")
    func pinAndConnectedLifetimes() async throws {
        let h = try TransportHarness()
        defer { h.stop() }
        try await h.start()
        let device = UUID()
        let client = h.client(deviceId: device)
        try await eventually { client.state == .awaitingPIN && h.pins[device] != nil }
        try await Task.sleep(for: .seconds(16))
        #expect(client.state == .awaitingPIN)
        #expect(h.server.connectionCount == 1)
        try await client.submitPIN(try #require(h.pins[device]))
        try await eventually { client.state == .connected }
        try await Task.sleep(for: .seconds(16))
        #expect(client.state == .connected)
        try await client.send(.requestState(.init()))
        try await eventually { h.incoming.count == 1 }
    }

    @Test("Four stalled hello/key free server slots")
    func occupiedSlots() async throws {
        let h = try TransportHarness()
        defer { h.stop() }
        try await h.start()
        var wires: [WireEndpoint] = []
        defer { for wire in wires { wire.close() } }
        for index in 0..<4 {
            let wire = WireEndpoint(
                NWConnection(to: h.endpoint, using: TransportConfiguration.parameters()))
            wires.append(wire)
            wire.start()
            try await eventually { wire.ready }
            if index.isMultiple(of: 2) {
                let client = ClientHandshake(
                    deviceId: UUID(), deviceName: "Stalled remote", appVersion: "1", mode: .pair)
                try await wire.send(client.start())
                try await eventually { wire.frames.count == 1 }
            }
        }
        #expect(h.server.connectionCount == 4)
        // Invalid command does not extend first hello deadline.
        try await Task.sleep(for: .seconds(10))
        try await wires[1].send(Codec.encode(.requestState(.init())))
        try await eventually { wires[1].frames.count == 1 }
        try await eventually(timeout: .seconds(7)) { h.server.connectionCount == 0 }
        #expect(h.failures == Array(repeating: .timeout, count: 4))
        _ = try await h.pair()
    }

    @Test(
        "Client bounds response wait during active pong",
        arguments: ["helloAck", "pairChallenge", "authOk", "paired"])
    func missingResponse(_ response: String) async throws {
        let server = try SilentHandshakeServer()
        defer { server.stop() }
        try await server.start()
        let token = Data(repeating: 17, count: 32)
        let client = TransportClient(
            endpoint: try server.endpoint(), serverId: server.id, deviceId: UUID(),
            deviceName: "Remote", appVersion: "1",
            mode: response == "authOk" ? .authenticate(token: token, serverId: server.id) : .pair,
            saveToken: { _ in Issue.record("No confirmation — no token") })
        defer { client.close() }
        client.start()
        try await eventually { server.wire?.frames.count == 1 }
        let wire = try #require(server.wire)
        let handshake = ServerHandshake(
            serverId: server.id, serverName: "Mac", pairingGate: PairingGate(),
            loadToken: { _ in token }, saveToken: { _ in })
        if response != "helloAck" {
            guard case .send(let ack) = try handshake.receive(wire.frames[0]) else {
                throw TransportTestError.storage
            }
            try await wire.send(ack)
            try await eventually { wire.frames.count == 2 }
        }
        if response == "paired" {
            guard case .pairingChallenge(let pin, let frame) = try handshake.receive(wire.frames[1])
            else { throw TransportTestError.storage }
            try await wire.send(frame)
            try await eventually { client.state == .awaitingPIN }
            // User has 120 seconds; short network timeout does not apply here.
            try await Task.sleep(for: .seconds(16))
            #expect(client.state == .awaitingPIN)
            try await client.submitPIN(pin)
            try await eventually { wire.frames.count == 3 }
        }
        try await eventually(timeout: .seconds(17)) {
            if case .closed = client.state { return true }
            return false
        }
        #expect(client.state == .closed(.timeout))
    }
}

@MainActor private final class SilentHandshakeServer {
    let id = UUID()
    let listener: NWListener
    var wire: WireEndpoint?
    private var ready = false

    init() throws {
        let parameters = TransportConfiguration.parameters(listener: true)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { if case .ready = state { self?.ready = true } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else {
                    connection.cancel()
                    return
                }
                self.wire = WireEndpoint(connection)
                self.wire?.start()
            }
        }
    }

    func start() async throws {
        listener.start(queue: .main)
        try await eventually { ready }
    }

    func endpoint() throws -> NWEndpoint {
        .hostPort(host: .ipv4(.loopback), port: try #require(listener.port))
    }

    func stop() {
        wire?.close()
        listener.cancel()
    }
}
