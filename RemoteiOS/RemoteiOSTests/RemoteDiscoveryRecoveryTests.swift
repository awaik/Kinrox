import Foundation
import Testing

@testable import RemoteTransport
@testable import RemoteiOS

@Suite("M5 Bonjour Discovery Recovery Regressions")
@MainActor struct RemoteDiscoveryRecoveryTests {
    @Test("Launch waits for async Bonjour without false reconnect")
    func launchWaitsForDiscovery() {
        let h = RemoteModelHarness(restore: true, discoverImmediately: false)
        defer { h.model.stop() }
        #expect(h.model.screen == .remote && h.model.connectionState == .connecting)
        #expect(h.model.retryAttempt == 0 && h.connections.isEmpty)
        h.clock.advance(0.2)
        h.discovery.servers = [RemoteModelHarness.server(id: h.serverId)]
        h.discovery.onChange?()
        #expect(h.connections.count == 1 && h.model.connectionState == .connecting)
        h.discovery.onChange?()
        #expect(h.connections.count == 1)
    }

    @Test("Manual retry uses still available Bonjour result")
    func retryKeepsAvailableServer() {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        h.current.onStateChange?(.closed(.timeout))
        h.model.retryConnection()
        #expect(h.discovery.stops == 0)
        #expect(h.connections.count == 2 && h.model.connectionState == .connecting)
    }

    @Test("Return to primary PIN waits for new Bonjour and begins pair")
    func pairingSurvivesBackground() {
        let h = RemoteModelHarness(paired: false)
        defer { h.model.stop() }
        h.model.select(h.model.players[0])
        h.current.onEvent?(.enterPIN)
        h.model.enterBackground()
        h.model.enterForeground()
        #expect(h.model.screen == .pairing && h.model.connectionState == .connecting)
        #expect(h.model.failureMessage == nil)
        h.discovery.servers = [RemoteModelHarness.server(id: h.serverId)]
        h.discovery.onChange?()
        #expect(h.connections.count == 2)
        if case .pair = h.current.mode {} else { Issue.record("Expected pair after background") }
    }

    @Test("Explicit code request after background waits for discovery and cancels on exit")
    func explicitPairWaitsAndCanBeCancelled() {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        h.model.enterBackground()
        h.model.enterForeground()
        h.model.beginPairing()
        #expect(h.model.connectionState == .connecting)
        h.discovery.servers = [RemoteModelHarness.server(id: h.serverId)]
        h.discovery.onChange?()
        #expect(h.connections.count == 2)
        if case .pair = h.current.mode {} else { Issue.record("Expected explicit pair") }
        h.model.enterBackground()
        h.model.enterForeground()
        h.model.returnToPlayers()
        h.discovery.servers = [RemoteModelHarness.server(id: h.serverId)]
        h.discovery.onChange?()
        h.clock.advance(300)
        #expect(h.connections.count == 2 && h.model.screen == .players)
    }

    @Test("After failure browser restarts in automatic retry")
    func failedBrowserRestarts() {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        h.discovery.stop()
        h.discovery.state = .failed(.posix(.ENETDOWN))
        h.discovery.onChange?()
        h.current.onStateChange?(.closed(.timeout))
        let starts = h.discovery.starts
        h.clock.advance(0.5)
        #expect(h.discovery.starts == starts + 1)
        h.discovery.servers = [RemoteModelHarness.server(id: h.serverId)]
        h.discovery.onChange?()
        #expect(h.connections.count == 2)
    }

    @Test("Bonjour wait is bounded and late discovery does not revive failure")
    func discoveryDeadline() {
        let h = RemoteModelHarness(restore: true, discoverImmediately: false)
        defer { h.model.stop() }
        h.clock.advance(120)
        #expect(h.model.connectionState == .failed)
        h.discovery.servers = [RemoteModelHarness.server(id: h.serverId)]
        h.discovery.onChange?()
        #expect(h.connections.isEmpty)
    }

    @Test("Network recovery restarts failure without touching running browser")
    func networkRecovery() {
        let h = RemoteModelHarness(restore: true, discoverImmediately: false)
        defer { h.model.stop() }
        h.discovery.state = .failed(.posix(.ENETDOWN))
        let starts = h.discovery.starts
        h.model.networkChanged(.available)
        #expect(h.discovery.starts == starts + 1)
        h.discovery.state = .ready
        h.model.networkChanged(.available)
        #expect(h.discovery.starts == starts + 1)
        h.discovery.servers = [RemoteModelHarness.server(id: h.serverId)]
        h.discovery.onChange?()
        #expect(h.connections.count == 1)
        h.model.enterBackground()
        h.model.networkChanged(.available)
        #expect(h.discovery.starts == starts + 1)
    }

    @Test(
        "Initial discovery transitions to retries, PIN discovery completes without indefinite wait")
    func searchTimeouts() {
        let h = RemoteModelHarness(restore: true, discoverImmediately: false)
        defer { h.model.stop() }
        h.clock.advance(9.99)
        #expect(h.model.connectionState == .connecting && h.model.retryAttempt == 0)
        h.clock.advance(0.01)
        #expect(h.model.connectionState == .reconnecting && h.model.retryAttempt == 1)
        h.model.beginPairing()
        h.clock.advance(10)
        #expect(h.model.connectionState == .failed && h.model.screen == .pairing)
        h.discovery.servers = [RemoteModelHarness.server(id: h.serverId)]
        h.discovery.onChange?()
        #expect(h.connections.isEmpty)
    }
}
