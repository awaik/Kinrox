import RemoteProtocol
import Testing

@testable import RemoteiOS

@Suite("Remote screensaver controls")
@MainActor struct ScreensaverRemoteTests {
    @Test("Legacy Mac does not receive unsupported commands")
    func legacyMac() async {
        let h = RemoteModelHarness()
        h.connect()
        var result: Bool?
        h.model.setScreensaver(.matrix) { result = $0 }
        await settleTasks()
        #expect(result == false)
        #expect(!h.model.supportsScreensavers)
        #expect(h.current.commands.isEmpty)
        h.model.stop()
    }

    @Test("Ack does not invent active state; Mac state controls the screen and position")
    func confirmedState() async {
        let h = RemoteModelHarness()
        h.connect()
        var state = RemoteModelHarness.playing
        state.screensaver = .off
        h.current.emit(state)
        h.model.setScreensaver(.matrix) { _ in }
        await settleTasks()
        #expect(h.current.commands == [.setScreensaver(screensaver: .matrix)])
        #expect(h.model.state.screensaver == .off)
        state.screensaver = .matrix
        state.paused = true
        h.current.emit(state)
        h.clock.advance(10)
        #expect(h.model.position == state.position)
        h.model.setScreensaver(.off) { _ in }
        await settleTasks()
        #expect(h.current.commands.last == .setScreensaver(screensaver: .off))
        #expect(h.model.state.screensaver == .matrix)
        h.model.stop()
    }

    @Test("Opening a recent movie exits Matrix in demo mode")
    func demoOpen() {
        let h = RemoteModelHarness(demo: true)
        h.model.select(h.model.players[0])
        h.model.setScreensaver(.matrix) { #expect($0) }
        let next = h.model.recents[1]
        h.model.open(next) { #expect($0) }
        #expect(h.model.state.title == next.title)
        #expect(h.model.state.screensaver == .off)
        #expect(!h.model.state.paused)
        #expect(h.connections.isEmpty)
        h.model.stop()
    }

    @Test("Demo cannot resume, seek, or skip a movie under Matrix")
    func demoPlaybackWhileActive() {
        let demo = RemoteDemoStore()
        demo.setScreensaver(.matrix)
        let state = demo.state
        demo.togglePause()
        demo.seek(by: 10)
        demo.seek(to: 0)
        demo.next()
        demo.previous()
        #expect(demo.state == state)
    }

    @Test("Demo start pauses, stop retains position, and no network connection is made")
    func demo() {
        let h = RemoteModelHarness(demo: true)
        h.model.select(h.model.players[0])
        h.model.setScreensaver(.matrix) { #expect($0) }
        let position = h.model.state.position
        #expect(h.model.state.paused && h.model.state.screensaver == .matrix)
        h.model.setScreensaver(.off) { #expect($0) }
        #expect(h.model.state.paused && h.model.state.screensaver == .off)
        #expect(h.model.state.position == position)
        #expect(h.connections.isEmpty)
        h.model.stop()
    }
}
