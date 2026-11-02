import Foundation
import MusicCore
import SpotifyWebAPI

/// Audio stays in Spotify. The complete occurrence timeline is mirrored into our private helper.
@MainActor
final class SpotifyConnectMusicEngine: MusicEngine {
    let events: AsyncStream<MusicEngineEvent>
    let continuation: AsyncStream<MusicEngineEvent>.Continuation
    let client: SpotifyClient
    let defaults: UserDefaults
    let preference: String
    let userID: String
    let localDeviceName: String
    let confirmationDelays: [Duration]
    let boundaryDelay: Duration?
    var playlistID: String?
    var deviceID: String?
    var mirrored: [MusicQueueItem] = []
    var mirroredSnapshotID: String?
    var confirmedQueue: MusicQueue?
    var cursor = 0
    var lastState: MusicPlaybackSnapshot?
    var stateTimestamp = ContinuousClock.now
    var repeatMode = MusicRepeat.off
    var boundaryTask: Task<Void, Never>?
    var isCommandRunning = false
    private(set) var commandGeneration: UInt64 = 0
    var isClosed = false
    var endReported = false
    var onPlaylistCreated: ((String) -> Void)?

    init(
        client: SpotifyClient, clientID: String, userID: String,
        defaults: UserDefaults = .standard,
        localDeviceName: String = Host.current().localizedName ?? "",
        confirmationDelays: [Duration] = [
            .milliseconds(80), .milliseconds(150), .milliseconds(300),
            .milliseconds(600), .seconds(1), .seconds(2), .seconds(2), .seconds(2),
        ],
        boundaryDelay: Duration? = nil
    ) {
        self.client = client
        self.userID = userID
        self.defaults = defaults
        self.localDeviceName = localDeviceName
        self.confirmationDelays = confirmationDelays
        self.boundaryDelay = boundaryDelay
        preference = SpotifyAccount.queuePreferencePrefix + "\(clientID).\(userID)"
        playlistID = defaults.string(forKey: preference)
        (events, continuation) = AsyncStream.makeStream()
    }

    func canResume(_ queue: MusicQueue) -> Bool {
        confirmedQueue == queue && mirroredSnapshotID != nil && cursor == queue.history.count
    }

    func play(queue: MusicQueue, position: Double) async throws {
        try await SpotifyRequestContext.$priority.withValue(.control) {
            try await playQueue(queue, position: position)
        }
    }
    private func playQueue(_ queue: MusicQueue, position: Double) async throws {
        guard !isClosed, let current = queue.current else { return }
        guard current.track.isPlayable != false else { throw SpotifyPlaybackError.restricted }
        beginCommand()
        var requestedPlay = false
        defer { finishCommand() }
        do {
            let state = try await client.playback()
            if let state { try requireAllowed("interrupting_playback", state: state) }
            let timeline = queue.history + queue.items
            var warm = false
            if mirrored.map(\.id) == timeline.map(\.id), let state,
                (try? validateContext(state)) != nil
            {
                warm = try await validateHelper()
            }
            let device: String
            let playlist: String
            if warm, let deviceID, let playlistID {
                device = deviceID
                playlist = playlistID
            } else {
                device = try await selectDevice(observed: state?.device)
                // Only pause a helper we are about to replace, not an unrelated context.
                if let state, state.device.id == device, state.isPlaying,
                    state.context?.uri == playlistID.map({ "spotify:playlist:" + $0 })
                {
                    try requireAllowed("pausing", state: state)
                    try await client.pause(true, deviceID: device)
                    _ = try await confirm { $0.device.id == device && !$0.isPlaying }
                }
                playlist = try await ensurePlaylist()
                try await mirror(queue, playlistID: playlist)
            }
            try await configurePlayback(
                queue, state: state?.device.id == device ? state : nil, device: device)
            requestedPlay = true
            try await client.play(
                contextURI: "spotify:playlist:" + playlist,
                offset: queue.history.count, position: position, deviceID: device)
            let confirmed = try await confirm {
                $0.device.id == device && $0.context?.uri == "spotify:playlist:" + playlist
                    && $0.isPlaying && Self.matches($0.item, uri: current.track.uri)
                    && abs(($0.progressMS ?? 0) / 1000 - position) < 3
            }
            cursor = queue.history.count
            confirmedQueue = queue
            repeatMode = queue.repeatMode
            endReported = false
            publish(confirmed, detectAdvance: false)
        } catch {
            if requestedPlay, let deviceID { try? await client.pause(true, deviceID: deviceID) }
            throw error
        }
    }

    func setPaused(_ paused: Bool) async throws {
        guard !isClosed, let deviceID, !mirrored.isEmpty else { return }
        beginCommand()
        defer { finishCommand() }
        guard let state = try await client.playback() else {
            if paused { return }
            throw SpotifyError.noDevice
        }
        guard state.device.id == deviceID else { throw SpotifyPlaybackError.otherDevice }
        if !paused {
            try validateContext(state)
            guard mirrored.indices.contains(cursor),
                Self.matches(state.item, uri: mirrored[cursor].track.uri)
            else {
                throw SpotifyPlaybackError.invalidQueue
            }
            if try await !validateHelper() {
                guard let queue = confirmedQueue else { throw SpotifyPlaybackError.invalidQueue }
                try await play(queue: queue, position: (state.progressMS ?? 0) / 1000)
                return
            }
            if let queue = confirmedQueue {
                try await configurePlayback(queue, state: state, device: deviceID)
            }
        }
        if state.isPlaying == paused {
            try requireAllowed(paused ? "pausing" : "resuming", state: state)
            try await client.pause(paused, deviceID: deviceID)
            let confirmed = try await confirm {
                $0.device.id == deviceID && $0.isPlaying != paused
                    && (paused || $0.context?.uri == state.context?.uri)
            }
            publish(confirmed, detectAdvance: false)
        } else {
            publish(state, detectAdvance: true)
        }
    }

    func seek(absolute position: Double) async throws {
        guard position.isFinite, let deviceID, !isClosed else { return }
        beginCommand()
        defer { finishCommand() }
        guard let state = try await client.playback() else { throw SpotifyError.noDevice }
        try validateContext(state)
        try requireAllowed("seeking", state: state)
        let duration = (state.item?.durationMS ?? 0) / 1000
        let target = min(max(0, position), max(0, duration - 1))
        let next = mirrored.indices.contains(cursor + 1) ? mirrored[cursor + 1].track.uri : nil
        let allowsAdvance = state.isPlaying && target >= duration - 2
        try await client.seek(target, deviceID: deviceID)
        let confirmed = try await confirm { observed in
            guard observed.device.id == deviceID, observed.context?.uri == state.context?.uri else {
                return false
            }
            if Self.matches(observed.item, uri: state.item?.uri ?? ""),
                abs((observed.progressMS ?? 0) / 1000 - target) < 3
            {
                return true
            }
            guard allowsAdvance else { return false }
            if let next {
                // Equal URIs cannot distinguish a stale pre-seek response from the next copy.
                return !Self.matches(state.item, uri: next)
                    && Self.matches(observed.item, uri: next)
                    && (observed.progressMS ?? 0) / 1000 < 5
            }
            return !observed.isPlaying && (observed.progressMS ?? 0) / 1000 >= duration - 2
        }
        publish(confirmed, detectAdvance: allowsAdvance, boundaryPosition: target)
    }

    func setVolume(_ volume: Double) async throws {
        guard volume.isFinite, !isClosed else { return }
        beginCommand()
        defer { finishCommand() }
        let device = try await selectDevice(requiresVolume: true)
        try requireAllowed("volume")
        let target = Double(Int(min(100, max(0, volume))))
        try await client.volume(target, deviceID: device)
        let state = try await confirm {
            $0.device.id == device && $0.device.volumePercent == target
        }
        publish(state, detectAdvance: true)
    }

    func stop() async throws {
        try await setPaused(true)
        if !mirrored.isEmpty { try await seek(absolute: 0) }
    }
    func shutdown() async {
        boundaryTask?.cancel()
        boundaryTask = nil
        try? await setPaused(true)
        isClosed = true
        boundaryTask?.cancel()
        boundaryTask = nil
        continuation.finish()
    }
    func beginCommand() {
        commandGeneration &+= 1
        isCommandRunning = true
        boundaryTask?.cancel()
        boundaryTask = nil
    }
    func finishCommand() {
        isCommandRunning = false
        scheduleBoundary()
    }
}

enum SpotifyPlaybackError: Error {
    case otherDevice, invalidQueue, queueTooLarge, unconfirmed, restricted
}
