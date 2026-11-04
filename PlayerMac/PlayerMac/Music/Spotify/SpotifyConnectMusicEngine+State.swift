import Foundation
import MusicCore
import SpotifyWebAPI

extension SpotifyConnectMusicEngine {
    func requireAllowed(_ action: String, state: SpotifyPlayback? = nil) throws {
        let restrictions = state.map(Self.restrictions) ?? lastState?.disallowedActions ?? []
        guard !restrictions.contains(action) else { throw SpotifyPlaybackError.restricted }
    }

    static func restrictions(_ state: SpotifyPlayback) -> Set<String> {
        var result = state.actions?.disallowed ?? []
        if state.device.supportsVolume == false { result.insert("volume") }
        if state.device.isRestricted {
            result.formUnion([
                "pausing", "resuming", "seeking", "skipping_next", "skipping_prev",
                "toggling_shuffle", "toggling_repeat_context", "toggling_repeat_track",
                "interrupting_playback", "volume",
            ])
        }
        return result
    }

    func confirm(_ predicate: (SpotifyPlayback) -> Bool) async throws -> SpotifyPlayback {
        for delay in confirmationDelays {
            try await Task.sleep(for: delay)
            guard !isClosed else { throw CancellationError() }
            if let state = try await client.playback(), predicate(state) { return state }
        }
        throw SpotifyPlaybackError.unconfirmed
    }

    func validateContext(_ state: SpotifyPlayback) throws {
        guard state.device.id == deviceID, state.device.name == localDeviceName,
            state.device.type == "Computer", let playlistID,
            state.context?.uri == "spotify:playlist:" + playlistID
        else { throw SpotifyPlaybackError.otherDevice }
    }

    static func matches(_ track: SpotifyTrack?, uri: String) -> Bool {
        track?.uri == uri || track?.linkedFrom?.uri == uri
    }

    func publish(_ state: SpotifyPlayback, detectAdvance: Bool, boundaryPosition: Double? = nil) {
        guard state.device.id == deviceID else { return }
        guard let playlistID,
            state.context?.uri == "spotify:playlist:" + playlistID,
            mirrored.indices.contains(cursor)
        else {
            let snapshot = MusicPlaybackSnapshot(
                uri: nil, position: 0, duration: 0, paused: true,
                volume: state.device.volumePercent, deviceName: state.device.name,
                occurrenceID: nil, disallowedActions: Self.restrictions(state))
            lastState = snapshot
            confirmedQueue = nil
            continuation.yield(.state(snapshot))
            return
        }
        let position = (state.progressMS ?? 0) / 1000
        let elapsed = stateTimestamp.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let previousPosition =
            boundaryPosition
            ?? ((lastState?.position ?? 0) + (lastState?.paused == false ? seconds : 0))
        if detectAdvance, repeatMode != .one {
            let currentMatches = Self.matches(state.item, uri: mirrored[cursor].track.uri)
            // Consecutive copies have equal URIs. A natural end-to-start transition
            // advances the occurrence; explicit seeks publish with detection off.
            let wrapped =
                currentMatches && previousPosition > mirrored[cursor].track.duration - 5
                && position < 5 && previousPosition > position + 2
            if !currentMatches || wrapped,
                let next = mirrored.indices.dropFirst(cursor + 1).first(where: {
                    Self.matches(state.item, uri: mirrored[$0].track.uri)
                })
            {
                cursor = next
            }
        }
        guard Self.matches(state.item, uri: mirrored[cursor].track.uri) else {
            continuation.yield(.failure(SpotifyStatus.message(SpotifyPlaybackError.otherDevice)))
            return
        }
        let snapshot = MusicPlaybackSnapshot(
            uri: mirrored[cursor].track.uri,
            position: position, duration: (state.item?.durationMS ?? 0) / 1000,
            paused: !state.isPlaying,
            volume: state.device.volumePercent,
            deviceName: state.device.name, occurrenceID: mirrored[cursor].id,
            disallowedActions: Self.restrictions(state))
        let wasPaused = lastState?.paused == true
        if state.isPlaying || position < snapshot.duration - 2 { endReported = false }
        lastState = snapshot
        stateTimestamp = .now
        if var queue = confirmedQueue {
            while queue.current?.id != mirrored[cursor].id,
                queue.upcoming.contains(where: { $0.id == mirrored[cursor].id })
            {
                _ = queue.next()
            }
            confirmedQueue = queue
        }
        continuation.yield(.state(snapshot))
        if detectAdvance, !endReported, !wasPaused, !state.isPlaying, cursor == mirrored.count - 1,
            snapshot.duration > 0, position >= snapshot.duration - 2
        {
            endReported = true
            continuation.yield(.ended(occurrenceID: mirrored[cursor].id))
        }
    }

    func scheduleBoundary() {
        boundaryTask?.cancel()
        boundaryTask = nil
        guard !isClosed, !isCommandRunning, let state = lastState, !state.paused, state.duration > 0
        else { return }
        let generation = commandGeneration
        let elapsed = stateTimestamp.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let delay =
            boundaryDelay ?? .seconds(max(0.5, state.duration - state.position - seconds + 0.35))
        boundaryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.reconcile(generation: generation)
        }
    }

    /// A delayed observation, including a failed one, never supersedes a newer command.
    func reconcile(generation: UInt64) async {
        guard !isClosed, !isCommandRunning, generation == commandGeneration else { return }
        do {
            guard let state = try await client.playback() else { throw SpotifyError.noDevice }
            guard !isClosed, !isCommandRunning, generation == commandGeneration else { return }
            try validateContext(state)
            publish(state, detectAdvance: true)
            scheduleBoundary()
        } catch is CancellationError {} catch {
            guard !isClosed, !isCommandRunning, generation == commandGeneration else { return }
            continuation.yield(.failure(SpotifyStatus.message(error)))
            boundaryTask = nil
        }
    }
}
