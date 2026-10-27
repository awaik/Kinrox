import Foundation
import RemoteProtocol
import Testing

@testable import RemoteiOS

@Suite("M5 Recent List Command Completion")
@MainActor struct RemoteCommandCompletionTests {
    @Test("Identical errors complete each openRecent, unrelated replyTo does not clear pending")
    func repeatedErrors() throws {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        let items = (0..<2).map { RecentItem(id: UUID(), title: "Movie \($0)", available: true) }
        h.model.recents = items
        var outcomes: [Bool] = []
        for item in items {
            let count = outcomes.count
            h.model.open(item) { outcomes.append($0) }
            let id = try #require(h.model.pending.keys.first)
            h.current.onEvent?(
                .message(.error(.init(), .init(replyTo: UUID(), code: .itemNotFound, message: ""))))
            #expect(outcomes.count == count)
            h.current.onEvent?(
                .message(.error(.init(), .init(replyTo: id, code: .itemNotFound, message: ""))))
            h.current.onEvent?(.message(.ack(.init(), .init(replyTo: id))))
            #expect(outcomes.count == count + 1 && outcomes.last == false)
            #expect(h.model.commandError == L10n.text("File not found on Mac."))
        }
        #expect(h.model.recents.allSatisfy { !$0.available })
    }

    @Test("Queue overflow, unavailability, and disconnection reject commands immediately")
    func immediateRejection() {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        var item = RecentItem(id: UUID(), title: "Movie", available: true)
        var outcomes: [Bool] = []
        for _ in 0..<32 { h.model.send(.togglePause) }
        for _ in 0..<2 { h.model.open(item) { outcomes.append($0) } }
        #expect(outcomes == [false, false])
        item.available = false
        h.model.open(item) { outcomes.append($0) }
        h.model.enterBackground()
        item.available = true
        h.model.open(item) { outcomes.append($0) }
        #expect(outcomes == [false, false, false, false])
    }

    @Test("Timeout and cancellation complete request once, late ack does not close sheet")
    func timeoutAndCancellation() throws {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        let item = RecentItem(id: UUID(), title: "Movie", available: true)
        var outcomes: [Bool] = []
        h.model.open(item) { outcomes.append($0) }
        let id = try #require(h.model.pending.keys.first)
        h.clock.advance(15)
        h.current.onEvent?(.message(.ack(.init(), .init(replyTo: id))))
        #expect(outcomes == [false])
        h.model.open(item) { outcomes.append($0) }
        h.model.enterBackground()
        h.clock.advance(30)
        #expect(outcomes == [false, false])
    }

    @Test("Send failure completes openRecent without false success")
    func sendFailure() async {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        h.current.sendOperation = { _ in throw RemoteTestFailure.timeout }
        var outcomes: [Bool] = []
        h.model.open(.init(id: UUID(), title: "Movie", available: true)) { outcomes.append($0) }
        await settleTasks()
        #expect(outcomes == [false] && h.model.pending.isEmpty)
    }

    @Test("Only matching ack completes open with success")
    func acknowledgement() throws {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        var outcomes: [Bool] = []
        h.model.open(.init(id: UUID(), title: "Movie", available: true)) { outcomes.append($0) }
        let id = try #require(h.model.pending.keys.first)
        h.current.onEvent?(.message(.ack(.init(), .init(replyTo: UUID()))))
        #expect(outcomes.isEmpty)
        h.current.onEvent?(.message(.ack(.init(), .init(replyTo: id))))
        h.clock.advance(15)
        #expect(outcomes == [true])
    }
}
