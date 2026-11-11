import Foundation
import RemoteProtocol
import Testing

@testable import RemoteiOS

@MainActor
struct SimilarRemoteTests {
    @Test func olderMacExplainsUpdateWithoutSendingCommands() async {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        h.current.emit(state(similar: nil))
        #expect(!h.model.supportsSimilar && h.model.canStartSimilar)
        h.model.setSimilar(true)
        h.model.hideFromSimilar(track, scope: .track)
        await settleTasks()
        #expect(h.current.messages.isEmpty)
        #expect(h.model.commandError == L10n.text("Update Kinrox on Mac to use Similar."))
    }

    @Test func startSendsOnceAndWaitsForConfirmedState() async throws {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        h.current.emit(state(similar: .init(active: false, available: true)))
        h.model.setSimilar(true)
        h.model.setSimilar(true)
        await settleTasks()
        let sent = try #require(h.current.messages.first)
        #expect(h.current.messages.count == 1)
        guard case .command(_, .setSimilar(active: true)) = sent else {
            Issue.record("Expected setSimilar")
            return
        }
        #expect(h.model.similarFinding && !h.model.similarActive && !h.model.canStartSimilar)
        h.current.onEvent?(.message(.ack(.init(), .init(replyTo: sent.header.id))))
        #expect(!h.model.similarFinding && !h.model.similarActive)
        h.current.emit(state(similar: .init(active: true, finding: true, available: true)))
        #expect(h.model.similarFinding && !h.model.similarActive)
        h.model.hideFromSimilar(track, scope: .track)
        await settleTasks()
        #expect(h.current.messages.count == 1)
        h.current.emit(state(similar: .init(active: true, finding: false, available: true)))
        #expect(h.model.similarActive && !h.model.similarFinding)
        h.model.setSimilar(false)
        await settleTasks()
        guard case .command(_, .setSimilar(active: false)) = h.current.messages.last else {
            Issue.record("Expected stop")
            return
        }
    }

    @Test func unavailableMacStartIsNotSent() async {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        h.current.emit(state(similar: .init(active: false, available: false)))
        #expect(!h.model.canStartSimilar)
        h.model.setSimilar(true)
        await settleTasks()
        #expect(h.current.messages.isEmpty)
    }

    @Test func notInterestedOffersUndoAfterAckAndExpires() async throws {
        let h = RemoteModelHarness()
        defer { h.model.stop() }
        h.connect()
        h.current.emit(state(similar: .init(active: false, available: true)))
        h.model.hideFromSimilar(track, scope: .artist)
        await settleTasks()
        #expect(h.current.messages.isEmpty)

        h.current.emit(state(similar: .init(active: true, available: true)))
        h.model.hideFromSimilar(track, scope: .artist)
        await settleTasks()
        let hide = try #require(h.current.messages.last)
        guard case .command(_, .setNotInterested("track", .artist, true)) = hide else {
            Issue.record("Expected hide")
            return
        }
        #expect(h.model.similarFeedback == nil)
        h.current.onEvent?(.message(.ack(.init(), .init(replyTo: hide.header.id))))
        let feedback = try #require(h.model.similarFeedback)
        #expect(feedback.text == L10n.format("Hidden %@ from Similar", "Artist"))

        h.model.undoHiddenFromSimilar()
        await settleTasks()
        #expect(h.model.similarFeedback == nil)
        guard case .command(_, .setNotInterested("track", .artist, false)) = h.current.messages.last
        else {
            Issue.record("Expected undo")
            return
        }

        h.model.hideFromSimilar(track, scope: .track)
        await settleTasks()
        let second = try #require(h.current.messages.last)
        h.current.onEvent?(.message(.ack(.init(), .init(replyTo: second.header.id))))
        #expect(h.model.similarFeedback?.text == L10n.format("Hidden “%@” from Similar", "Test"))
        h.clock.advance(6)
        #expect(h.model.similarFeedback == nil)
    }

    @Test func demoStartsFromCurrentAndHidesArtist() throws {
        let model = RemoteAppModel(isDemo: true)
        model.start()
        model.select(try #require(model.players.first))
        model.enableMusicDemo()
        defer { model.stop() }
        let demo = try #require(model.musicDemo)
        let current = try #require(demo.queue.current)
        model.setSimilar(true)
        #expect(model.similarActive)
        #expect(demo.queue.current?.id == current.id)
        #expect(!demo.queue.source.isEmpty)
        let playing = try #require(model.state.music?.track)
        model.hideFromSimilar(playing, scope: .artist)
        #expect(model.state.music?.track?.artists.first != playing.artists.first)
        #expect(
            !demo.queue.source.contains { $0.track.artists.first?.name == playing.artists.first })
        #expect(model.similarFeedback != nil)
    }

    private var track: RemoteMusicTrack {
        .init(
            id: "track", title: "Test", artists: ["Artist"], album: "Album", year: "2025",
            duration: 180)
    }

    private func state(similar: RemoteSimilarState?) -> PlayerState {
        .init(
            title: "Test", position: 42, duration: 180, paused: false, volume: 0, fullscreen: false,
            hasMedia: true, canNext: true, canPrevious: false, source: .music,
            music: .init(
                track: track, nextTrack: track, liked: false, shuffle: false, repeatMode: .off,
                queueCount: 2, queueRevision: UUID(), libraryRevision: UUID(),
                outputName: "Test Mac", similar: similar))
    }
}
