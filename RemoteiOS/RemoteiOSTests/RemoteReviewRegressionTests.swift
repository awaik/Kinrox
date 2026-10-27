import Foundation
import RemoteProtocol
import Testing

@testable import RemoteiOS

@Suite("M5 Remote Review Regressions")
@MainActor struct RemoteReviewRegressionTests {
    @Test("New Mac is saved only after successful token write")
    func selectionRequiresSavedToken() {
        let h = RemoteModelHarness(paired: false)
        defer { h.model.stop() }
        h.model.select(h.model.players[0])
        #expect(h.preferences.selected == nil)
        h.store.fails = true
        h.current.connected(pairing: true)
        #expect(h.preferences.selected == nil && h.store.records.isEmpty)
        h.store.fails = false
        h.model.beginPairing()
        h.current.connected(pairing: true)
        #expect(h.preferences.selected?.id == h.serverId)
        #expect(h.store.records[h.serverId] != nil)
    }

    @Test("Remaining selection without token does not open remote after launch")
    func staleSelectionWithoutToken() {
        let h = RemoteModelHarness(paired: false, restore: true, discoverImmediately: false)
        defer { h.model.stop() }
        #expect(h.model.screen == .players && h.model.selected == nil)
        #expect(h.preferences.selected == nil && h.model.players.isEmpty)
        #expect(h.connections.isEmpty)
    }

    @Test(
        "Unavailable row does not initiate connection in live or demo mode",
        arguments: [false, true])
    func unavailableSelection(demo: Bool) {
        let h = RemoteModelHarness(paired: false, demo: demo)
        defer { h.model.stop() }
        let player = MacPlayer(
            id: UUID(), name: "Offline", status: .unavailable, detail: "Unavailable")
        h.model.select(player)
        #expect(h.model.screen == .players && h.model.selected == nil)
        #expect(h.preferences.selected == nil && h.connections.isEmpty)
    }

    @Test("Retry after incompatible version on PIN screen begins pair again")
    func incompatiblePairingRetry() {
        let h = RemoteModelHarness(paired: false)
        defer { h.model.stop() }
        h.model.select(h.model.players[0])
        h.current.onStateChange?(
            .closed(.protocolFailure(.init(code: .incompatibleVersion, message: ""))))
        h.model.retryConnection()
        #expect(h.model.screen == .pairing && h.model.connectionState == .connecting)
        #expect(h.connections.count == 2)
        if case .pair = h.current.mode {} else { Issue.record("Expected repeated pairing") }
    }

    @Test(
        "Auth rejection remains effective even after replyTo expires",
        arguments: [ProtocolError.Code.authFailed, .notPaired])
    func expiredAuthorizationError(code: ProtocolError.Code) throws {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        let id = try #require(h.model.send(.togglePause))
        h.clock.advance(15)
        h.current.onEvent?(.message(.error(.init(), .init(replyTo: id, code: code, message: ""))))
        #expect(h.model.connectionState == .needsPairing && !h.model.controlsEnabled)
        #expect(h.preferences.rejectedServers.contains(h.serverId))
        #expect(h.store.records[h.serverId] != nil)
    }

    @Test("Successful bye immediately terminates background socket retention")
    func completedByeReleasesRetirement() async {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        h.model.enterBackground()
        await settleTasks()
        #expect(h.current.closes == 1)
        #expect(h.model.retiringClient == nil && h.model.retirement == nil)
        h.clock.advance(0.25)
        #expect(h.current.closes == 1)
    }

    @Test("Hung bye closes in 0.25 s, old completion does not touch new socket")
    func stalledByeAndLateCompletion() async {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        let old = h.current
        var resume: CheckedContinuation<Void, Never>?
        old.sendOperation = { _ in await withCheckedContinuation { resume = $0 } }
        h.model.enterBackground()
        await settleTasks()
        h.clock.advance(0.25)
        #expect(old.closes == 1 && h.model.retiringClient == nil)
        h.model.enterForeground()
        h.discovery.servers = [RemoteModelHarness.server(id: h.serverId)]
        h.discovery.onChange?()
        h.current.connected()
        h.current.emit(RemoteModelHarness.playing)
        let new = h.current
        var resumeNew: CheckedContinuation<Void, Never>?
        new.sendOperation = { _ in await withCheckedContinuation { resumeNew = $0 } }
        h.model.enterBackground()
        await settleTasks()
        resume?.resume()
        await settleTasks()
        #expect(h.model.retiringClient === new && new.closes == 0)
        resumeNew?.resume()
        await settleTasks()
        #expect(h.model.retiringClient == nil && new.closes == 1)
    }
}
