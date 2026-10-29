import MediaPlayer
import RemoteProtocol
import Testing

@testable import Kinrox

@Suite("Live playlist observers", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LivePlaylistObserverTests {
    @Test(
        "Paused and final-frame navigation reaches a connected remote without ticks",
        arguments: [true, false])
    func connectedRemote(paused: Bool) async throws {
        let h = try RemoteServerHarness()
        let folder = try LivePlaylistFolder()
        defer { folder.remove() }
        let first = try folder.file("1.mkv")
        let engine = FakePlayerEngine()
        let model = PlayerViewModel(engine: engine, recents: h.recents)
        let center = FakeNowPlayingCenter()
        let nowPlaying = NowPlayingController(center: center)
        nowPlaying.connect(to: model)
        h.server.connect(to: model)
        do {
            model.open(url: first)
            model.receive(.started)
            model.receive(.loaded)
            model.receive(.property(.position, .number(42)))
            try await waitForRemote { model.playlist != nil }
            model.receive(.property(.paused, .flag(paused)))
            if !paused {
                model.receive(.property(.endReached, .flag(true)))
                try await waitForRemote { model.eofTask == nil }
            }
            #expect(!center.enabled.contains(.nextTrack))
            #expect(center.nowPlayingInfo?[MPMediaItemPropertyArtist] as? String == "Kinrox")
            try await h.start()
            _ = try await h.pair()
            let commands = engine.commands
            let recents = h.recents.items
            let initialMessages = h.messages.count
            try folder.file("2.mkv")
            try await waitForRemote {
                h.messages.dropFirst(initialMessages).contains {
                    if case .state(_, let state) = $0 {
                        state.canNext && state.position == 42
                    } else {
                        false
                    }
                }
            }
            #expect(center.enabled.contains(.nextTrack))
            #expect(
                center.nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
                    == folder.url.lastPathComponent)
            #expect(center.playbackState == .paused)
            #expect(model.currentURL == first && model.position == 42)
            #expect(engine.commands == commands && h.recents.items == recents)
        } catch {
            await h.stop()
            await model.shutdown()
            throw error
        }
        await h.stop()
        await model.shutdown()
    }

    @Test("Navigation changes bypass the 2 Hz position throttle")
    func immediateNavigation() {
        var sent: [PlayerState] = []
        let publisher = RemoteStatePublisher(now: { 0 }, publish: { sent.append($0) })
        let first = PlayerState(
            title: "1.mkv", position: 42, duration: 100, paused: true, volume: 0,
            fullscreen: false, hasMedia: true, canNext: false, canPrevious: false)
        let updated = PlayerState(
            title: "1.mkv", position: 42, duration: 100, paused: true, volume: 0,
            fullscreen: false, hasMedia: true, canNext: true, canPrevious: false)
        publisher.update(first)
        publisher.update(updated)
        #expect(sent == [first, updated])
        publisher.reset()
    }
}
