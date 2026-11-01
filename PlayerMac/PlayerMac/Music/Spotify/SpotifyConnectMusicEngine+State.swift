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
        for attempt in 0..<8 {
            if attempt > 0 { try await Task.sleep(for: pollInterval) }
            guard !isClosed else { throw CancellationError() }
            if let state = try await client.playback(), predicate(state) { return state }
        }
        throw SpotifyPlaybackError.unconfirmed
    }

    func validateContext(_ state: SpotifyPlayback) throws {
        guard state.device.id == deviceID, let playlistID,
            state.context?.uri == "spotify:playlist:" + playlistID
        else { throw SpotifyPlaybackError.otherDevice }
    }

    static func matches(_ track: SpotifyTrack?, uri: String) -> Bool {
        track?.uri == uri || track?.linkedFrom?.uri == uri
    }

    func publish(_ state: SpotifyPlayback, detectAdvance: Bool) {
        guard state.device.id == deviceID, let playlistID,
            state.context?.uri == "spotify:playlist:" + playlistID,
            mirrored.indices.contains(cursor)
        else { return }
        let position = (state.progressMS ?? 0) / 1000
        let previousPosition = lastState?.position ?? 0
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
            volume: state.device.volumePercent ?? lastState?.volume ?? 0,
            deviceName: state.device.name, occurrenceID: mirrored[cursor].id,
            disallowedActions: Self.restrictions(state))
        lastState = snapshot
        continuation.yield(.state(snapshot))
        if detectAdvance, !endReported, !state.isPlaying, cursor == mirrored.count - 1,
            snapshot.duration > 0, position >= snapshot.duration - 2
        {
            endReported = true
            continuation.yield(.ended)
        }
    }

    func beginPolling() {
        guard polling == nil, !isClosed else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isClosed else { return }
                do {
                    try await Task.sleep(
                        for: self.lastState?.paused == true ? .seconds(10) : self.pollInterval)
                } catch { return }
                guard !self.isCommandRunning else { continue }
                let generation = self.commandGeneration
                do {
                    guard let state = try await self.client.playback() else {
                        throw SpotifyError.noDevice
                    }
                    guard !self.isClosed, !self.isCommandRunning,
                        generation == self.commandGeneration
                    else { continue }
                    try self.validateContext(state)
                    self.publish(state, detectAdvance: true)
                } catch is CancellationError { return } catch {
                    // Errors from a superseded request must not retire the polling
                    // task that a newer successful command still relies on.
                    guard !self.isClosed, !self.isCommandRunning,
                        generation == self.commandGeneration
                    else { continue }
                    self.continuation.yield(.failure(SpotifyStatus.message(error)))
                    // Authentication, device changes and quota exhaustion need an
                    // explicit user action; an unattended poll never retries them.
                    self.polling = nil
                    return
                }
            }
        }
    }
}
