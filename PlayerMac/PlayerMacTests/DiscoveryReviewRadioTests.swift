import Foundation
import MusicCore
import Testing

@testable import Kinrox

@MainActor
struct DiscoveryReviewRadioTests {
    func snapshot(_ tracks: [MusicTrack]) -> MusicDiscoverySnapshot {
        .init(
            items: tracks.map { .init(track: $0, reasons: [.init(kind: .collaborator)], score: 1) })
    }

    @Test func refillStaysBusyUntilEngineCommitAndRetriesFailures() async throws {
        let model = MusicViewModel()
        let engine = FakeMusicEngine()
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: model)
        model.connect(engine: engine)
        let candidates = Array(model.catalog.tracks.prefix(10))
        let initial = try #require(model.currentTrack)
        model.queue.start([initial])
        model.paused = false
        model.isDiscoveryRadioActive = true
        model.disallowedActions = ["interrupting_playback"]
        var requests = 0
        model.radioDiscoveryProvider = { _ in
            requests += 1
            return snapshot(candidates)
        }
        engine.waitsForUpdate = true
        engine.updateError = URLError(.networkConnectionLost)
        model.refillDiscoveryRadioIfNeeded()
        for _ in 0..<100 where engine.updateGate == nil { await Task.yield() }
        #expect(engine.updateGate != nil)
        #expect(model.isRefillingRadio)
        #expect(model.radioSeenTrackIDs.isEmpty)
        model.refillDiscoveryRadioIfNeeded()
        #expect(requests == 1)
        engine.updateGate?.resume()
        engine.updateGate = nil
        await model.radioRefillTask?.value
        #expect(!model.isRefillingRadio)
        #expect(model.queue.source.isEmpty)
        #expect(model.radioSeenTrackIDs.isEmpty)
        #expect(model.radioAttemptedOccurrences.isEmpty)
        engine.updateError = nil
        engine.waitsForUpdate = false
        model.refillDiscoveryRadioIfNeeded()
        await model.radioRefillTask?.value
        #expect(requests == 2)
        #expect(!model.queue.source.isEmpty)
        #expect(!model.radioSeenTrackIDs.isEmpty)
        await coordinator.close()
    }

    @Test func transientDiscoveryFailureAndRemovingQueuedItemsAllowSameOccurrenceRefill()
        async throws
    {
        let model = MusicViewModel()
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: model)
        let tracks = model.catalog.tracks
        model.queue.start([try #require(tracks.first)])
        model.isDiscoveryRadioActive = true
        var attempts = 0
        model.radioDiscoveryProvider = { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.timedOut) }
            return snapshot(Array(tracks.dropFirst().prefix(attempts == 2 ? 5 : 15)))
        }
        model.refillDiscoveryRadioIfNeeded()
        await model.radioRefillTask?.value
        #expect(model.radioAttemptedOccurrences.isEmpty)
        model.refillDiscoveryRadioIfNeeded()
        await model.radioRefillTask?.value
        #expect(model.queue.source.count == 5)
        let removed = try #require(model.queue.source.last)
        model.removeFromQueue(removed.id)
        await coordinator.settle()
        await model.radioRefillTask?.value
        #expect(attempts == 3)
        #expect(model.queue.source.count > 4)
        #expect(!model.queue.items.contains { $0.track.id == removed.track.id })
        await coordinator.close()
    }

    @Test func onlyAnExhaustedPoolBlocksRepeatedRefills() async throws {
        let model = MusicViewModel()
        model.queue.start([try #require(model.catalog.tracks.first)])
        model.isDiscoveryRadioActive = true
        var attempts = 0
        model.radioDiscoveryProvider = { _ in
            attempts += 1
            return snapshot([])
        }
        model.refillDiscoveryRadioIfNeeded()
        await model.radioRefillTask?.value
        model.refillDiscoveryRadioIfNeeded()
        #expect(attempts == 1)
        #expect(model.radioAttemptedOccurrences == Set([try #require(model.queue.current?.id)]))
        model.stopDiscoveryRadio()
    }

    @Test func radioAndKeyboardContentsFollowVisibleSectionOrder() async throws {
        let model = MusicViewModel()
        let tracks = Array(model.catalog.tracks.prefix(3))
        let ranked: [MusicDiscoveryItem] = [
            .init(track: tracks[0], reasons: [.init(kind: .sharedGenre)], score: 10),
            .init(track: tracks[1], reasons: [.init(kind: .collaborator)], score: 5),
            .init(track: tracks[2], reasons: [.init(kind: .listenBrainzArtist)], score: 1),
        ]
        model.discoverySnapshot = .init(items: ranked)
        model.selection.select(source: .similar)
        model.refreshContents()
        let expected = [tracks[2].id, tracks[1].id, tracks[0].id]
        #expect(model.discoverySnapshot?.items == ranked)
        #expect(model.discoverySnapshot?.displayItems.map(\.id) == expected)
        #expect(model.contents.tracks.map(\.id) == expected)
        #expect(model.focusedTrackID == expected.first)
        model.radioDiscoveryProvider = { _ in snapshot([]) }
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: model)
        model.startDiscoveryRadio()
        await coordinator.settle()
        await model.radioRefillTask?.value
        #expect(model.queue.items.map(\.track.id) == expected)
        await coordinator.close()
    }
}
