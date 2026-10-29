import Foundation
import RemoteProtocol
import Testing

@testable import Kinrox

@Suite("Matrix remote transport", .timeLimit(.minutes(1)))
@MainActor struct ScreensaverRemoteTests {
    @Test("Secure remote start and stop publish actual state without resuming the movie")
    func roundTrip() async throws {
        let h = try RemoteServerHarness()
        try await h.start()
        let client = try await h.pair()
        try await h.loaded()
        h.model.receive(.property(.position, .number(42)))
        let header = Message.Header()
        try await client.send(.command(header, .setScreensaver(screensaver: .matrix)))
        // A second command is a transport barrier: Matrix must not block the receive loop.
        _ = try await h.command(.setVolume(volume: 0), client: client)
        #expect(h.reply(to: header.id) == nil)
        #expect(h.model.isStartingScreensaver)
        #expect(h.model.screensaver == .off)
        h.model.receive(.property(.paused, .flag(true)))
        try await waitForRemote { h.reply(to: header.id) != nil }
        if case .ack = h.reply(to: header.id) {} else { Issue.record("Start was rejected") }
        try await waitForRemote {
            h.messages.contains {
                if case .state(_, let s) = $0 {
                    s.screensaver == .matrix && s.paused
                } else {
                    false
                }
            }
        }
        let stopped = try await h.command(.setScreensaver(screensaver: .off), client: client)
        if case .ack = stopped {} else { Issue.record("Stop was rejected") }
        #expect(h.model.screensaver == .off)
        #expect(h.model.paused && h.model.position == 42)
        #expect(!h.engine.commands.contains(.paused(false)))
        await h.stop()
    }

    @Test(
        "Failed or cancelled Matrix starts return one error to the requesting phone",
        arguments: ["failure", "timeout", "stop", "open", "shutdown"])
    func failedStart(reason: String) async throws {
        let h = try RemoteServerHarness()
        try await h.start()
        let client = try await h.pair()
        try await h.loaded()
        let header = Message.Header()
        try await client.send(.command(header, .setScreensaver(screensaver: .matrix)))
        _ = try await h.command(.setVolume(volume: 0), client: client)
        #expect(h.reply(to: header.id) == nil)
        switch reason {
        case "failure": h.model.receive(.failure("Pause failed"))
        case "stop": _ = try await h.command(.setScreensaver(screensaver: .off), client: client)
        case "open": h.model.open(url: h.folder.appendingPathComponent("2.mkv"))
        case "shutdown": await h.model.shutdown()
        default: break  // Exercise the real five-second timeout.
        }
        try await waitForRemote { h.reply(to: header.id) != nil }
        if case .error(_, let error) = h.reply(to: header.id) {
            #expect(error.code == .internal)
        } else {
            Issue.record("Failed start was acknowledged as successful")
        }
        h.model.receive(.property(.paused, .flag(true)))
        #expect(h.model.screensaver == .off)
        #expect(
            h.messages.filter {
                if case .error(_, let error) = $0 { error.replyTo == header.id } else { false }
            }.count == 1)
        await h.stop()
    }

    @Test("Screensaver transitions publish immediately even inside the position throttle")
    func immediateState() {
        var sent: [PlayerState] = []
        let publisher = RemoteStatePublisher(now: { 0 }, publish: { sent.append($0) })
        var state = PlayerState(
            title: "", position: 0, duration: 0, paused: true,
            volume: 0, fullscreen: false, hasMedia: false,
            canNext: false, canPrevious: false, screensaver: .off)
        publisher.update(state)
        state.screensaver = .matrix
        publisher.update(state)
        #expect(sent.count == 2)
        #expect(sent.last?.screensaver == .matrix)
    }
}
