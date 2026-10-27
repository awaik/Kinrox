import Foundation
import RemoteProtocol
import Testing

@testable import RemoteiOS

@Suite("M5 State and Commands")
@MainActor struct RemotePlaybackTests {
    @Test("Monotonic position: correction, pause, duration boundary, and connection loss")
    func position() {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        h.clock.advance(2.5)
        #expect(h.model.position == 12.5)
        var state = RemoteModelHarness.playing
        state.position = 9
        state.paused = true
        h.current.emit(state)
        h.clock.advance(30)
        #expect(h.model.position == 9)
        state.position = 99
        state.paused = false
        h.current.emit(state)
        h.clock.advance(5)
        #expect(h.model.position == 100)
        state.position = 20
        h.current.emit(state)
        h.clock.advance(1)
        h.current.onStateChange?(.closed(.timeout))
        h.clock.advance(5)
        #expect(h.model.position == 21 && h.model.state.position == 20)
    }

    @Test("Dragging preserves target; seek and ack do not change actual position")
    func seekAndAcknowledgement() async {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        h.model.scrubTarget = 80
        var update = RemoteModelHarness.playing
        update.position = 11
        h.current.emit(update)
        #expect(h.model.scrubTarget == 80)
        #expect(h.current.commands.isEmpty)
        h.model.seek(to: h.model.scrubTarget!)
        await settleTasks()
        #expect(h.current.commands == [.seekAbsolute(seconds: 80)])
        let id = h.current.messages[0].header.id
        h.current.onEvent?(.message(.ack(.init(), .init(replyTo: id))))
        #expect(h.model.state.position == 11)
        update.position = 80
        h.current.emit(update)
        #expect(h.model.position == 80)
        update.title = "Other Movie"
        h.current.emit(update)
        #expect(h.model.scrubTarget == nil)
    }

    @Test("Volume capped at 10 Hz with last value, disconnect cancels tail")
    func volume() async {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        h.model.setVolume(10)
        for value in 11...90 { h.model.setVolume(Double(value)) }
        await settleTasks()
        #expect(h.current.commands == [.setVolume(volume: 10)])
        h.clock.advance(0.099)
        await settleTasks()
        #expect(h.current.commands.count == 1)
        h.clock.advance(0.001)
        await settleTasks()
        #expect(h.current.commands == [.setVolume(volume: 10), .setVolume(volume: 90)])
        h.model.setVolume(30)
        h.current.onStateChange?(.closed(.closed))
        h.clock.advance(0.5)
        h.current.connected()
        h.current.emit(RemoteModelHarness.playing)
        h.clock.advance(10)
        await settleTasks()
        #expect(h.current.commands.isEmpty)
    }

    @Test("Without connection commands do not queue, next/previous derive from state")
    func offlineAndAvailability() async {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        #expect(!h.model.canNext && h.model.canPrevious)
        h.model.next()
        h.model.previous()
        await settleTasks()
        #expect(h.current.commands == [.previous])
        h.current.onStateChange?(.closed(.closed))
        for _ in 0..<20 {
            h.model.togglePause()
            h.model.seek(by: 30)
            h.model.setVolume(80)
        }
        h.clock.advance(0.5)
        h.current.connected()
        h.current.emit(.empty)
        await settleTasks()
        #expect(h.current.commands.isEmpty)
        #expect(!h.model.canNext && !h.model.canPrevious)
        h.model.togglePause()
        #expect(h.current.commands.isEmpty)
    }

    @Test("Recent, replyTo responses, rejection, and timeout without fictitious success")
    func commandReplies() async {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        let item = RecentItem(id: UUID(), title: "Movie", available: true)
        h.current.onEvent?(.message(.recent(.init(), [item])))
        #expect(h.model.recents == [item])
        var accepted = 0
        h.model.open(item) { if $0 { accepted += 1 } }
        await settleTasks()
        let id = h.current.messages.last!.header.id
        h.current.onEvent?(.message(.ack(.init(), .init(replyTo: UUID()))))
        #expect(accepted == 0)
        h.current.onEvent?(
            .message(.error(.init(), .init(replyTo: id, code: .itemNotFound, message: ""))))
        #expect(accepted == 0 && !h.model.recents[0].available)
        #expect(h.model.commandError == L10n.text("File not found on Mac."))
        h.model.open(item) { if $0 { accepted += 1 } }
        await settleTasks()
        let second = h.current.messages.last!.header.id
        h.current.onEvent?(.message(.ack(.init(), .init(replyTo: second))))
        #expect(accepted == 1 && h.model.state.title == "Video.mkv")
        h.model.send(.togglePause)
        h.clock.advance(15)
        #expect(h.model.pending.isEmpty)
        #expect(
            h.model.commandError
                == L10n.text("Mac did not confirm command. Check player state."))
    }

    @Test("All UI commands are transmitted without optimistic state modification")
    func commandMapping() async {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        let initial = h.model.state
        h.model.togglePause()
        for value in [-30.0, -10, 10, 30] { h.model.seek(by: value) }
        h.model.toggleFullscreen()
        await settleTasks()
        #expect(h.current.commands.count == 6)
        #expect(h.current.commands.contains(.toggleFullscreen))
        #expect(h.model.state == initial)
    }

    @Test("Mac silence caps queue and explicitly rejects excess command")
    func commandBackpressure() async {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        for _ in 0..<32 { h.model.send(.togglePause) }
        var accepted = false
        #expect(h.model.send(.toggleFullscreen) { accepted = $0 } == nil)
        await settleTasks()
        #expect(h.current.commands.count == 32 && h.model.pending.count == 32)
        #expect(h.model.commandError != nil && !accepted)
        h.model.returnToPlayers()
        h.clock.advance(30)
        h.connect()
        await settleTasks()
        #expect(h.current.commands.isEmpty && h.model.pending.isEmpty)
    }
}
