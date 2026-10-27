import AppKit
import Foundation
import RemoteProtocol
import Testing

@testable import Kinrox

@Suite("M4.4: review regressions", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RemoteReviewRegressionTests {
    @Test(
        "Seek publishes confirmed position under both time-pos/RESTART orderings",
        arguments: [false, true])
    func seekEventOrdering(_ positionFirst: Bool) async throws {
        let h = try RemoteServerHarness()
        defer {
            h.server.stop()
            h.browser.stop()
            for client in h.clients { client.close() }
        }
        try await h.start()
        let client = try await h.pair()
        try await h.loaded()
        h.model.receive(.property(.position, .number(5)))
        h.model.receive(.property(.paused, .flag(true)))
        _ = try await h.command(.togglePause, client: client)
        h.messages.removeAll()
        h.model.receive(.property(.position, .number(6)))
        h.model.receive(.seeking)
        if positionFirst { h.model.receive(.property(.position, .number(0))) }
        h.model.receive(.playbackRestarted)
        if !positionFirst { h.model.receive(.property(.position, .number(0))) }
        _ = try await h.command(.togglePause, client: client)
        let positions = h.messages.compactMap { message -> Double? in
            if case .state(_, let state) = message { state.position } else { nil }
        }
        #expect(!positions.isEmpty)
        #expect(positions.allSatisfy { $0 == 0 })
        await h.stop()
    }

    @Test("Authorization sends single recent, updates available to old and new remotes")
    func initialRecentsAreNotDuplicated() async throws {
        let h = try RemoteServerHarness(preloadRecent: true)
        defer {
            h.server.stop()
            h.browser.stop()
            for client in h.clients { client.close() }
        }
        try await h.start()
        let first = try await h.pair()
        _ = try await h.command(.togglePause, client: first)
        #expect(recents(in: h.messages).count == 1)
        #expect(recents(in: h.messages).last?.first?.available == false)
        h.messages.removeAll()
        try Data().write(to: h.folder.appendingPathComponent("1.mkv"))
        let second = try h.client()
        var secondMessages: [Message] = []
        second.onEvent = {
            if case .message(let message) = $0 { secondMessages.append(message) }
        }
        try await waitForRemote { second.state == .awaitingPIN && h.pairing.prompt != nil }
        try await second.submitPIN(#require(h.pairing.prompt?.code))
        try await waitForRemote { second.state == .connected }
        let barrier = Message.command(.init(), .togglePause)
        try await second.send(barrier)
        try await waitForRemote {
            secondMessages.contains {
                if case .error(_, let error) = $0 {
                    error.replyTo == barrier.header.id
                } else {
                    false
                }
            } && !recents(in: h.messages).isEmpty
        }
        #expect(recents(in: secondMessages).count == 1)
        #expect(recents(in: h.messages).count == 1)
        #expect(recents(in: secondMessages).last?.first?.available == true)
        #expect(recents(in: h.messages).last?.first?.available == true)
        await h.stop()
    }

    @Test("Saved device appears in list before network confirmation")
    func devicesReloadBeforeAuthentication() async throws {
        let store = MemoryPairedDevices()
        let h = try RemoteServerHarness(store: store)
        defer {
            store.onRead = nil
            h.server.stop()
            h.browser.stop()
            for client in h.clients { client.close() }
        }
        try await h.start()
        var readBeforeAuthentication = false
        store.onRead = {
            if !store.records.isEmpty && h.server.connectedDevices.isEmpty {
                readBeforeAuthentication = true
            }
        }
        _ = try await h.pair()
        #expect(readBeforeAuthentication)
        #expect(h.server.devices.count == 1)
        await h.stop()
    }

    @Test("Repeated reachability check does not notify without changes")
    func unchangedAvailabilityIsSilent() throws {
        let h = try RemoteServerHarness(preloadRecent: true)
        h.recents.refreshAvailability()
        var changes = 0
        let observer = h.recents.observeChanges { changes += 1 }
        defer { h.recents.removeObserver(observer) }
        h.recents.refreshAvailability()
        #expect(changes == 0)
        try Data().write(to: h.folder.appendingPathComponent("1.mkv"))
        h.recents.refreshAvailability()
        #expect(changes == 1)
    }

    @Test("Command after didEnter awaits return from AppKit callback")
    func fullscreenCallbackBoundary() async throws {
        let controller = try PlayerWindowController { _ in }
        let model = controller.model
        model.setVolume(0)
        let original = controller.window
        let window = CountingFullscreenWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        let notification = Notification(
            name: NSWindow.didEnterFullScreenNotification, object: window)
        controller.windowWillEnterFullScreen(notification)
        controller.windowDidEnterFullScreen(notification)
        #expect(model.setFullscreen(false))
        #expect(window.toggles == 0)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(window.toggles == 1)
        controller.close()
        original?.close()
        await model.shutdown()
    }

    private func recents(in messages: [Message]) -> [[RemoteProtocol.RecentItem]] {
        messages.compactMap { if case .recent(_, let items) = $0 { items } else { nil } }
    }
}

@MainActor
private final class CountingFullscreenWindow: NSWindow {
    var toggles = 0
    override func toggleFullScreen(_ sender: Any?) { toggles += 1 }
}
