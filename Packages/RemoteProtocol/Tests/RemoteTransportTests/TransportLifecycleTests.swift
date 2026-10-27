import Foundation
import Network
import Testing

@testable import RemoteTransport

@Suite("Transport lifecycle after review", .serialized)
@MainActor struct TransportLifecycleTests {
    @Test("waiting preserves listener until ready")
    func listenerWaiting() async throws {
        let h = try TransportHarness()
        defer { h.stop() }
        var states: [TransportServer.State] = []
        h.server.onStateChange = { states.append($0) }
        try h.server.start(advertise: false, loopbackOnly: true)
        h.server.listenerStateChanged(.waiting(.posix(.ENETDOWN)))
        #expect(h.server.state == .waiting(.posix(.ENETDOWN)))
        #expect(!states.contains(.stopped))
        try await eventually {
            if case .ready = h.server.state { return true }
            return false
        }
        _ = try await h.pair()
    }

    @Test("Listener failure reports only failed and allows restart")
    func listenerFailure() async throws {
        let h = try TransportHarness()
        defer { h.stop() }
        try await h.start()
        _ = try await h.pair()
        var states: [TransportServer.State] = []
        h.server.onStateChange = { states.append($0) }
        let error = NWError.posix(.ENETDOWN)
        h.server.listenerStateChanged(.failed(error))
        #expect(states == [.failed(.network(error))])
        #expect(h.server.connectionCount == 0)
        try await h.start()
        _ = try await h.pair()
    }

    @Test("After failed browser creates new search")
    func browserRestart() async throws {
        let browser = BonjourBrowser()
        defer { browser.stop() }
        browser.start()
        let error = NWError.posix(.ENETDOWN)
        browser.browserStateChanged(.failed(error))
        #expect(browser.state == .failed(error))
        browser.start()
        #expect(browser.state == .searching)
        try await eventually { browser.state == .ready }
    }

    @Test("Late cancellation of completed send preserves connection")
    func completedSendCancellation() async throws {
        let h = try WireHarness()
        defer { h.stop() }
        try await h.start()
        let peer = try #require(h.peer)
        let id = UUID()
        try await peer.send(Data([1]), id: id)
        // Reproducing onCancel handler deferred until contentProcessed.
        peer.cancelSend(id: id)
        #expect(!peer.isClosed)
        try await peer.send(Data([2]))
        try await eventually { h.wire?.frames == [Data([1]), Data([2])] }
    }
}
