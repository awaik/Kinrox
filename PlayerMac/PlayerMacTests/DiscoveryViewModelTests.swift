import Foundation
import MusicCore
import Testing

@testable import Kinrox

@MainActor
struct DiscoveryViewModelTests {
    func observe(_ model: MusicViewModel, paused: Bool) throws {
        let item = try #require(model.queue.current)
        model.receive(
            .init(
                uri: item.track.uri, position: 0, duration: item.track.duration, paused: paused,
                volume: 0, deviceName: "Test", occurrenceID: item.id))
    }
    @Test func historyIgnoresRestoredPausedQueueAndDistinguishesSkipCompletionAndTransition()
        async throws
    {
        let model = MusicViewModel()
        let engine = FakeMusicEngine()
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: model)
        model.connect(engine: engine)
        var now = Date()
        model.historyNow = { now }
        model.next()
        await coordinator.settle()
        #expect(model.playHistory.isEmpty)
        try observe(model, paused: false)
        let skipped = model.currentTrack?.id
        now = now.addingTimeInterval(5)
        model.next()
        await coordinator.settle()
        #expect(model.playHistory.last?.trackID == skipped)
        #expect(model.playHistory.last?.skipped == true)
        // No new play session exists until the engine observes playing.
        #expect(model.activePlaySession == nil)
        try observe(model, paused: false)
        let completed = model.currentTrack?.id
        model.finishPlayHistory(completedNaturally: true)
        #expect(model.playHistory.last?.completed == true)
        #expect(model.playHistory.last?.skipped == false)
        model.next()
        await coordinator.settle()
        try observe(model, paused: false)
        model.finishPlayHistory(completedNaturally: true)
        #expect(model.playHistory.last?.previousTrackID == completed)
        let result = MusicDiscoveryEngine.build(
            seedTrackIDs: completed.map { [$0] } ?? [], hideLiked: false,
            catalog: MusicCatalog(
                tracks: model.catalog.tracks.filter {
                    $0.id == completed || $0.id == model.currentTrack?.id
                }),
            library: LibrarySnapshot(userID: "u"), history: model.playHistory)
        #expect(
            result.items.contains {
                $0.id == model.currentTrack?.id && $0.reasons.contains { $0.kind == .playHistory }
            })
        await coordinator.close()
    }
    @Test func pausedTimeAndSeekingDoNotBecomeListeningTime() throws {
        let model = MusicViewModel()
        var now = Date()
        model.historyNow = { now }
        try observe(model, paused: false)
        now = now.addingTimeInterval(10)
        try observe(model, paused: true)
        now = now.addingTimeInterval(500)
        model.position = 180
        model.finishPlayHistory()
        #expect(model.playHistory.last?.playedSeconds == 10)
        #expect(model.playHistory.last?.skipped == true)
    }
    @Test func notInterestedUndoAndSeedBackNavigation() throws {
        let model = MusicViewModel()
        let first = try #require(model.catalog.track(id: "evening-2"))
        let next = try #require(model.catalog.track(id: "neon-0"))
        model.openSimilar(forTrack: first)
        let visible = try #require(model.discoverySnapshot?.tracks.first)
        model.notInterested(track: visible)
        #expect(!model.discoverySnapshot!.tracks.contains { $0.id == visible.id })
        model.notInterested(artist: visible.artists[0])
        model.undoNotInterested()
        #expect(model.notInterestedTrackIDs.contains(visible.id))
        model.undoNotInterested()
        #expect(!model.canUndoNotInterested)
        #expect(model.discoverySnapshot!.tracks.contains { $0.id == visible.id })
        model.openSimilar(forTrack: next)
        #expect(model.canGoBackDiscovery)
        model.goBackDiscoverySeed()
        #expect(model.discoverySeedTrack?.id == first.id)
    }
    @Test func radioRefillsSourceAndCannotReplaceManualOrderOrSurviveSourceReplacement()
        async throws
    {
        let model = MusicViewModel()
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: model)
        let tracks = Array(model.catalog.tracks.prefix(3))
        model.discoverySnapshot = .init(
            items: tracks.map { .init(track: $0, reasons: [.init(kind: .collaborator)], score: 1) })
        let refills = Array(model.catalog.tracks.dropFirst(3).prefix(10))
        model.radioDiscoveryProvider = { _ in
            .init(
                items: refills.map {
                    .init(track: $0, reasons: [.init(kind: .collaborator)], score: 1)
                })
        }
        model.startDiscoveryRadio()
        await coordinator.settle()
        for _ in 0..<100 where model.isRefillingRadio { await Task.yield() }
        await coordinator.settle()
        #expect(model.isDiscoveryRadioActive)
        #expect(model.queue.manual.isEmpty)
        #expect(model.queue.source.count > 2)
        #expect(model.queue.source.allSatisfy { $0.origin == .source })
        #expect(Set(model.queue.items.map(\.track.id)).count == model.queue.items.count)
        model.play([tracks[0]])
        await coordinator.settle()
        #expect(!model.isDiscoveryRadioActive)
        #expect(model.queue.items.count == 1)
        await coordinator.close()
    }
    @Test func lateRadioResponseCannotMutateNewQueue() async throws {
        let model = MusicViewModel()
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: model)
        let track = try #require(model.catalog.tracks.first)
        var gate: CheckedContinuation<Void, Never>?
        model.discoverySnapshot = .init(items: [
            .init(track: track, reasons: [.init(kind: .collaborator)], score: 1)
        ])
        model.radioDiscoveryProvider = { _ in
            await withCheckedContinuation { gate = $0 }
            return .init(
                items: model.catalog.tracks.map {
                    .init(track: $0, reasons: [.init(kind: .collaborator)], score: 1)
                })
        }
        model.startDiscoveryRadio()
        await coordinator.settle()
        for _ in 0..<100 where gate == nil { await Task.yield() }
        #expect(gate != nil)
        model.play([track])
        await coordinator.settle()
        gate?.resume()
        for _ in 0..<20 { await Task.yield() }
        await coordinator.settle()
        #expect(model.queue.items.count == 1)
        #expect(!model.isDiscoveryRadioActive)
        await coordinator.close()
    }
}
