import Foundation
import MusicCore
import RemoteProtocol
import Testing

@testable import Kinrox

@MainActor
struct RemoteSimilarTests {
    private func snapshot(_ tracks: [MusicTrack]) -> MusicDiscoverySnapshot {
        .init(
            items: tracks.map { .init(track: $0, reasons: [.init(kind: .collaborator)], score: 1) })
    }

    private func playing(_ count: Int) async throws -> (
        MusicViewModel, PlaybackCoordinator, RemoteMusicBridge, [MusicTrack]
    ) {
        let music = MusicViewModel()
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: music)
        let tracks = music.catalog.tracks
        try #require(tracks.count >= count + 4)
        music.play(Array(tracks.prefix(count)))
        await coordinator.settle()
        return (
            music, coordinator, RemoteMusicBridge(music: music, coordinator: coordinator), tracks
        )
    }

    @Test(arguments: [false, true])
    func startKeepsCurrentAndManualTracksAndReplacesSource(workspaceActive: Bool) async throws {
        let (music, coordinator, bridge, tracks) = try await playing(3)
        music.setWorkspaceActive(workspaceActive)
        let current = try #require(music.queue.current)
        let manual = tracks[3]
        music.addToQueue(manual)
        await coordinator.settle()
        let candidates = Array(tracks.dropFirst(4))
        music.radioDiscoveryProvider = { _ in self.snapshot(candidates) }
        #expect(bridge.state.similar == .init(active: false, finding: false, available: true))

        #expect(bridge.execute(.setSimilar(active: true)) == nil)
        #expect(bridge.state.similar?.active == false)
        #expect(bridge.state.similar?.finding == true)
        await music.radioRefillTask?.value
        await coordinator.settle()

        #expect(music.queue.current?.id == current.id)
        #expect(music.queue.manual.map(\.track.id) == [manual.id])
        #expect(music.queue.source.map(\.track.id) == candidates.prefix(10).map(\.id))
        #expect(bridge.state.similar == .init(active: true, finding: false, available: true))

        #expect(bridge.execute(.setSimilar(active: false)) == nil)
        #expect(bridge.state.similar?.active == false)
        #expect(music.queue.source.map(\.track.id) == candidates.prefix(10).map(\.id))
        bridge.disconnect()
        await coordinator.close()
    }

    @Test func startWithoutResultsKeepsQueueAndExplainsWhy() async throws {
        let (music, coordinator, bridge, _) = try await playing(3)
        let source = music.queue.source.map(\.id)
        music.radioDiscoveryProvider = { _ in self.snapshot([]) }
        #expect(bridge.execute(.setSimilar(active: true)) == nil)
        await music.radioRefillTask?.value
        await coordinator.settle()
        #expect(music.queue.source.map(\.id) == source)
        #expect(bridge.state.similar == .init(active: false, finding: false, available: true))
        #expect(bridge.state.status == L10n.text("Nothing similar found yet"))
        bridge.disconnect()
        await coordinator.close()
    }

    @Test func notInterestedRemovesPendingTrackSkipsCurrentAndUndoes() async throws {
        let (music, coordinator, bridge, tracks) = try await playing(1)
        let candidates = Array(tracks.dropFirst().prefix(6))
        music.radioDiscoveryProvider = { _ in self.snapshot(candidates) }
        #expect(bridge.execute(.setSimilar(active: true)) == nil)
        await music.radioRefillTask?.value
        await coordinator.settle()

        let pending = try #require(music.queue.source.last?.track)
        #expect(
            bridge.execute(.setNotInterested(trackId: pending.id, scope: .track, excluded: true))
                == nil)
        await coordinator.settle()
        #expect(music.notInterestedTrackIDs.contains(pending.id))
        #expect(!music.queue.upcoming.contains { $0.track.id == pending.id })

        let current = try #require(music.currentTrack)
        let artist = try #require(current.artists.first)
        #expect(
            bridge.execute(.setNotInterested(trackId: current.id, scope: .artist, excluded: true))
                == nil)
        await coordinator.settle()
        await music.radioRefillTask?.value
        #expect(music.notInterestedArtistIDs.contains(artist.id))
        #expect(music.currentTrack?.id != current.id)

        #expect(
            bridge.execute(.setNotInterested(trackId: current.id, scope: .artist, excluded: false))
                == nil)
        #expect(
            bridge.execute(.setNotInterested(trackId: pending.id, scope: .track, excluded: false))
                == nil)
        #expect(!music.notInterestedArtistIDs.contains(artist.id))
        #expect(!music.notInterestedTrackIDs.contains(pending.id))
        #expect(
            bridge.execute(.setNotInterested(trackId: "missing", scope: .track, excluded: true))
                == .itemNotFound)
        music.stopSimilar()
        bridge.disconnect()
        await coordinator.close()
    }

    @Test func notInterestedOutsideSimilarOnlyHidesSuggestions() async throws {
        let (music, coordinator, bridge, _) = try await playing(3)
        let current = try #require(music.queue.current)
        let source = music.queue.source.map(\.id)
        #expect(
            bridge.execute(
                .setNotInterested(trackId: current.track.id, scope: .track, excluded: true)) == nil)
        await coordinator.settle()
        #expect(music.notInterestedTrackIDs.contains(current.track.id))
        #expect(music.queue.current?.id == current.id)
        #expect(music.queue.source.map(\.id) == source)
        bridge.disconnect()
        await coordinator.close()
    }
    @Test(arguments: [false, true])
    func repeatedHideStillSkipsAndUndoKeepsExistingExclusion(artistScope: Bool) async throws {
        let (music, coordinator, bridge, _) = try await playing(1)
        let current = try #require(music.currentTrack)
        let artist = try #require(current.artists.first)
        if artistScope {
            music.notInterestedArtistIDs.insert(artist.id)
        } else {
            music.notInterestedTrackIDs.insert(current.id)
        }
        music.isDiscoveryRadioActive = true
        music.radioDiscoveryProvider = { _ in self.snapshot([]) }
        #expect(
            bridge.execute(
                .setNotInterested(
                    trackId: current.id,
                    scope: artistScope ? .artist : .track, excluded: true)) == nil)
        await coordinator.settle()
        #expect(music.paused)  // No replacement: the hidden track must stop.
        #expect(music.notInterestedUndo.isEmpty)
        #expect(
            bridge.execute(
                .setNotInterested(
                    trackId: current.id,
                    scope: artistScope ? .artist : .track, excluded: false)) == nil)
        #expect(
            artistScope
                ? music.notInterestedArtistIDs.contains(artist.id)
                : music.notInterestedTrackIDs.contains(current.id))
        music.stopSimilar()
        bridge.disconnect()
        await coordinator.close()
    }

    @Test func hidingLastArtistStopsWithoutUpdatingHiddenPlayback() async throws {
        let (music, coordinator, bridge, _) = try await playing(1)
        let current = try #require(music.currentTrack)
        let engine = FakeMusicEngine()
        music.connect(engine: engine)
        music.queue.appendSource([current, current])
        music.isDiscoveryRadioActive = true
        music.radioDiscoveryProvider = { _ in self.snapshot([]) }
        #expect(
            bridge.execute(
                .setNotInterested(
                    trackId: current.id,
                    scope: .artist, excluded: true)) == nil)
        await coordinator.settle()
        await music.radioRefillTask?.value
        #expect(music.queue.source.isEmpty)
        #expect(engine.commands == [.stop])
        #expect(music.paused)
        music.stopSimilar()
        bridge.disconnect()
        await coordinator.close()
    }

}
