import Foundation
import MusicCore

/// Similar control from the iPhone remote: it starts from the playing track without
/// interrupting it, unlike the Mac's Listen to similar, which plays the shown results.
extension MusicViewModel {
    var canStartSimilarFromCurrent: Bool {
        hasTrack && canPlayLibrary && (store as? SpotifyLibraryStore)?.isConnected != false
    }

    /// Replaces pending source tracks with tracks like the current one, then keeps refilling.
    @discardableResult
    func startSimilarFromCurrent() -> Bool {
        guard canStartSimilarFromCurrent, let current = queue.current else { return false }
        stopDiscoveryRadio()
        isDiscoveryRadioActive = true
        isStartingSimilar = true
        let kept = [current] + queue.manual + queue.history
        radioSeenTrackIDs = Set(kept.map(\.track.id))
        radioSeenDedupeKeys = kept.reduce(into: []) {
            $0.formUnion(MusicDiscoveryIdentity.keys($1.track))
        }
        refillDiscoveryRadioIfNeeded(replacingSource: true)
        notifyPlayback()
        return true
    }

    /// Stop keeps the similar tracks already in the queue.
    func stopSimilar() {
        stopDiscoveryRadio()
        notifyPlayback()
    }

    func failSimilarStart() {
        stopDiscoveryRadio()
        statusMessage = L10n.text("Nothing similar found yet")
        notifyPlayback()
    }

    /// Hides a track or its artist from suggestions. While Similar runs, matching pending
    /// similar tracks leave the queue and a matching current track is skipped.
    @discardableResult
    func hideFromSimilar(_ track: MusicTrack, artist: MusicArtist?) -> Bool {
        let inserted: Bool
        if let artist {
            inserted = notInterestedArtistIDs.insert(artist.id).inserted
            if inserted { notInterestedUndo.append((nil, artist.id)) }
        } else {
            inserted = notInterestedTrackIDs.insert(track.id).inserted
            if inserted { notInterestedUndo.append((track.id, nil)) }
        }
        if inserted { persistNotInterested(refresh: selection.source == .similar) }
        guard isDiscoveryRadioActive, paused || allows("interrupting_playback") else {
            return inserted
        }
        let matches: (MusicTrack) -> Bool = { candidate in
            if let artist { return candidate.artists.contains { $0.id == artist.id } }
            return candidate.id == track.id
        }
        let session = radioSessionID
        runPlayback(startsPlayback: queue.current.map { matches($0.track) } ?? false) { model in
            guard model.radioSessionID == session else { return }
            var next = model.queue
            for item in next.source where matches(item.track) { next.remove(item.id) }
            let skipsCurrent = next.current.map { matches($0.track) } ?? false
            guard skipsCurrent || next != model.queue else { return }
            model.radioAttemptedOccurrences.removeAll()
            if skipsCurrent {
                // Repeat All may revisit a hidden item in context. Never restart it.
                var advanced = next
                for _ in 0..<max(1, next.items.count + next.context.count) {
                    guard let item = advanced.next() else { break }
                    if item.track.isPlayable != false, !matches(item.track) {
                        try await model.startQueue(advanced)
                        return
                    }
                }
                // No replacement is ready: stop now rather than keep playing the hidden track.
                try await model.musicEngine?.stop()
                model.finishPlayHistory()
                model.paused = true
                model.position = 0
            } else if let engine = model.musicEngine {
                try await engine.updateQueue(
                    next, position: model.displayedPosition, paused: model.paused)
            }
            model.queue = next
            model.refillDiscoveryRadioIfNeeded()
            if model.isQueue { model.refreshContents() }
            model.notifyPlayback()
        }
        return inserted
    }

    func unhideFromSimilar(trackID: String?, artistID: String?) {
        var changed = false
        if let trackID, notInterestedTrackIDs.remove(trackID) != nil { changed = true }
        if let artistID, notInterestedArtistIDs.remove(artistID) != nil { changed = true }
        guard changed else { return }
        notInterestedUndo.removeAll { $0.track == trackID && $0.artist == artistID }
        persistNotInterested(refresh: selection.source == .similar)
    }
}
