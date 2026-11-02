import Foundation
import MusicCore
import SpotifyWebAPI
import Testing

@testable import Kinrox

extension SpotifyLibraryTests {
    func warmEngine(_ client: SpotifyClient, queue: MusicQueue, boundaryDelay: Duration? = nil)
        throws -> SpotifyConnectMusicEngine
    {
        let engine = SpotifyConnectMusicEngine(
            client: client, clientID: "test", userID: "owner",
            defaults: try #require(UserDefaults(suiteName: "app.kinrox.tests.latency.\(UUID())")),
            localDeviceName: "Test Mac", confirmationDelays: [.milliseconds(1), .milliseconds(1)],
            boundaryDelay: boundaryDelay)
        engine.deviceID = "device"
        engine.playlistID = "helper"
        engine.mirrored = queue.history + queue.items
        engine.mirroredSnapshotID = "v1"
        engine.confirmedQueue = queue
        engine.cursor = queue.history.count
        return engine
    }
    @Test(arguments: [1, 50, 100, 500]) func warmResumeHasThreeCallsBeforeConfirmation(count: Int)
        async throws
    {
        let client = connectClient([
            .init(body: playback(playing: false)), .init(body: helper),
            .init(status: 204), .init(body: playback(playing: true)),
        ])
        var queue = MusicQueue()
        queue.start(Array(repeating: connectTrack, count: count))
        let engine = try warmEngine(client, queue: queue)
        try await engine.setPaused(false)
        #expect(
            MusicHTTPStub.state.requests.map { ($0.httpMethod ?? "") + " " + ($0.url?.path ?? "") }
                == [
                    "GET /v1/me/player", "GET /v1/playlists/helper", "PUT /v1/me/player/play",
                    "GET /v1/me/player",
                ])
        #expect(MusicHTTPStub.state.requests[2].httpBody == nil)
        engine.boundaryTask?.cancel()
        await client.close()
        await engine.shutdown()
    }
    @Test func warmNextAndPreviousUseOffsetsWithNoPlaylistWrites() async throws {
        let client = connectClient([
            .init(body: playback(playing: true)), .init(body: helper), .init(status: 204),
            .init(body: playback(playing: true)),
            .init(body: playback(playing: true)), .init(body: helper), .init(status: 204),
            .init(body: playback(playing: true)),
        ])
        var queue = MusicQueue()
        queue.start([connectTrack, connectTrack])
        let engine = try warmEngine(client, queue: queue)
        _ = queue.next()
        try await engine.play(queue: queue, position: 0)
        #expect(engine.cursor == 1)
        _ = queue.previous()
        try await engine.play(queue: queue, position: 0)
        #expect(engine.cursor == 0)
        let writes = MusicHTTPStub.state.requests.filter { $0.httpMethod != "GET" }
        #expect(writes.count == 2 && writes.allSatisfy { $0.url?.path == "/v1/me/player/play" })
        let offsets = try writes.map { request in
            let object =
                try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
            return (object?["offset"] as? [String: Int])?["position"]
        }
        #expect(offsets == [1, 0])
        engine.boundaryTask?.cancel()
        await client.close()
        await engine.shutdown()
    }
    @Test func insertManualItemBeforeSourceWithoutPausingOrRestarting() async throws {
        let client = connectClient([.init(body: helper), .init(body: #"{"snapshot_id":"v2"}"#)])
        var queue = MusicQueue()
        queue.start([connectTrack, connectTrack, connectTrack])
        _ = queue.next()
        let engine = try warmEngine(client, queue: queue)
        queue.add(connectTrack)
        try await engine.updateQueue(queue, position: 42, paused: false)
        #expect(MusicHTTPStub.state.requests.count == 2)
        let write = try #require(MusicHTTPStub.state.requests.last)
        #expect(write.httpMethod == "POST" && write.url?.path == "/v1/playlists/helper/items")
        let body =
            try JSONSerialization.jsonObject(with: #require(write.httpBody)) as? [String: Any]
        #expect(body?["position"] as? Int == queue.history.count + queue.manual.count)
        #expect(engine.mirrored.map(\.id) == (queue.history + queue.items).map(\.id))
        #expect(engine.mirroredSnapshotID == "v2")
        await client.close()
        await engine.shutdown()
    }
    @Test func previousAcrossPendingManualItemsRebuildsEvenWithoutWrap() async throws {
        let client = connectClient([
            .init(body: playback(playing: false)), .init(body: helper),
            .init(body: #"{"snapshot_id":"v2"}"#),
            .init(status: 204), .init(body: playback(playing: true)),
        ])
        var queue = MusicQueue()
        queue.start([connectTrack, connectTrack, connectTrack])
        _ = queue.next()
        queue.add(connectTrack)
        let engine = try warmEngine(client, queue: queue)
        _ = queue.previous()
        #expect(engine.mirrored.map(\.id) != (queue.history + queue.items).map(\.id))
        try await engine.play(queue: queue, position: 0)
        #expect(
            MusicHTTPStub.state.requests.contains {
                $0.httpMethod == "PUT" && $0.url?.path == "/v1/playlists/helper/items"
            })
        engine.boundaryTask?.cancel()
        await client.close()
        await engine.shutdown()
    }
    @Test(arguments: ["snapshot", "public", "owner", "collaborative"])
    func invalidHelperCannotAuthorizeWarmOffsetJump(reason: String) async throws {
        var invalid = helper
        switch reason {
        case "snapshot": invalid = invalid.replacingOccurrences(of: "v1", with: "changed")
        case "public":
            invalid = invalid.replacingOccurrences(of: #""public":false"#, with: #""public":true"#)
        case "owner":
            invalid = invalid.replacingOccurrences(of: #""id":"owner""#, with: #""id":"other""#)
        default:
            invalid = invalid.replacingOccurrences(
                of: #""collaborative":false"#, with: #""collaborative":true"#)
        }
        let client = connectClient([
            .init(body: playback(playing: false)), .init(body: invalid), .init(body: helper),
            .init(body: #"{"snapshot_id":"v2"}"#), .init(status: 204),
            .init(body: playback(playing: true)),
        ])
        var queue = MusicQueue()
        queue.start([connectTrack, connectTrack])
        let engine = try warmEngine(client, queue: queue)
        _ = queue.next()
        try await engine.play(queue: queue, position: 0)
        let requests = MusicHTTPStub.state.requests
        let writeIndex = try #require(
            requests.firstIndex { $0.url?.path == "/v1/playlists/helper/items" })
        let playIndex = try #require(requests.firstIndex { $0.url?.path == "/v1/me/player/play" })
        #expect(writeIndex < playIndex)
        #expect(requests[2].httpMethod == (reason == "snapshot" ? "GET" : "POST"))
        engine.boundaryTask?.cancel()
        await client.close()
        await engine.shutdown()
    }
    @Test func playingHasNoPeriodicRequestsAndPausedHasNoBoundaryTask() async throws {
        let client = connectClient([])
        var queue = MusicQueue()
        queue.start([connectTrack])
        let engine = try warmEngine(client, queue: queue)
        engine.publish(
            try JSONDecoder().decode(
                SpotifyPlayback.self, from: Data(playback(playing: true).utf8)),
            detectAdvance: false)
        engine.scheduleBoundary()
        try await Task.sleep(for: .milliseconds(60))
        #expect(MusicHTTPStub.state.requests.isEmpty)
        engine.publish(
            try JSONDecoder().decode(
                SpotifyPlayback.self, from: Data(playback(playing: false).utf8)),
            detectAdvance: false)
        engine.scheduleBoundary()
        #expect(engine.boundaryTask == nil)
        #expect(MusicHTTPStub.state.requests.isEmpty)
        await client.close()
        await engine.shutdown()
    }
    @Test(arguments: [200, 503]) func completedPlayDiscardsEarlierPollResults(status: Int)
        async throws
    {
        let gate = MusicResponseGate()
        let client = connectClient([
            .init(
                status: status,
                body: playback(playing: false).replacingOccurrences(of: "helper", with: "other"),
                gate: gate),
            .init(body: playback(playing: false)), .init(body: helper), .init(status: 204),
            .init(body: playback(playing: true)),
        ])
        var queue = MusicQueue()
        queue.start([connectTrack])
        let engine = try warmEngine(client, queue: queue)
        let old = Task { await engine.reconcile(generation: engine.commandGeneration) }
        try await waitFor { MusicHTTPStub.state.requests.count == 1 }
        try await engine.play(queue: queue, position: 0)
        await gate.release()
        await old.value
        #expect(engine.lastState?.paused == false)
        #expect(engine.boundaryTask != nil)
        #expect(MusicHTTPStub.state.requests.count == 5)
        engine.boundaryTask?.cancel()
        await client.close()
        await engine.shutdown()
    }
    @Test func boundaryObservationAdvancesOccurrenceOnceAndRearms() async throws {
        let next = playback(playing: true).replacingOccurrences(of: "track1", with: "track2")
        let client = connectClient([.init(body: next)])
        let track2 = MusicTrack(
            id: "track2", uri: "spotify:track:track2", title: "Two", artists: [], albumID: "album",
            albumTitle: "Album", duration: 180)
        var queue = MusicQueue()
        queue.start([connectTrack, track2])
        let engine = try warmEngine(client, queue: queue)
        await engine.reconcile(generation: engine.commandGeneration)
        #expect(engine.lastState?.occurrenceID == queue.items[1].id)
        #expect(engine.boundaryTask != nil)
        #expect(MusicHTTPStub.state.requests.count == 1)
        engine.boundaryTask?.cancel()
        await client.close()
        await engine.shutdown()
    }
    @Test func nearEndSeekAcceptsNaturalAdvance() async throws {
        let next = playback(playing: true).replacingOccurrences(of: "track1", with: "track2")
        let client = connectClient([
            .init(body: playback(playing: true)), .init(status: 204), .init(body: next),
        ])
        let track2 = MusicTrack(
            id: "track2", uri: "spotify:track:track2", title: "Two", artists: [], albumID: "album",
            albumTitle: "Album", duration: 180)
        var queue = MusicQueue()
        queue.start([connectTrack, track2])
        let engine = try warmEngine(client, queue: queue)
        try await engine.seek(absolute: 180)
        #expect(engine.lastState?.occurrenceID == queue.items[1].id)
        let seek = MusicHTTPStub.state.requests[1]
        #expect(
            URLComponents(url: seek.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains {
                $0.name == "position_ms" && $0.value == "179000"
            } == true)
        engine.boundaryTask?.cancel()
        await client.close()
        await engine.shutdown()
    }
}

extension SpotifyLibraryTests {
    @Test func fastConfirmationCatchesSecondObservationAround230Milliseconds() async throws {
        let client = connectClient([
            .init(body: playback(playing: false)), .init(body: playback(playing: true)),
        ])
        let engine = SpotifyConnectMusicEngine(
            client: client, clientID: "test", userID: "owner",
            defaults: try #require(UserDefaults(suiteName: "app.kinrox.tests.confirm.\(UUID())")))
        let start = ContinuousClock.now
        let result = try await engine.confirm { $0.isPlaying }
        let duration = start.duration(to: .now).components
        let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        print("METRIC confirmation-second-observation-ms=\(milliseconds)")
        #expect(result.isPlaying && milliseconds >= 220 && milliseconds < 1000)
        #expect(MusicHTTPStub.state.requests.count == 2)
        await client.close()
        await engine.shutdown()
    }
}

extension SpotifyLibraryTests {
    @Test func finalBoundaryEmitsEndAndLeavesNoBackgroundTimer() async throws {
        let ended = playback(playing: false).replacingOccurrences(
            of: "\"progress_ms\":0", with: "\"progress_ms\":179000")
        let client = connectClient([.init(body: ended)])
        var queue = MusicQueue()
        queue.start([connectTrack])
        let engine = try warmEngine(client, queue: queue)
        await engine.reconcile(generation: engine.commandGeneration)
        #expect(engine.endReported)
        #expect(engine.lastState?.paused == true)
        #expect(engine.boundaryTask == nil)
        #expect(MusicHTTPStub.state.requests.count == 1)
        await client.close()
        await engine.shutdown()
    }
}
