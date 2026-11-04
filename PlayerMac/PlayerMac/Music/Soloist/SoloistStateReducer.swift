import Foundation

/// One process represents one queue occurrence. URI equality never identifies the next copy.
/// A successful exit alone is not EOF: the confirmed position must also reach the boundary.
struct SoloistStateReducer: Sendable {
    private(set) var epoch: UInt64 = 0
    private(set) var ready = false
    private(set) var loggedIn = false
    private(set) var inactive = false
    private(set) var stateRevision: UInt64 = 0
    private(set) var revision: UInt64 = 0
    private(set) var snapshot = MusicPlaybackSnapshot(
        uri: nil, position: 0, duration: 0, paused: true, volume: nil,
        deviceName: "This Mac", occurrenceID: nil)
    var suppressEnd = false
    private var anchor = ContinuousClock.now
    private var hasPlayed = false
    private var finished = false
    private var terminalBoundary = false
    private var takeover = false
    private var wireStatus = "idle"
    private var naturalEnd: ContinuousClock.Instant?
    private var terminalBuffering = false

    mutating func begin(
        epoch: UInt64, occurrenceID: UUID, uri: String, now: ContinuousClock.Instant
    ) {
        self = Self()
        self.epoch = epoch
        snapshot.occurrenceID = occurrenceID
        snapshot.uri = uri
        anchor = now
    }

    func position(at now: ContinuousClock.Instant) -> Double {
        let elapsed = anchor.duration(to: now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return min(snapshot.duration, snapshot.position + (snapshot.paused ? 0 : max(0, seconds)))
    }

    func current(at now: ContinuousClock.Instant) -> MusicPlaybackSnapshot {
        var value = snapshot
        value.position = position(at: now)
        return value
    }

    mutating func setParkedPosition(_ value: Double, now: ContinuousClock.Instant) {
        snapshot.position = min(max(0, value), max(0, snapshot.duration - 1))
        snapshot.paused = true
        snapshot.disallowedActions.insert("volume")
        anchor = now
    }

    mutating func receive(
        _ frame: SoloistFrame, epoch: UInt64, now: ContinuousClock.Instant,
        wallTime: Date = Date()
    ) -> [MusicEngineEvent] {
        guard epoch == self.epoch, !finished, !takeover else { return [] }
        guard
            [
                "auth_state", "playback_state", "playback_changed", "track_changed",
                "volume_changed", "position_sync", "device_changed", "context_changed",
            ].contains(frame.type)
        else { return [] }
        revision &+= 1
        if let value = frame.volume { snapshot.volume = value }
        if let value = frame.loggedIn { loggedIn = value }
        if frame.type == "playback_state" { stateRevision &+= 1 }
        if let active = frame.isActive {
            inactive = !active
            if !active, hasPlayed {
                // Soloist may relinquish its device immediately after a confirmed pause.
                // Keep the paused occurrence; only an explicit Play can reclaim it.
                if (frame.status ?? wireStatus) == "paused" {
                    snapshot.disallowedActions.insert("volume")
                } else {
                    return takeOver(now: now)
                }
            }
        }
        if let status = frame.status {
            if status == "buffering", !snapshot.paused, snapshot.duration > 0,
                position(at: now) >= snapshot.duration - 1.5
            {
                terminalBuffering = true
            }
            if status == "paused" || status == "idle" { terminalBuffering = false }
            wireStatus = status
        }
        let foreign = frame.item?.uri.map { !$0.isEmpty && $0 != snapshot.uri } == true
        if foreign {
            // Single-track mode may publish recommendation metadata while exiting at EOF.
            // Preserve the original anchor until the owned process exits. Never play that item.
            if hasPlayed, wireStatus == "buffering", atBoundary(now), !suppressEnd {
                terminalBoundary = true
                return []
            }
            if hasPlayed { return takeOver(now: now) }
            return [.state(current(at: now))]
        }
        if let duration = frame.item?.duration { snapshot.duration = duration }
        if let value = frame.status, value != "playing" {
            snapshot.position = position(at: now)
            snapshot.paused = true
            anchor = now
            ready = false
        }
        if let value = frame.position {
            snapshot.position = value.positionMS / 1000
            if let time = value.timestampMS, value.speed == 1 {
                let age = wallTime.timeIntervalSince1970 - time / 1000
                // Do not extrapolate unbounded wall-clock skew into a false EOF.
                if (0...2).contains(age) { snapshot.position += age }
            }
            snapshot.position = min(snapshot.duration, snapshot.position)
            anchor = now
        }
        let completePlayback =
            frame.type == "playback_state" && frame.item?.uri == snapshot.uri
            && frame.isActive == true
        let resumedPlayback = frame.type == "playback_changed" && hasPlayed && !inactive
        if completePlayback || resumedPlayback,
            frame.status == "playing", frame.position?.speed == 1
        {
            ready = true
            hasPlayed = true
            snapshot.paused = false
            terminalBoundary = false
            terminalBuffering = false
        }
        if ready, frame.position?.speed == 1 {
            naturalEnd = now.advanced(by: .seconds(max(0, snapshot.duration - snapshot.position)))
        }
        return [.state(current(at: now))]
    }

    mutating func retire(now: ContinuousClock.Instant) {
        snapshot.position = position(at: now)
        snapshot.paused = true
        ready = false
        finished = true
        anchor = now
    }

    mutating func processExited(
        code: Int32, epoch: UInt64, now: ContinuousClock.Instant
    ) -> [MusicEngineEvent] {
        guard epoch == self.epoch, !finished else { return [] }
        let ended =
            code == 0 && hasPlayed && !suppressEnd && !takeover
            && (terminalBoundary || ((!snapshot.paused || terminalBuffering) && atBoundary(now)))
        retire(now: now)
        if ended, let id = snapshot.occurrenceID {
            return [.state(snapshot), .ended(occurrenceID: id)]
        }
        if takeover { return [.state(snapshot)] }
        if code == 10 { return [.state(snapshot), .availability(.expired)] }
        return [
            .state(snapshot),
            .availability(.failed("Soloist playback stopped.")),
        ]
    }

    private func atBoundary(_ now: ContinuousClock.Instant) -> Bool {
        guard snapshot.duration > 0 else { return false }
        if terminalBuffering, let naturalEnd { return now >= naturalEnd }
        return position(at: now) >= snapshot.duration - 0.75
    }

    private mutating func takeOver(now: ContinuousClock.Instant) -> [MusicEngineEvent] {
        snapshot.position = position(at: now)
        snapshot.paused = true
        ready = false
        takeover = true
        anchor = now
        return [.state(snapshot), .availability(.externalTakeover)]
    }
}
