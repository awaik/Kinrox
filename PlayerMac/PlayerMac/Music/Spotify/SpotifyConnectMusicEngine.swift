import Foundation
import MusicCore
import SpotifyWebAPI

/// Audio stays in the official Spotify client. The private context is owned by
/// this engine; user playlists and Spotify's uneditable native queue are untouched.
@MainActor
final class SpotifyConnectMusicEngine: MusicEngine {
    let events: AsyncStream<MusicEngineEvent>
    let continuation: AsyncStream<MusicEngineEvent>.Continuation
    let client: SpotifyClient
    let defaults: UserDefaults
    let preference: String
    let userID: String
    let localDeviceName: String
    let pollInterval: Duration
    var playlistID: String?
    var deviceID: String?
    var mirrored: [MusicQueueItem] = []
    var cursor = 0
    var lastState: MusicPlaybackSnapshot?
    var repeatMode = MusicRepeat.off
    var polling: Task<Void, Never>?
    var isCommandRunning = false
    var isClosed = false
    var endReported = false
    var onPlaylistCreated: ((String) -> Void)?

    init(
        client: SpotifyClient, clientID: String, userID: String,
        defaults: UserDefaults = .standard,
        localDeviceName: String = Host.current().localizedName ?? "",
        pollInterval: Duration = .seconds(2)
    ) {
        self.client = client
        self.userID = userID
        self.defaults = defaults
        self.localDeviceName = localDeviceName
        self.pollInterval = pollInterval
        preference = SpotifyAccount.queuePreferencePrefix + "\(clientID).\(userID)"
        playlistID = defaults.string(forKey: preference)
        (events, continuation) = AsyncStream.makeStream()
    }

    func play(queue: MusicQueue, position: Double) async throws {
        guard !isClosed, queue.current != nil else { return }
        guard queue.current?.track.isPlayable != false else {
            throw SpotifyPlaybackError.restricted
        }
        try requireAllowed("interrupting_playback")
        isCommandRunning = true
        var requestedPlay = false
        defer { isCommandRunning = false }
        do {
            let device = try await selectDevice()
            // Pause before replacing a context that Spotify may currently be reading.
            if let state = try await client.playback(), state.device.id == device {
                try requireAllowed("interrupting_playback", state: state)
                try requireAllowed("toggling_shuffle", state: state)
                try requireAllowed(
                    queue.repeatMode == .one ? "toggling_repeat_track" : "toggling_repeat_context",
                    state: state)
                if state.isPlaying {
                    try requireAllowed("pausing", state: state)
                    try await client.pause(true, deviceID: device)
                    _ = try await confirm { $0.device.id == device && !$0.isPlaying }
                }
            }
            let playlist = try await ensurePlaylist()
            try await mirror(queue, playlistID: playlist)
            try await client.shuffle(false, deviceID: device)
            try await client.repeatMode(
                queue.repeatMode == .one ? "track" : "off", deviceID: device)
            requestedPlay = true
            try await client.play(
                contextURI: "spotify:playlist:" + playlist, offset: 0,
                position: position, deviceID: device)
            let current = queue.current!.track.uri
            let state = try await confirm { state in
                state.device.id == device && state.context?.uri == "spotify:playlist:" + playlist
                    && state.isPlaying && Self.matches(state.item, uri: current)
            }
            publish(state, detectAdvance: false)
            beginPolling()
        } catch {
            // A failed confirmation can follow an accepted play request. Settle it
            // with a pause before permitting another engine to start.
            if requestedPlay, let deviceID { try? await client.pause(true, deviceID: deviceID) }
            throw error
        }
    }

    func setPaused(_ paused: Bool) async throws {
        guard !isClosed, let deviceID, !mirrored.isEmpty else { return }
        isCommandRunning = true
        defer { isCommandRunning = false }
        guard let state = try await client.playback() else {
            if paused { return }
            throw SpotifyError.noDevice
        }
        // Never resume an unrelated context or take over another device.
        guard state.device.id == deviceID else { throw SpotifyPlaybackError.otherDevice }
        if !paused { try validateContext(state) }
        if state.isPlaying == paused {
            try requireAllowed(paused ? "pausing" : "resuming", state: state)
            try await client.pause(paused, deviceID: deviceID)
        }
        let confirmed = try await confirm { $0.device.id == deviceID && $0.isPlaying != paused }
        publish(confirmed, detectAdvance: false)
        beginPolling()
    }

    func seek(absolute position: Double) async throws {
        guard position.isFinite, let deviceID, !isClosed else { return }
        isCommandRunning = true
        defer { isCommandRunning = false }
        guard let state = try await client.playback() else { throw SpotifyError.noDevice }
        try validateContext(state)
        try requireAllowed("seeking", state: state)
        let target = min(max(0, position), max(0, (state.item?.durationMS ?? 0) / 1000 - 0.2))
        try await client.seek(target, deviceID: deviceID)
        let confirmed = try await confirm { abs(($0.progressMS ?? 0) / 1000 - target) < 3 }
        publish(confirmed, detectAdvance: false)
    }

    func setVolume(_ volume: Double) async throws {
        guard volume.isFinite, !isClosed else { return }
        isCommandRunning = true
        defer { isCommandRunning = false }
        let device = try await selectDevice(requiresVolume: true)
        try requireAllowed("volume")
        let target = Double(Int(min(100, max(0, volume))))
        try await client.volume(target, deviceID: device)
        let state = try await confirm {
            $0.device.id == device && $0.device.volumePercent == target
        }
        publish(state, detectAdvance: false)
    }

    func updateQueue(_ queue: MusicQueue, position: Double, paused: Bool) async throws {
        guard !isClosed, !mirrored.isEmpty, queue.current != nil else { return }
        if mirrored == queue.items {
            guard queue.repeatMode != repeatMode, let deviceID else { return }
            isCommandRunning = true
            defer { isCommandRunning = false }
            try requireAllowed(
                queue.repeatMode == .one || repeatMode == .one
                    ? "toggling_repeat_track" : "toggling_repeat_context")
            try await client.repeatMode(
                queue.repeatMode == .one ? "track" : "off", deviceID: deviceID)
            repeatMode = queue.repeatMode
            return
        }
        if paused {
            try await setPaused(true)
            guard let playlistID else { return }
            isCommandRunning = true
            defer { isCommandRunning = false }
            try await mirror(queue, playlistID: playlistID)
            return
        }
        // Restart the context at the confirmed current position. Spotify cannot
        // otherwise remove/reorder pending queue occurrences through its API.
        try await play(queue: queue, position: position)
    }

    func stop() async throws {
        try await setPaused(true)
        if !mirrored.isEmpty { try await seek(absolute: 0) }
    }

    func shutdown() async {
        polling?.cancel()
        polling = nil
        try? await setPaused(true)
        isClosed = true
        continuation.finish()
    }

    private func selectDevice(requiresVolume: Bool = false) async throws -> String {
        let devices = try await client.devices()
        // A remembered id may be reused only while it still identifies this Mac.
        guard
            let device = devices.first(where: {
                $0.type == "Computer" && !$0.isRestricted && $0.name == localDeviceName
                    && $0.id != nil
            }), let id = device.id
        else { throw SpotifyError.noDevice }
        if requiresVolume, device.supportsVolume == false { throw SpotifyPlaybackError.restricted }
        deviceID = id
        return id
    }

    private func ensurePlaylist() async throws -> String {
        if let playlistID {
            do {
                let playlist = try await client.playlist(playlistID)
                guard playlist.owner.id == userID, playlist.public != true,
                    playlist.collaborative != true
                else { throw SpotifyPlaybackError.invalidQueue }
                onPlaylistCreated?(playlistID)
                return playlistID
            } catch SpotifyError.http(let code) where code == 404 {
                self.playlistID = nil
                defaults.removeObject(forKey: preference)
            } catch SpotifyPlaybackError.invalidQueue {
                // The user changed the helper's visibility/ownership. Leave that
                // playlist intact and create a new private helper for this account.
                self.playlistID = nil
                defaults.removeObject(forKey: preference)
            }
        }
        let playlist = try await client.createPlaylist(
            name: "Kinrox Queue",
            description:
                "Playback queue managed by Kinrox. Its contents change when the queue changes.")
        guard playlist.owner.id == userID else { throw SpotifyPlaybackError.invalidQueue }
        playlistID = playlist.id
        defaults.set(playlist.id, forKey: preference)
        onPlaylistCreated?(playlist.id)
        return playlist.id
    }

    private func mirror(_ queue: MusicQueue, playlistID: String) async throws {
        let items = queue.items
        guard items.count <= 10_000 else { throw SpotifyPlaybackError.queueTooLarge }
        let uris = items.map(\.track.uri)
        _ = try await client.replaceItems(playlistID: playlistID, uris: Array(uris.prefix(100)))
        for offset in stride(from: 100, to: uris.count, by: 100) {
            _ = try await client.insertItems(
                playlistID: playlistID,
                uris: Array(uris[offset..<min(offset + 100, uris.count)]), position: offset)
        }
        mirrored = items
        cursor = 0
        repeatMode = queue.repeatMode
        endReported = false
    }
}

enum SpotifyPlaybackError: Error {
    case otherDevice, invalidQueue, queueTooLarge, unconfirmed, restricted
}
