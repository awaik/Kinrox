import Foundation
import MusicCore

extension MusicViewModel {
    func startDiscoveryRadio() {
        let tracks = (discoverySnapshot?.displayTracks ?? contents.tracks).filter {
            $0.isPlayable != false
        }
        guard canPlayLibrary, !tracks.isEmpty else { return }
        stopDiscoveryRadio()
        let session = radioSessionID
        runPlayback(startsPlayback: true) { model in
            guard model.radioSessionID == session else { return }
            var queue = MusicQueue()
            queue.start(tracks)
            try await model.startQueue(queue)
            guard model.radioSessionID == session else { return }
            model.isDiscoveryRadioActive = true
            model.radioSeenTrackIDs = Set(tracks.map(\.id))
            model.radioSeenDedupeKeys = tracks.reduce(into: []) {
                $0.formUnion(MusicDiscoveryIdentity.keys($1))
            }
            model.refillDiscoveryRadioIfNeeded()
        }
    }

    func stopDiscoveryRadio() {
        isDiscoveryRadioActive = false
        radioSessionID = UUID()
        radioRefillTask?.cancel()
        radioRefillTask = nil
        isRefillingRadio = false
        isStartingSimilar = false
        radioSeenTrackIDs.removeAll()
        radioSeenDedupeKeys.removeAll()
        radioAttemptedOccurrences.removeAll()
    }

    /// `replacingSource` swaps the pending source list for similar tracks on its first fill.
    func refillDiscoveryRadioIfNeeded(replacingSource: Bool = false) {
        synchronizeDiscoveryConsent()
        guard isDiscoveryRadioActive, !isRefillingRadio, let current = queue.current,
            replacingSource
                || (queue.source.count < 5 && !radioAttemptedOccurrences.contains(current.id))
        else { return }
        isRefillingRadio = true
        let session = radioSessionID
        let consent = listenBrainzEnabled
        let store = store
        radioRefillTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.radioSessionID == session {
                    self.isRefillingRadio = false
                    // A start that found nothing playable leaves the queue as it was.
                    if replacingSource, self.isStartingSimilar { self.failSimilarStart() }
                }
            }
            do {
                let snapshot: MusicDiscoverySnapshot
                if let provider = self.radioDiscoveryProvider {
                    snapshot = try await provider(current.track)
                } else if let spotify = store as? SpotifyLibraryStore {
                    self.synchronizeDiscoveryConsent()
                    spotify.setListenBrainzEnabled(self.listenBrainzEnabled)
                    guard spotify.isConnected else { return }
                    snapshot = try await spotify.discover(
                        seedTitle: current.track.title, seedTrack: current.track,
                        seedArtist: current.track.artists.first, mode: self.discoveryMode,
                        selectedGenre: self.discoverySelectedGenre,
                        hideLiked: self.discoveryHideLiked,
                        notInterestedTrackIDs: self.notInterestedTrackIDs,
                        notInterestedArtistIDs: self.notInterestedArtistIDs)
                } else {
                    let catalog = self.catalog
                    let library = self.library
                    let history = self.playHistory
                    let hideLiked = self.discoveryHideLiked
                    let excludedTracks = self.notInterestedTrackIDs
                    let excludedArtists = self.notInterestedArtistIDs
                    snapshot = try await MusicDiscoveryComputation.run {
                        MusicDiscoveryEngine.build(
                            seedTrackIDs: [current.track.id], hideLiked: hideLiked,
                            catalog: catalog, library: library, history: history,
                            notInterestedTrackIDs: excludedTracks,
                            notInterestedArtistIDs: excludedArtists)
                    }
                }
                guard !Task.isCancelled, self.isDiscoveryRadioActive,
                    self.radioSessionID == session, self.store === store,
                    self.listenBrainzEnabled == consent
                else { return }
                await self.commitRadioRefill(
                    snapshot.displayTracks, occurrenceID: current.id, session: session,
                    store: store, replacingSource: replacingSource, consent: consent)
            } catch {
                // Discovery failure leaves the current queue playable.
            }
        }
    }

    private func commitRadioRefill(
        _ candidates: [MusicTrack], occurrenceID: UUID, session: UUID, store: any MusicLibraryStore,
        replacingSource: Bool, consent: Bool
    ) async {
        // Join the playback coordinator, keeping the refill busy through the actual engine commit.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let action: @MainActor () async -> Void = { [weak self] in
                defer { continuation.resume() }
                guard let self, self.isDiscoveryRadioActive, self.radioSessionID == session,
                    self.store === store, self.listenBrainzEnabled == consent,
                    replacingSource || self.queue.source.count < 5
                else { return }
                // Replaced source occurrences may come back as similar tracks.
                let kept = replacingSource ? self.queue.items.count - self.queue.source.count : 0
                let existing =
                    (replacingSource ? Array(self.queue.items.prefix(kept)) : self.queue.items)
                    + self.queue.history
                var ids = self.radioSeenTrackIDs.union(existing.map(\.track.id))
                var keys = existing.reduce(into: self.radioSeenDedupeKeys) {
                    $0.formUnion(MusicDiscoveryIdentity.keys($1.track))
                }
                var refill: [MusicTrack] = []
                for track in candidates
                where track.isPlayable != false && !ids.contains(track.id)
                    && !self.notInterestedTrackIDs.contains(track.id)
                    && self.notInterestedArtistIDs.isDisjoint(with: track.artists.map(\.id))
                {
                    let trackKeys = MusicDiscoveryIdentity.keys(track)
                    guard keys.isDisjoint(with: trackKeys) else { continue }
                    refill.append(track)
                    ids.insert(track.id)
                    keys.formUnion(trackKeys)
                    if refill.count == 10 { break }
                }
                guard !refill.isEmpty else {
                    self.radioAttemptedOccurrences.insert(occurrenceID)
                    return
                }
                var next = self.queue
                if replacingSource { next.replaceSource(refill) } else { next.appendSource(refill) }
                do {
                    if let engine = self.musicEngine {
                        try await engine.updateQueue(
                            next, position: self.displayedPosition, paused: self.paused)
                    }
                    guard self.isDiscoveryRadioActive, self.radioSessionID == session,
                        self.store === store, self.listenBrainzEnabled == consent
                    else { return }
                    self.queue = next
                    self.radioSeenTrackIDs = ids
                    self.radioSeenDedupeKeys = keys
                    self.isStartingSimilar = false
                    if self.isQueue { self.refreshContents() }
                    self.notifyPlayback()
                } catch {
                    // No candidates are consumed on a transient engine failure.
                }
            }
            if let coordinator {
                coordinator.perform(.music, action: action)
            } else {
                Task { await action() }
            }
        }
    }

}
