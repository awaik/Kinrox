import Foundation
import MusicCore
import RemoteProtocol
import Testing

@testable import Kinrox

extension DiscoveryServiceTests {
    @Test(arguments: [100, 1_100])
    func remoteFeedbackDefersDiscoveryUntilWorkspaceReturns(trackCount: Int) async throws {
        DiscoveryHTTPStub.state.reset([])
        let store = makeStore()
        let tracks = SpotifyPerformanceTests.fixture(trackCount: trackCount).catalog.tracks
        store.catalog = MusicCatalog(tracks: tracks)
        let seed = tracks[0]
        let candidate = tracks[1]
        var data = SpotifyDiscoveryData()
        data.tracks = [candidate]
        data.signals = [.init(track: candidate, kind: .listenBrainzRecording)]
        let key = store.discoverySeedKey(track: seed, artist: seed.artists.first)
        store.discoveryCache["seed-v2|\(key)|0"] = (Date(), data)
        let music = MusicViewModel(store: store)
        music.discoverySeedTrack = seed
        music.discoverySeedArtist = seed.artists.first
        music.select(.similar)
        await music.browsingTask?.value
        #expect(music.discoverySnapshot?.items.map(\.id) == [candidate.id])
        let coordinator = PlaybackCoordinator()
        coordinator.connect(video: nil, music: music)
        let bridge = RemoteMusicBridge(music: music, coordinator: coordinator, isActive: { true })
        music.setWorkspaceActive(false)
        #expect(store.discoveryCache["seed-v2|\(key)|0"] != nil)
        let requestID = music.discoveryRequestID
        for excluded in [true, false] {
            #expect(
                bridge.execute(
                    .setNotInterested(
                        trackId: candidate.id, scope: .track, excluded: excluded)) == nil)
            #expect(music.notInterestedTrackIDs.contains(candidate.id) == excluded)
            #expect(music.discoveryRequestID == requestID)
            #expect(music.discoverySnapshot == nil)
            #expect(music.discoveryNeedsRefresh)
            #expect(!music.isDiscovering)
            #expect(music.browsingTask == nil)
        }
        // Explicit UI refresh paths obey the same inactive-workspace boundary.
        music.refreshDiscovery()
        #expect(music.discoverySnapshot == nil)
        music.setWorkspaceActive(true)
        await music.browsingTask?.value
        #expect(music.discoveryRequestID != requestID)
        #expect(!music.discoveryNeedsRefresh)
        #expect(music.discoverySnapshot?.items.map(\.id) == [candidate.id])
        #expect(DiscoveryHTTPStub.state.requests.isEmpty)
        music.setWorkspaceActive(false)
        bridge.disconnect()
        await coordinator.close()
        store.retire()
        await store.client.close()
    }

    @Test func videoStartupCoalescesRestoreAndRefreshUntilWorkspaceActivation() async throws {
        DiscoveryHTTPStub.state.reset(routes: [
            "GET /v1/me/albums": [.init(body: "{\"items\":[]}")],
            "GET /v1/me/playlists": [.init(body: "{\"items\":[]}")],
            "GET /v1/me/tracks": [.init(body: "{\"items\":[]}")],
            "GET /v1/me/following": [.init(body: "{\"artists\":{\"items\":[]}}")],
        ])
        let defaults = try preferences()
        defaults.set(false, forKey: ListenBrainzPreference.key)
        defaults.set(
            try JSONEncoder().encode(BrowserSelection(source: .similar)),
            forKey: MusicViewModel.selectionPreference)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "startup-\(UUID())")
        let cache = SpotifyCacheStore(
            clientID: "test", userID: "owner", displayName: "Test", root: root)
        let store = makeStore(cache: cache)
        store.isConnected = false
        let fixture = SpotifyPerformanceTests.fixture(trackCount: 100)
        try await cache.save(fixture, revision: 1, session: store.sessionGeneration)
        let history = MusicPlayHistoryEntry(
            sessionID: UUID(), trackID: "t10", previousTrackID: "t0",
            playedAt: Date(), playedSeconds: 200, completed: true, skipped: false)
        try await cache.recordPlay(history, session: store.sessionGeneration)
        let session = PlayerSession(
            recents: RecentFilesStore(fileURL: root.appendingPathComponent("recents.json")),
            musicDefaults: defaults)
        let video = PlayerViewModel(engine: FakePlayerEngine())
        session.model = video
        session.music.replaceStore(store)
        let beforeRestore = session.music.discoveryRequestID
        await store.restore()
        #expect(session.music.discoveryRequestID == beforeRestore)
        #expect(session.music.discoverySnapshot == nil)
        #expect(store.playHistory == [history])
        store.isConnected = true
        session.music.syncLibrary()
        await session.music.syncTask?.value
        #expect(session.music.statusMessage == nil)
        #expect(session.music.discoveryRequestID == beforeRestore)
        #expect(session.music.discoverySnapshot == nil)
        session.mode = .music
        let activated = session.music.discoveryRequestID
        #expect(activated != beforeRestore)
        #expect(session.music.discoverySnapshot != nil)
        await session.music.browsingTask?.value
        #expect(session.music.discoveryRequestID == activated)
        #expect(store.playHistory == [history])
        store.retire()
        await store.client.close()
        await video.shutdown()
    }

    @Test func discoveryCacheEvictsToDiskAndIdleTrimKeepsOnlyActiveSeed() async throws {
        DiscoveryHTTPStub.state.reset([])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "discovery-bound-\(UUID())")
        let cache = SpotifyCacheStore(clientID: "c", userID: "u", displayName: "Test", root: root)
        let store = makeStore(cache: cache)
        for index in 0..<20 {
            let track = MusicTrack(
                id: "seed\(index)", uri: "seed", title: "Seed \(index)",
                artists: [artist], albumID: "a", albumTitle: "A", duration: 200, isrc: "X")
            _ = try await store.discover(
                seedTitle: track.title, seedTrack: track, seedArtist: artist,
                mode: .sameSpirit, selectedGenre: nil, hideLiked: false)
            #expect(store.discoveryCache.count <= 12)
        }
        let first = "seed-v2|track:seed0|artist:artist|0"
        #expect(store.discoveryCache[first] == nil)
        #expect(try await cache.discovery(first) != nil)
        let count = DiscoveryHTTPStub.state.requests.count
        let track = MusicTrack(
            id: "seed0", uri: "seed", title: "Seed 0", artists: [artist],
            albumID: "a", albumTitle: "A", duration: 200, isrc: "X")
        _ = try await store.discover(
            seedTitle: track.title, seedTrack: track, seedArtist: artist,
            mode: .sameSpirit, selectedGenre: nil, hideLiked: false)
        #expect(DiscoveryHTTPStub.state.requests.count == count)
        store.searchCache["query"] = (Date(), store.catalog)
        store.trimDiscoveryMemory(keeping: first)
        #expect(store.searchCache.isEmpty)
        #expect(Set(store.discoveryCache.keys) == [first])
        store.retire()
        await store.client.close()
    }

    @Test func videoModeDefersRestoredDiscoveryAndPreservesPlayback() async throws {
        DiscoveryHTTPStub.state.reset([])
        let defaults = try preferences()
        defaults.set(false, forKey: ListenBrainzPreference.key)
        defaults.set(
            try JSONEncoder().encode(BrowserSelection(source: .similar)),
            forKey: MusicViewModel.selectionPreference)
        let session = PlayerSession(
            recents: RecentFilesStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "recents-\(UUID()).json")), musicDefaults: defaults)
        let video = PlayerViewModel(engine: FakePlayerEngine())
        session.model = video
        let store = makeStore()
        store.isConnected = false
        session.music.replaceStore(store)
        #expect(session.mode == .video)
        #expect(session.music.discoverySnapshot == nil)
        session.music.acceptLibrary(store)
        #expect(session.music.discoverySnapshot == nil)
        session.mode = .music
        #expect(session.music.discoverySnapshot != nil)
        session.music.queue.start([seed])
        session.music.paused = false
        let queue = session.music.queue
        session.mode = .video
        #expect(session.music.discoverySnapshot == nil)
        #expect(session.music.queue == queue)
        #expect(!session.music.paused)
        session.mode = .music
        #expect(session.music.discoverySnapshot != nil)
        session.music.select(.liked)
        #expect(session.music.discoverySnapshot == nil)
        #expect(DiscoveryHTTPStub.state.requests.isEmpty)
        store.retire()
        await store.client.close()
        await video.shutdown()
    }

    @Test func restorePublishesCompleteHistoryBeforeDiscovery() async throws {
        let date = Date()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "discovery-restore-\(UUID())")
        let cache = SpotifyCacheStore(clientID: "c", userID: "u", displayName: "Test", root: root)
        let store = makeStore(cache: cache)
        store.isConnected = false
        let row = MusicPlayHistoryEntry(
            sessionID: UUID(), trackID: seed.id, playedAt: date,
            playedSeconds: 200, completed: true, skipped: false)
        try await cache.save(
            .init(
                library: LibrarySnapshot(userID: "u", likedTrackIDs: [seed.id]),
                catalog: store.catalog,
                resources: [
                    "liked": .init(fetchedAt: date, expiresAt: date.addingTimeInterval(300))
                ]),
            revision: 1, session: store.sessionGeneration)
        try await cache.recordPlay(row, session: store.sessionGeneration)
        var completedPublications = 0
        store.onChange = {
            if !store.isRestoring {
                completedPublications += 1
                #expect(store.playHistory == [row])
                #expect(store.catalog.track(id: self.seed.id) != nil)
            }
        }
        await store.restore()
        #expect(completedPublications == 1)
        store.retire()
        await store.client.close()
    }
}

@MainActor
struct DiscoveryComputationTests {
    @Test func closingWindowTrimsDiscoveryAndKeepsMusicAndRemoteState() async throws {
        let session = PlayerSession(
            recents: RecentFilesStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "window-recents-\(UUID())")),
            demoMusic: true)
        let controller = try PlayerWindowController(session: session) { _ in session.model = nil }
        session.model = controller.model
        session.mode = .music
        session.music.select(.similar)
        session.music.paused = false
        let bridge = RemoteMusicBridge(music: session.music, coordinator: session.playback)
        let state = bridge.state
        let queue = session.music.queue
        let history = session.music.playHistory
        controller.windowWillClose(Notification(name: .init("test")))
        #expect(session.music.discoverySnapshot == nil)
        #expect(session.music.queue == queue)
        #expect(session.music.playHistory == history)
        #expect(!session.music.paused)
        #expect(bridge.state.track == state.track)
        #expect(bridge.state.similar == state.similar)
        #expect(bridge.state.queueRevision == state.queueRevision)
        #expect(!bridge.snapshot(fullscreen: false, screensaver: .off).paused)
        session.mode = .video
        session.mode = .music
        #expect(!session.music.isWorkspaceActive)
        #expect(session.music.discoverySnapshot == nil)
        #expect(session.music.discoveryNeedsRefresh)
        bridge.disconnect()
        await controller.model.shutdown()
    }

    @Test func workerLeavesMainThreadAndPropagatesCancellation() async throws {
        let offMain = try await MusicDiscoveryComputation.run { !Thread.isMainThread }
        #expect(offMain)
        let task = Task {
            try await MusicDiscoveryComputation.run {
                while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
                return 1
            }
        }
        await Task.yield()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
