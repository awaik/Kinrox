import Foundation
import RemoteProtocol
import RemoteTransport
import Testing

@testable import Kinrox

@Suite("M4.4: player and secure remote", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct RemoteServerTests {
    @Test("Pairing, initial state/recent without paths, commands and errors with replyTo")
    func pairingAndCommands() async throws {
        let h = try RemoteServerHarness()
        defer {
            h.server.stop()
            h.browser.stop()
            for client in h.clients { client.close() }
        }
        try await h.start()
        let client = try await h.pair()
        #expect(h.pairing.prompt == nil)
        #expect(h.server.connectedDevices.count == 1)
        if case .state(_, let state) = h.messages[0] {
            #expect(!state.hasMedia)
        } else {
            Issue.record("State must be first")
        }
        if case .recent(_, let items) = h.messages[1] {
            #expect(items.isEmpty)
        } else {
            Issue.record("Recent must be second")
        }
        expectError(try await h.command(.togglePause, client: client), .noMedia)
        try await h.loaded()
        try await waitForRemote {
            h.messages.contains {
                if case .recent(_, let items) = $0 { !items.isEmpty } else { false }
            }
        }
        let recent = try #require(h.messages.last { if case .recent = $0 { true } else { false } })
        let json = String(decoding: try Codec.encode(recent), as: UTF8.self)
        #expect(
            !json.contains(h.folder.path) && !json.contains("bookmark") && !json.contains("path"))
        h.engine.commands.removeAll()
        for command in [
            Command.togglePause, .setPaused(paused: false), .seekRelative(seconds: -30),
            .seekAbsolute(seconds: 300), .setVolume(volume: 40),
        ] {
            expectAck(try await h.command(command, client: client))
        }
        #expect(
            h.engine.commands == [
                .paused(true), .paused(false), .seekRelative(-30), .seekAbsolute(120), .volume(40),
            ])
        // UI already displays 40, but remote cannot be told unconfirmed value.
        #expect(h.server.snapshot.volume == 100)
        h.model.receive(.property(.volume, .number(40)))
        #expect(h.server.snapshot.volume == 40)
        expectError(try await h.command(.previous, client: client), .itemNotFound)
        expectAck(try await h.command(.next, client: client))
        expectError(try await h.command(.next, client: client), .itemNotFound)
        expectAck(try await h.command(.previous, client: client))
        var fullscreenChanges = 0
        h.model.onToggleFullscreen = {
            fullscreenChanges += 1
            h.model.isFullscreen.toggle()
        }
        expectAck(try await h.command(.toggleFullscreen, client: client))
        expectAck(try await h.command(.setFullscreen(fullscreen: true), client: client))
        expectAck(try await h.command(.setFullscreen(fullscreen: false), client: client))
        #expect(fullscreenChanges == 2)
        let recentId = try #require(h.recents.items.first?.id)
        var opened: UUID?
        h.server.openRecent = {
            opened = $0
            return $0 == recentId ? nil : .itemNotFound
        }
        expectAck(try await h.command(.openRecent(itemId: recentId), client: client))
        #expect(opened == recentId)
        expectError(try await h.command(.openRecent(itemId: UUID()), client: client), .itemNotFound)
        h.engine.commandError = RemoteTestError.storage
        expectError(try await h.command(.setPaused(paused: true), client: client), .internal)
        h.server.connect(to: nil)
        #expect(!h.server.snapshot.hasMedia)
        expectError(try await h.command(.seekRelative(seconds: 10), client: client), .noMedia)
        await h.stop()
    }

    @Test("Owner rejection, window close, and Keychain error do not authorize remote")
    func rejectsPairing() async throws {
        let store = MemoryPairedDevices()
        let h = try RemoteServerHarness(store: store)
        defer {
            h.server.stop()
            h.browser.stop()
            for client in h.clients { client.close() }
        }
        try await h.start()
        let rejected = try h.client()
        try await waitForRemote { h.pairing.prompt != nil }
        h.pairing.decline()
        try await waitForRemote { if case .closed = rejected.state { true } else { false } }
        if case .closed(.protocolFailure(let error)) = rejected.state {
            #expect(error.code == .pairingRejected)
        } else {
            Issue.record("Expected pairingRejected")
        }
        #expect(h.pairing.prompt == nil && h.server.connectedDevices.isEmpty)
        let closedWindow = try h.client()
        try await waitForRemote { h.pairing.prompt != nil }
        h.server.windowClosed()
        try await waitForRemote { if case .closed = closedWindow.state { true } else { false } }
        store.fails = true
        let denied = try h.client()
        try await waitForRemote { denied.state == .awaitingPIN && h.pairing.prompt != nil }
        try await denied.submitPIN(#require(h.pairing.prompt?.code))
        try await waitForRemote { if case .closed = denied.state { true } else { false } }
        #expect(h.server.connectedDevices.isEmpty && h.tokens.isEmpty && store.records.isEmpty)
        #expect(h.server.errorMessage != nil)
        await h.stop()
    }

    @Test(
        "Shutdown, sleep/wake, and network change preserve identity and token; forget revokes access"
    )
    func lifecycleAndForget() async throws {
        let h = try RemoteServerHarness()
        defer {
            h.server.stop()
            h.browser.stop()
            for client in h.clients { client.close() }
        }
        try await h.start()
        let id = UUID()
        let client = try await h.pair(id)
        let token = try #require(h.tokens[id])
        h.server.setEnabled(false)
        try await waitForRemote { if case .closed = client.state { true } else { false } }
        #expect(h.server.state == .stopped && h.server.connectedDevices.isEmpty)
        let next = RemoteServer(
            defaults: h.defaults, store: h.store, recents: h.recents,
            pairing: PairingCenter())
        #expect(!next.isEnabled && next.serverId == h.server.serverId)
        h.server.setEnabled(true)
        try await waitForRemote { h.server.isOnline && h.discovered != nil }
        let authenticated = try h.client(id, token: token)
        try await waitForRemote { authenticated.state == .connected }
        #expect(h.pairing.prompt == nil)
        h.server.willSleep()
        #expect(h.server.state == .stopped)
        h.server.didWake()
        try await waitForRemote { h.server.isOnline }
        h.server.networkChanged()
        try await waitForRemote { h.server.isOnline && h.discovered != nil }
        let sameDevice = try h.client(id, token: token)
        try await waitForRemote { sameDevice.state == .connected }
        h.server.forget(id)
        try await waitForRemote { if case .closed = sameDevice.state { true } else { false } }
        #expect(h.server.devices.isEmpty && h.server.connectedDevices.isEmpty)
        let forgotten = try h.client(id, token: token)
        try await waitForRemote { if case .closed = forgotten.state { true } else { false } }
        if case .closed(.protocolFailure(let error)) = forgotten.state {
            #expect(error.code == .authFailed)
        } else {
            Issue.record("Forgotten token must receive authFailed")
        }
        await h.stop()
    }

    @Test("All authorized remotes receive state/recent; forget closes unfinished pair")
    func broadcastsAndRevokesPendingPair() async throws {
        let h = try RemoteServerHarness()
        defer {
            h.server.stop()
            h.browser.stop()
            for client in h.clients { client.close() }
        }
        try await h.start()
        let id = UUID()
        let first = try await h.pair(id)
        let second = try await h.pair()
        var received: [Message] = []
        second.onEvent = { if case .message(let message) = $0 { received.append(message) } }
        try await h.loaded()
        h.model.receive(.property(.paused, .flag(true)))
        try await waitForRemote {
            received.contains {
                if case .state(_, let state) = $0 { state.hasMedia && state.paused } else { false }
            }
                && received.contains {
                    if case .recent(_, let items) = $0 { !items.isEmpty } else { false }
                }
        }
        received.removeAll()
        try await second.send(.requestState(.init()))
        try await waitForRemote { !received.isEmpty }
        if case .state(_, let state) = received[0] {
            #expect(state == h.server.snapshot)
        } else {
            Issue.record("Expected snapshot on requestState")
        }
        h.recents.clear()
        try await waitForRemote {
            received.contains {
                if case .recent(_, let items) = $0 { items.isEmpty } else { false }
            }
        }
        let pending = try h.client(id)
        try await waitForRemote { h.pairing.prompt != nil }
        h.server.forget(id)
        try await waitForRemote {
            if case .closed = first.state, case .closed = pending.state { true } else { false }
        }
        #expect(h.pairing.prompt == nil)
        #expect(second.state == .connected && h.server.connectedDevices.count == 1)
        await h.stop()
    }

    @Test("Network notifications preserve a healthy listener and authenticated remote")
    func networkUpdatesPreserveConnection() async throws {
        let h = try RemoteServerHarness()
        defer {
            h.server.stop()
            h.browser.stop()
            for client in h.clients { client.close() }
        }
        try await h.start()
        let client = try await h.pair()
        let listenerState = h.server.state
        for _ in 0..<3 {
            h.server.networkChanged()
            #expect(h.server.state == listenerState)
            #expect(h.server.connectedDevices.count == 1)
        }
        h.messages.removeAll()
        try await client.send(.requestState(.init()))
        try await waitForRemote { !h.messages.isEmpty }
        #expect(client.state == .connected)
        await h.stop()
    }

    private func expectAck(_ message: Message) {
        if case .ack = message {} else { Issue.record("Expected command ack") }
    }

    private func expectError(_ message: Message, _ code: ProtocolError.Code) {
        if case .error(_, let error) = message {
            #expect(error.code == code)
        } else {
            Issue.record("Expected error \(code)")
        }
    }
}
