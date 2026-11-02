import Foundation
import MusicCore
import SpotifyWebAPI

extension SpotifyConnectMusicEngine {
    func selectDevice(observed: SpotifyDevice? = nil, requiresVolume: Bool = false) async throws
        -> String
    {
        func local(_ device: SpotifyDevice) -> Bool {
            device.type == "Computer" && !device.isRestricted && device.name == localDeviceName
                && device.id != nil
        }
        let device: SpotifyDevice
        if let observed, local(observed) {
            device = observed
        } else {
            guard let found = try await client.devices().first(where: local) else {
                throw SpotifyError.noDevice
            }
            device = found
        }
        if requiresVolume, device.supportsVolume == false { throw SpotifyPlaybackError.restricted }
        deviceID = device.id
        return device.id!
    }
    func configurePlayback(_ queue: MusicQueue, state: SpotifyPlayback?, device: String)
        async throws
    {
        if state?.shuffleState != false {
            try requireAllowed("toggling_shuffle", state: state)
            try await client.shuffle(false, deviceID: device)
        }
        let repeatState = queue.repeatMode == .one ? "track" : "off"
        if state?.repeatState != repeatState {
            try requireAllowed(
                queue.repeatMode == .one ? "toggling_repeat_track" : "toggling_repeat_context",
                state: state)
            try await client.repeatMode(repeatState, deviceID: device)
        }
    }
    func suitable(_ playlist: SpotifyPlaylist) -> Bool {
        playlist.owner.id == userID && playlist.public != true && playlist.collaborative != true
    }
    func validateHelper() async throws -> Bool {
        guard let playlistID, let version = mirroredSnapshotID, !version.isEmpty else {
            return false
        }
        do {
            let playlist = try await client.playlist(playlistID, live: true, priority: .control)
            guard suitable(playlist) else {
                forgetHelper()
                return false
            }
            guard playlist.snapshotID == version else {
                mirroredSnapshotID = nil
                return false
            }
            return true
        } catch SpotifyError.http(let code) where code == 404 {
            forgetHelper()
            return false
        }
    }
    func forgetHelper() {
        playlistID = nil
        mirroredSnapshotID = nil
        defaults.removeObject(forKey: preference)
    }
    func ensurePlaylist() async throws -> String {
        if let playlistID {
            do {
                let playlist = try await client.playlist(playlistID, live: true, priority: .control)
                if suitable(playlist) {
                    onPlaylistCreated?(playlistID)
                    return playlistID
                }
                forgetHelper()
            } catch SpotifyError.http(let code) where code == 404 { forgetHelper() }
        }
        let playlist = try await client.createPlaylist(
            name: "Kinrox Queue",
            description:
                "Playback queue managed by Kinrox. Its contents change when the queue changes.")
        guard suitable(playlist) else { throw SpotifyPlaybackError.invalidQueue }
        playlistID = playlist.id
        defaults.set(playlist.id, forKey: preference)
        onPlaylistCreated?(playlist.id)
        return playlist.id
    }
    func mirror(_ queue: MusicQueue, playlistID: String) async throws {
        let items = queue.history + queue.items
        guard items.count <= 10_000 else { throw SpotifyPlaybackError.queueTooLarge }
        mirroredSnapshotID = nil
        let uris = items.map(\.track.uri)
        var version = try await client.replaceItems(
            playlistID: playlistID, uris: Array(uris.prefix(100)))
        for offset in stride(from: 100, to: uris.count, by: 100) {
            version = try await client.insertItems(
                playlistID: playlistID,
                uris: Array(uris[offset..<min(offset + 100, uris.count)]), position: offset)
        }
        mirrored = items
        mirroredSnapshotID = version.isEmpty ? nil : version
        cursor = queue.history.count
        repeatMode = queue.repeatMode
        endReported = false
    }
    func updateQueue(_ queue: MusicQueue, position: Double, paused: Bool) async throws {
        try await SpotifyRequestContext.$priority.withValue(.control) {
            try await editQueue(queue, position: position, paused: paused)
        }
    }
    private func editQueue(_ queue: MusicQueue, position: Double, paused: Bool) async throws {
        guard !isClosed, !mirrored.isEmpty, queue.current != nil else { return }
        let timeline = queue.history + queue.items
        guard timeline.count <= 10_000 else { throw SpotifyPlaybackError.queueTooLarge }
        if mirrored.map(\.id) == timeline.map(\.id) {
            guard queue.repeatMode != repeatMode, let deviceID else { return }
            beginCommand()
            defer { finishCommand() }
            try requireAllowed(
                queue.repeatMode == .one || repeatMode == .one
                    ? "toggling_repeat_track" : "toggling_repeat_context")
            try await client.repeatMode(
                queue.repeatMode == .one ? "track" : "off", deviceID: deviceID)
            repeatMode = queue.repeatMode
            if confirmedQueue != nil { confirmedQueue = queue }
            return
        }
        let count = timeline.count - mirrored.count
        let insertion = zip(mirrored, timeline).prefix { $0.id == $1.id }.count
        if (1...100).contains(count), insertion > cursor,
            Array(timeline.dropFirst(insertion + count).map(\.id))
                == Array(mirrored.dropFirst(insertion).map(\.id))
        {
            beginCommand()
            defer { finishCommand() }
            if try await validateHelper(), let playlistID {
                // A failed write invalidates offsets even if Spotify accepted it before a transport error.
                mirroredSnapshotID = nil
                let version = try await client.insertItems(
                    playlistID: playlistID,
                    uris: timeline[insertion..<insertion + count].map(\.track.uri),
                    position: insertion)
                mirrored = timeline
                mirroredSnapshotID = version.isEmpty ? nil : version
                if confirmedQueue != nil { confirmedQueue = queue }
                return
            }
        }
        if paused {
            try await setPaused(true)
            beginCommand()
            defer { finishCommand() }
            let id = try await ensurePlaylist()
            try await mirror(queue, playlistID: id)
            // Rewriting a paused context does not establish Spotify's current offset.
            confirmedQueue = nil
        } else {
            try await play(queue: queue, position: position)
        }
    }
}
