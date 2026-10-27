import Foundation
import Network
import Testing

@testable import RemoteProtocol
@testable import RemoteTransport

@Suite("Synchronous pairing rejection")
@MainActor
struct PairingRejectionTests {
    @Test("Rejection frees PIN before yield and blocks already queued proof")
    func queuedProofCannotOvertakeRejection() async throws {
        let probe = PairingSessionProbe()
        let advertisement = try BonjourAdvertiser(
            serverId: UUID(), name: "Kinrox-Rejection-Test", appVersion: "1.0")
        let parameters = TransportConfiguration.parameters(listener: true)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { [weak listener] state in
            MainActor.assumeIsolated {
                if case .ready = state { probe.port = listener?.port }
            }
        }
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated {
                let session = ServerSession(
                    connection: connection, advertisement: advertisement, gate: probe.gate,
                    loadToken: { _ in nil }, saveToken: { _ in probe.saved = true })
                probe.session = session
                session.onPairing = { _, _, pin in probe.pin = pin }
                session.onAuthenticated = { _, _ in probe.authenticated = true }
                session.peer.start()
            }
        }
        defer {
            probe.session?.close()
            probe.session = nil
            listener.cancel()
        }
        listener.start(queue: .main)
        try await wait("Listener did not receive port") { probe.port != nil }
        let wire = WireEndpoint(
            NWConnection(
                to: .hostPort(host: .ipv4(.loopback), port: try #require(probe.port)),
                using: TransportConfiguration.parameters()))
        defer { wire.close() }
        wire.start()
        try await wait("Client socket is not ready") { wire.ready }
        let client = ClientHandshake(
            deviceId: UUID(), deviceName: "Remote", appVersion: "1.0", mode: .pair)
        try await wire.send(client.start())
        try await wait("helloAck not received") { wire.frames.count == 1 }
        guard case .send(let request) = try client.receive(wire.frames[0]) else {
            Issue.record("Expected pairRequest")
            return
        }
        try await wire.send(request)
        try await wait("PIN request not received") { wire.frames.count == 2 && probe.pin != nil }
        guard case .enterPIN = try client.receive(wire.frames[1]) else {
            Issue.record("Expected PIN request")
            return
        }
        let proof = try client.submitPIN(#require(probe.pin))
        let session = try #require(probe.session)
        let receive = try #require(session.peer.onData)
        // Reproducing WebSocketPeer queue independent of network speed.
        let queuedReader = Task { await receive(proof) }
        session.rejectPairing()
        let next = ServerHandshake(
            serverId: advertisement.serverId, serverName: advertisement.name,
            pairingGate: probe.gate, loadToken: { _ in nil }, saveToken: { _ in })
        #expect(probe.gate.acquire(next))
        next.close()
        await queuedReader.value
        try await wait("Rejection frame not received") { wire.frames.count == 3 }
        guard case .error(_, let error) = try Codec.decode(wire.frames[2]) else {
            Issue.record("Expected rejection instead of paired")
            return
        }
        #expect(error.code == .pairingRejected)
        #expect(!probe.saved && !probe.authenticated)
    }
    private func wait(_ message: Comment, _ condition: () -> Bool) async throws {
        do { try await eventually(condition) } catch {
            Issue.record(message)
            throw error
        }
    }
}

@MainActor
private final class PairingSessionProbe {
    let gate = PairingGate()
    var session: ServerSession?
    var port: NWEndpoint.Port?
    var pin: String?
    var saved = false
    var authenticated = false
}
