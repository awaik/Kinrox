import Foundation
import Network
import Testing

@testable import RemoteTransport

@Suite("Connection path recovery", .serialized)
@MainActor struct WebSocketPathRecoveryTests {
    @Test(
        "Loss of local approval for the connected address remains retryable",
        arguments: [WebSocketPeer.Role.client, .server])
    func lostSubnet(_ role: WebSocketPeer.Role) async throws {
        var permitted = true
        var checkedEndpoint: NWEndpoint?
        let h = try WireHarness(role: role) { endpoint in
            checkedEndpoint = endpoint
            return permitted && LocalNetworkPolicy.permits(endpoint)
        }
        defer { h.stop() }
        try await h.start(role: role)
        let peer = try #require(h.peer)
        let endpoint = try #require(checkedEndpoint)
        try await h.wire?.send(Data([42]))
        try await eventually { h.received == [Data([42])] }

        // Simulate getifaddrs losing the subnet before NWPath becomes unsatisfied.
        permitted = false
        peer.pathChanged(status: .satisfied, endpoint: endpoint)
        #expect(h.peerFailure == .notConnected)
        #expect(peer.isClosed && !peer.isReady)
        await #expect(throws: TransportFailure.notConnected) { try await peer.send(Data([43])) }
    }

    @Test(
        "Initial local-policy rejection remains terminal",
        arguments: [WebSocketPeer.Role.client, .server])
    func initialRejection(_ role: WebSocketPeer.Role) async throws {
        let h = try WireHarness(role: role, permitsEndpoint: { _ in false })
        defer { h.stop() }
        await #expect(throws: TransportFailure.nonLocalEndpoint) { try await h.start(role: role) }
        #expect(h.peer?.isClosed == true)
        #expect(h.received.isEmpty)
    }

    @Test("Approval does not carry over to a different endpoint on the same host")
    func changedEndpoint() async throws {
        var permitted = true
        var checkedEndpoint: NWEndpoint?
        let h = try WireHarness(role: .client) { endpoint in
            checkedEndpoint = endpoint
            return permitted && LocalNetworkPolicy.permits(endpoint)
        }
        defer { h.stop() }
        try await h.start(role: .client)
        let peer = try #require(h.peer)
        guard case .hostPort(let host, let port) = checkedEndpoint else {
            Issue.record("Ready socket must have a resolved host and port")
            return
        }
        permitted = false
        peer.pathChanged(
            status: .satisfied, endpoint: .hostPort(host: host, port: port == 1 ? 2 : 1))
        #expect(h.peerFailure == .nonLocalEndpoint)
        #expect(peer.isClosed)
    }

    @Test(
        "Missing or unresolved route closes as a retryable network loss",
        arguments: [NWPath.Status.satisfied, .unsatisfied, .requiresConnection])
    func missingRoute(_ status: NWPath.Status) async throws {
        for endpoint: NWEndpoint? in [
            nil,
            .service(name: "Mac", type: "_kinrox._tcp", domain: "local.", interface: nil),
            .hostPort(host: .name("mac.local", nil), port: 1234),
        ] {
            let h = try WireHarness(role: .client)
            defer { h.stop() }
            try await h.start(role: .client)
            let peer = try #require(h.peer)
            peer.pathChanged(status: status, endpoint: endpoint)
            #expect(h.peerFailure == .notConnected)
            #expect(peer.isClosed)
        }
    }

    @Test("An unavailable path is retryable even if it retains an old address")
    func unavailableRoute() async throws {
        let h = try WireHarness(role: .client)
        defer { h.stop() }
        try await h.start(role: .client)
        let peer = try #require(h.peer)
        peer.pathChanged(
            status: .unsatisfied, endpoint: .hostPort(host: .ipv4(.loopback), port: 1234))
        #expect(h.peerFailure == .notConnected)
        #expect(peer.isClosed)
    }

    @Test("A usable local path update preserves the connected socket")
    func localRoute() async throws {
        let h = try WireHarness(role: .client)
        defer { h.stop() }
        try await h.start(role: .client)
        let peer = try #require(h.peer)
        peer.pathChanged(
            status: .satisfied, endpoint: .hostPort(host: .ipv4(.loopback), port: 1234))
        #expect(h.peerFailure == nil)
        try await h.wire?.send(Data([42]))
        try await eventually { h.received == [Data([42])] }
    }

    @Test("Resolved nonlocal addresses still fail the security policy")
    func nonlocalRoute() async throws {
        let h = try WireHarness(role: .client)
        defer { h.stop() }
        try await h.start(role: .client)
        let peer = try #require(h.peer)
        // Documentation-only address, never contacted by the test.
        peer.pathChanged(
            status: .satisfied,
            endpoint: .hostPort(host: .ipv4(IPv4Address("203.0.113.1")!), port: 1234))
        #expect(h.peerFailure == .nonLocalEndpoint)
        #expect(peer.isClosed)
    }
}
