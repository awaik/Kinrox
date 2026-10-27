import Foundation
import Network
import Testing

@testable import RemoteTransport

@Suite("WebSocket stream termination")
@MainActor struct WebSocketEOFTests {
    @Test("Empty final context signifies EOF rather than corrupted message")
    func finalContext() {
        let peer = makePeer()
        var failure: TransportFailure?
        peer.onClose = { failure = $0 }
        peer.received(nil, context: .finalMessage, complete: true, error: nil)
        #expect(failure == .closed)
        #expect(peer.isClosed)
    }

    @Test("final context with data and nonterminal empty context do not bypass check")
    func invalidContexts() {
        for (data, context) in [
            (Data([1]), NWConnection.ContentContext.finalMessage),
            (nil, NWConnection.ContentContext.defaultMessage),
        ] {
            let peer = makePeer()
            var failure: TransportFailure?
            peer.onClose = { failure = $0 }
            peer.received(data, context: context, complete: true, error: nil)
            #expect(failure == .invalidMessage)
        }
    }

    @Test("Real server closure terminates client as disconnection")
    func serverDisconnect() async throws {
        let h = try TransportHarness()
        defer { h.stop() }
        try await h.start()
        let id = UUID()
        let client = try await h.pair(deviceId: id)
        h.server.disconnect(deviceId: id)
        try await eventually { if case .closed = client.state { true } else { false } }
        #expect(client.state == .closed(.closed))
    }

    private func makePeer() -> WebSocketPeer {
        WebSocketPeer(
            connection: NWConnection(host: .ipv4(.loopback), port: 1, using: .tcp), role: .client)
    }
}
