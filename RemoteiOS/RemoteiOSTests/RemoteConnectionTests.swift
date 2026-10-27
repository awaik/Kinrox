import Foundation
import Network
import RemoteProtocol
import Testing

@testable import RemoteTransport
@testable import RemoteiOS

@Suite("M5 Connection and Navigation")
@MainActor struct RemoteConnectionTests {
    @Test("Saved Macs remain without Bonjour, name and endpoint update without duplicates")
    func discoveryMerge() {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.discovery.servers = []
        h.discovery.onChange?()
        #expect(h.model.players.count == 1 && h.model.players[0].status == .unavailable)
        h.discovery.servers = [RemoteModelHarness.server(id: h.serverId, name: "New Name")]
        h.discovery.onChange?()
        #expect(h.model.players[0].name == "New Name" && h.model.players[0].status == .paired)
        h.connect()
        #expect(h.connections.count == 1)
        #expect(h.model.screen == .remote && h.model.controlsEnabled)
        h.model.returnToPlayers()
        #expect(h.model.screen == .players && h.preferences.selected == nil)
        #expect(h.current.closes == 1)
    }

    @Test("Discovery distinguishes empty network, no interface, refusal, and transport")
    func discoveryErrors() {
        let h = RemoteModelHarness(paired: false)
        defer { h.model.stop() }
        h.discovery.servers = []
        h.discovery.onChange?()
        #expect(h.model.discoveryStatus == .searching)
        h.clock.advance(10)
        #expect(h.model.discoveryStatus == .hints)
        #expect(
            RemoteDiscoveryStatus.resolve(
                browser: .waiting(.dns(-65570)), network: .available,
                hasServers: false, elapsed: true) == .permissionDenied)
        #expect(
            RemoteDiscoveryStatus.resolve(
                browser: .ready, network: .unavailable,
                hasServers: false, elapsed: true) == .noNetwork)
        #expect(
            RemoteDiscoveryStatus.resolve(
                browser: .failed(.posix(.ECONNREFUSED)), network: .available,
                hasServers: false, elapsed: true) == .transportError)
    }

    @Test("Pairing blocks double PIN, localizes protocol errors, and handles Keychain error")
    func pairing() async {
        let h = RemoteModelHarness(paired: false)
        defer { h.model.stop() }
        h.model.select(h.model.players[0])
        #expect(h.model.screen == .pairing)
        h.current.onEvent?(.enterPIN)
        h.model.submitPIN("123456")
        h.model.submitPIN("654321")
        await settleTasks()
        #expect(h.current.pins.count == 1 && h.model.connectionState == .checkingPIN)
        h.current.onEvent?(
            .protocolError(.init(code: .authFailed, message: "Remaining attempts: 7")))
        h.current.onEvent?(.retryPIN)
        #expect(h.model.pairingMessage == L10n.text("Incorrect code. Try again."))
        #expect(h.model.connectionState == .awaitingPIN)
        h.store.fails = true
        h.current.connected(pairing: true)
        #expect(h.model.connectionState == .failed && h.store.records.isEmpty)
        #expect(!h.model.controlsEnabled)
        h.store.fails = false
        h.model.beginPairing()
        h.current.connected(pairing: true)
        #expect(h.model.screen == .remote && h.store.records[h.serverId] != nil)
        #expect(!h.model.controlsEnabled)
        h.current.emit(.empty)
        #expect(h.model.controlsEnabled && !h.model.state.hasMedia)
    }

    @Test("Auth failure stops retries, does not delete token; new pairing is explicit")
    func authFailureAndForget() {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        let id = h.preferences.deviceId
        h.current.onStateChange?(.closed(.protocolFailure(.init(code: .authFailed, message: ""))))
        h.clock.advance(300)
        #expect(h.connections.count == 1 && h.model.connectionState == .needsPairing)
        #expect(h.store.records[h.serverId] != nil)
        #expect(h.preferences.rejectedServers.contains(h.serverId))
        h.model.beginPairing()
        if case .pair = h.current.mode {} else { Issue.record("Expected new pair") }
        h.current.connected(pairing: true)
        #expect(!h.preferences.rejectedServers.contains(h.serverId))
        h.model.forgetSelected()
        h.clock.advance(300)
        #expect(h.model.screen == .players && h.store.records.isEmpty)
        #expect(h.preferences.selected == nil)
        #expect(RemotePreferences(defaults: h.defaults).deviceId == id)
        #expect(h.connections.count == 2)
    }

    @Test("Stale callbacks and token saving do not affect new session")
    func staleCallbacks() throws {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        let oldEvent = h.current.onEvent
        let oldState = h.current.onStateChange
        let oldSave = h.current.save
        h.model.returnToPlayers()
        h.connect()
        oldEvent?(.enterPIN)
        oldEvent?(.message(.state(.init(), .empty)))
        oldState?(.closed(.timeout))
        #expect(throws: (any Error).self) { try oldSave(Data(repeating: 9, count: 32)) }
        #expect(h.model.screen == .remote && h.model.controlsEnabled)
        #expect(h.model.state.hasMedia)
        #expect(h.connections.count == 2 && h.connections[0].closes == 1)
    }

    @Test(
        "Retries 0.5,1,2,4,8,10 and independent overall limit of 120 seconds",
        arguments: [TransportFailure.timeout, .notConnected, .closed, .network(.posix(.ENETDOWN))])
    func retries(_ failure: TransportFailure) {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        h.current.onStateChange?(.closed(failure))
        for delay in [0.5, 1, 2, 4, 8, 10] {
            let count = h.connections.count
            #expect(h.model.nextRetryDelay == delay)
            h.clock.advance(delay - 0.01)
            #expect(h.connections.count == count)
            h.clock.advance(0.01)
            #expect(h.connections.count == count + 1)
            h.current.onStateChange?(.closed(failure))
        }
        h.clock.advance(120 - h.clock.now)
        #expect(h.model.connectionState == .failed && h.model.screen == .remote)
        let count = h.connections.count
        h.clock.advance(500)
        #expect(h.connections.count == count)
    }

    @Test("A lost route reconnects automatically with the stored token")
    func routeRecovery() {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        h.current.onStateChange?(.closed(.notConnected))
        #expect(h.model.connectionState == .reconnecting && !h.model.controlsEnabled)
        h.clock.advance(0.5)
        #expect(h.connections.count == 2)
        if case .authenticate = h.current.mode {} else { Issue.record("Expected token auth") }
        h.current.connected()
        h.current.emit(RemoteModelHarness.playing)
        #expect(h.model.controlsEnabled && h.model.failureMessage == nil)
        h.clock.advance(120)
        #expect(h.connections.count == 2 && h.model.connectionState == .connected)
    }

    @Test("A nonlocal endpoint stops retries and preserves the stored pairing")
    func nonlocalFailure() {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        h.current.onStateChange?(.closed(.nonLocalEndpoint))
        h.clock.advance(300)
        #expect(h.model.connectionState == .failed && !h.model.controlsEnabled)
        #expect(h.connections.count == 1 && h.store.records[h.serverId] != nil)
    }

    @Test("Background closes socket; foreground and restart restore Mac with token")
    func lifecycle() async {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        h.model.enterForeground()
        #expect(h.connections.count == 1)
        h.model.enterBackground()
        await settleTasks()
        h.clock.advance(0.25)
        #expect(h.current.closes >= 1)
        #expect(h.current.messages.contains { if case .bye = $0 { true } else { false } })
        h.clock.advance(200)
        #expect(h.connections.count == 1)
        h.model.enterForeground()
        #expect(h.connections.count == 1)
        h.discovery.servers = [RemoteModelHarness.server(id: h.serverId)]
        h.discovery.onChange?()
        #expect(h.connections.count == 2)
        if case .authenticate = h.current.mode {} else { Issue.record("Expected auth") }
        h.model.stop()
        let fresh = RemoteAppModel(
            credentials: h.store, preferences: h.preferences,
            discovery: h.discovery, scheduler: h.clock, monitorNetwork: false
        ) { _, _, mode, save in
            FakeRemoteConnection(mode: mode, save: save)
        }
        fresh.start()
        #expect(fresh.selected?.id == h.serverId && fresh.screen == .remote)
        fresh.stop()
    }

    @Test("Demo does not read storage and does not start network")
    func demoIsolation() {
        let h = RemoteModelHarness(demo: true)
        defer { h.model.stop() }
        h.model.select(h.model.players[0])
        h.model.setVolume(0)
        h.model.togglePause()
        h.model.forgetSelected()
        #expect(h.store.calls == 0 && h.discovery.starts == 0 && h.connections.isEmpty)
    }
}
