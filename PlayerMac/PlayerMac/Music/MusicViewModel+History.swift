import Foundation
import MusicCore

struct MusicActivePlaySession {
    var occurrenceID: UUID
    var track: MusicTrack
    var startedAt: Date
    var lastUpdate: Date
    var seconds: Double = 0
    var running: Bool
}

extension MusicViewModel {
    /// Wall-clock listening time excludes pause time and is unaffected by seeks.
    func updatePlayHistory() {
        if activePlaySession?.occurrenceID != queue.current?.id { finishPlayHistory() }
        let now = historyNow()
        if var active = activePlaySession {
            if active.running { active.seconds += max(0, now.timeIntervalSince(active.lastUpdate)) }
            active.running = !paused
            active.lastUpdate = now
            activePlaySession = active
        } else if !paused, let current = queue.current {
            activePlaySession = MusicActivePlaySession(
                occurrenceID: current.id, track: current.track,
                startedAt: now, lastUpdate: now, running: true)
        }
    }

    func finishPlayHistory(completedNaturally: Bool = false) {
        guard var active = activePlaySession else { return }
        activePlaySession = nil
        if active.running {
            active.seconds += max(0, historyNow().timeIntervalSince(active.lastUpdate))
        }
        let duration = active.track.duration
        let completed =
            completedNaturally || active.seconds >= max(30, min(duration * 0.5, duration - 5))
        let row = MusicPlayHistoryEntry(
            sessionID: listeningSessionID, trackID: active.track.id,
            previousTrackID: lastCompletedTrackID, playedAt: active.startedAt,
            playedSeconds: completedNaturally ? max(active.seconds, duration) : active.seconds,
            completed: completed, skipped: !completed && active.seconds < 30 && duration >= 30)
        if completed { lastCompletedTrackID = active.track.id }
        playHistory = MusicPlayHistoryEntry.retained(playHistory + [row], now: historyNow())
        (store as? SpotifyLibraryStore)?.recordPlay(row)
    }
}
