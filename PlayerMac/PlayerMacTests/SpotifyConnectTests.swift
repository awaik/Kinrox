import Foundation
import MusicCore
import SpotifyWebAPI
import Testing

@testable import Kinrox

// Shares the serialized HTTP fixture suite, so responses cannot cross tests.
extension SpotifyLibraryTests {
    @Test func connectPlayUsesPrivateContextAndWaitsBeyond204() async throws {
        let client = connectClient([
            .init(status: 204), .init(body: devices), .init(status: 201, body: helper),
            .init(body: #"{"snapshot_id":"v1"}"#), .init(status: 204), .init(status: 204),
            .init(status: 204),
            .init(body: playback(playing: false)), .init(body: playback(playing: true)),
        ])
        let defaults = try #require(UserDefaults(suiteName: "app.kinrox.tests.music.\(UUID())"))
        let engine = SpotifyConnectMusicEngine(
            client: client, clientID: "test", userID: "owner", defaults: defaults,
            localDeviceName: "Test Mac", confirmationDelays: [.milliseconds(1), .milliseconds(1)])
        var queue = MusicQueue()
        queue.start([connectTrack])
        try await engine.play(queue: queue, position: 0)
        engine.boundaryTask?.cancel()
        engine.boundaryTask = nil
        #expect(engine.lastState?.paused == false)
        #expect(engine.lastState?.occurrenceID == queue.current?.id)
        #expect(defaults.string(forKey: engine.preference) == "helper")
        let requests = MusicHTTPStub.state.requests
        let create = try #require(requests.first { $0.url?.path == "/v1/me/playlists" })
        let body =
            try JSONSerialization.jsonObject(with: #require(create.httpBody)) as? [String: Any]
        #expect(body?["public"] as? Bool == false)
        let play = try #require(requests.first { $0.url?.path == "/v1/me/player/play" })
        let playBody =
            try JSONSerialization.jsonObject(with: #require(play.httpBody)) as? [String: Any]
        #expect(playBody?["context_uri"] as? String == "spotify:playlist:helper")
        #expect(playBody?["uris"] == nil)
        #expect(requests.filter { $0.url?.path == "/v1/me/player" }.count == 3)
        await client.close()
        await engine.shutdown()
    }

    @Test func foreignStoredHelperIsLeftUntouchedAndReplacedPrivately() async throws {
        let foreign = helper.replacingOccurrences(
            of: #""id":"owner""#, with: #""id":"someoneElse""#)
        let client = connectClient([
            .init(status: 204), .init(body: devices), .init(body: foreign),
            .init(
                status: 201, body: helper.replacingOccurrences(of: "helper", with: "replacement")),
            .init(body: #"{"snapshot_id":"v1"}"#), .init(status: 204), .init(status: 204),
            .init(status: 204),
            .init(
                body: playback(playing: true).replacingOccurrences(
                    of: "helper", with: "replacement")),
        ])
        let defaults = try #require(UserDefaults(suiteName: "app.kinrox.tests.music.\(UUID())"))
        let engine = SpotifyConnectMusicEngine(
            client: client, clientID: "test", userID: "owner", defaults: defaults,
            localDeviceName: "Test Mac", confirmationDelays: [.milliseconds(1), .milliseconds(1)])
        engine.playlistID = "helper"
        var queue = MusicQueue()
        queue.start([connectTrack])
        try await engine.play(queue: queue, position: 0)
        engine.boundaryTask?.cancel()
        engine.boundaryTask = nil
        #expect(engine.playlistID == "replacement")
        #expect(
            !MusicHTTPStub.state.requests.contains { $0.url?.path == "/v1/playlists/helper/items" })
        #expect(
            MusicHTTPStub.state.requests.contains {
                $0.url?.path == "/v1/playlists/replacement/items"
            })
        await client.close()
        await engine.shutdown()
    }

    @Test func editingPausedQueueNeverStartsPlayback() async throws {
        let client = connectClient([
            .init(body: playback(playing: false)), .init(body: helper),
            .init(body: #"{"snapshot_id":"v2"}"#),
        ])
        let engine = SpotifyConnectMusicEngine(
            client: client, clientID: "test", userID: "owner",
            defaults: try #require(UserDefaults(suiteName: "app.kinrox.tests.music.\(UUID())")),
            localDeviceName: "Test Mac")
        var queue = MusicQueue()
        queue.start([connectTrack])
        engine.playlistID = "helper"
        engine.deviceID = "device"
        engine.mirrored = queue.items
        queue.add(connectTrack)
        try await engine.updateQueue(queue, position: 42, paused: true)
        engine.boundaryTask?.cancel()
        engine.boundaryTask = nil
        #expect(engine.mirrored.map(\.id) == queue.items.map(\.id))
        #expect(!MusicHTTPStub.state.requests.contains { $0.url?.path == "/v1/me/player/play" })
        await client.close()
        await engine.shutdown()
    }

    @Test(arguments: [204, 403])
    func repeatUpdateExcludesBoundaryObservationsUntilRequestCompletes(status: Int) async throws {
        let gate = MusicResponseGate()
        let client = connectClient([
            .init(status: status, gate: gate), .init(body: playback(playing: true)),
        ])
        let engine = SpotifyConnectMusicEngine(
            client: client, clientID: "test", userID: "owner",
            defaults: try #require(UserDefaults(suiteName: "app.kinrox.tests.music.\(UUID())")),
            localDeviceName: "Test Mac", confirmationDelays: [.milliseconds(1)],
            boundaryDelay: .milliseconds(2))
        var queue = MusicQueue()
        queue.start([connectTrack])
        engine.mirrored = queue.items
        engine.deviceID = "device"
        engine.playlistID = "helper"
        engine.publish(
            try JSONDecoder().decode(
                SpotifyPlayback.self, from: Data(playback(playing: true).utf8)),
            detectAdvance: false)
        queue.repeatMode = .one
        let update = Task { try await engine.updateQueue(queue, position: 42, paused: false) }
        for _ in 0..<200 where MusicHTTPStub.state.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(MusicHTTPStub.state.requests.count == 1)
        engine.scheduleBoundary()
        try await Task.sleep(for: .milliseconds(30))
        #expect(MusicHTTPStub.state.requests.map { $0.url?.path } == ["/v1/me/player/repeat"])
        await gate.release()
        if status == 204 {
            try await update.value
        } else {
            await #expect(throws: SpotifyError.forbidden) { try await update.value }
        }
        #expect(!engine.isCommandRunning)
        #expect(engine.repeatMode == (status == 204 ? .one : .off))
        engine.boundaryTask?.cancel()
        engine.boundaryTask = nil
        await client.close()
        await engine.shutdown()
    }

    @Test func freshSpotifyRestrictionsPreventSeekRequest() async throws {
        let state =
            playback(playing: true).dropLast() + #","actions":{"disallows":{"seeking":true}}}"#
        let client = connectClient([.init(body: String(state))])
        let engine = SpotifyConnectMusicEngine(
            client: client, clientID: "test", userID: "owner",
            defaults: try #require(UserDefaults(suiteName: "app.kinrox.tests.music.\(UUID())")),
            localDeviceName: "Test Mac")
        engine.deviceID = "device"
        engine.playlistID = "helper"
        do {
            try await engine.seek(absolute: 12)
            Issue.record("Restricted seek unexpectedly succeeded")
        } catch SpotifyPlaybackError.restricted {}
        #expect(MusicHTTPStub.state.requests.map { $0.url?.path } == ["/v1/me/player"])
        await client.close()
        await engine.shutdown()
    }

    @Test func unsupportedVolumeNeverReachesWriteEndpoint() async throws {
        let devices = devices.replacingOccurrences(
            of: "\"volume_percent\":0", with: "\"volume_percent\":0,\"supports_volume\":false")
        let client = connectClient([.init(body: devices)])
        let engine = SpotifyConnectMusicEngine(
            client: client, clientID: "test", userID: "owner",
            defaults: try #require(UserDefaults(suiteName: "app.kinrox.tests.music.\(UUID())")),
            localDeviceName: "Test Mac")
        do {
            try await engine.setVolume(20)
            Issue.record("Unsupported volume unexpectedly succeeded")
        } catch SpotifyPlaybackError.restricted {}
        #expect(MusicHTTPStub.state.requests.map { $0.url?.path } == ["/v1/me/player/devices"])
        await client.close()
        await engine.shutdown()
    }

    var connectTrack: MusicTrack {
        .init(
            id: "track1", uri: "spotify:track:track1", title: "Test", artists: [], albumID: "album",
            albumTitle: "Album", duration: 180)
    }
    var devices: String {
        #"{"devices":[{"id":"device","name":"Test Mac","type":"Computer","is_active":true,"is_restricted":false,"volume_percent":0}]}"#
    }
    var helper: String {
        #"{"id":"helper","uri":"spotify:playlist:helper","name":"Kinrox Queue","owner":{"id":"owner"},"public":false,"collaborative":false,"snapshot_id":"v1"}"#
    }
    func playback(playing: Bool) -> String {
        #"{"device":{"id":"device","name":"Test Mac","type":"Computer","is_active":true,"is_restricted":false,"volume_percent":0},"is_playing":\#(playing),"progress_ms":0,"shuffle_state":false,"repeat_state":"off","context":{"uri":"spotify:playlist:helper"},"item":{"id":"track1","uri":"spotify:track:track1","name":"Test","duration_ms":180000}}"#
    }
    func connectClient(_ replies: [MusicHTTPStub.Reply]) -> SpotifyClient {
        MusicHTTPStub.state.reset(replies)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MusicHTTPStub.self]
        return SpotifyClient(configuration: config) { _ in "synthetic" }
    }
}
