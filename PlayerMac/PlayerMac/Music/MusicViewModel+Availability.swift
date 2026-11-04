import Foundation
import MusicCore

extension MusicViewModel {
    var engineCanPlay: Bool {
        switch engineAvailability {
        case .ready: true
        case .reconnecting, .externalTakeover, .failed: !engineNeedsSetup
        case .notInstalled, .downloading, .needsKey, .needsPairing, .starting, .expired: false
        }
    }

    func allows(_ action: String) -> Bool {
        acceptsPlayback && engineCanPlay && !disallowedActions.contains(action)
            && (action != "volume" || volumeKnown)
    }

    var hasTrack: Bool { currentTrack != nil }
    var canPlayLibrary: Bool { allows("interrupting_playback") }
    var canTogglePause: Bool { hasTrack && allows(paused ? "resuming" : "pausing") }
    var canStop: Bool { hasTrack && allows("pausing") && allows("seeking") }
    var canSeek: Bool { hasTrack && allows("seeking") }
    var canNext: Bool {
        hasTrack && allows("skipping_next")
            && (!queue.upcoming.isEmpty || queue.repeatMode == .all)
    }
    var canPrevious: Bool { hasTrack && allows("skipping_prev") && !queue.history.isEmpty }
    var canShuffle: Bool { hasTrack && allows("toggling_shuffle") }
    var canRepeat: Bool {
        hasTrack
            && allows(
                queue.repeatMode == .off ? "toggling_repeat_context" : "toggling_repeat_track")
    }
    var canAdjustVolume: Bool { allows("volume") }

    /// Additive v1 restrictions also disable controls on older iPhone remotes.
    var effectiveDisallowedActions: Set<String> {
        let transport: Set<String> = [
            "pausing", "resuming", "seeking", "skipping_next", "skipping_prev",
            "toggling_shuffle", "toggling_repeat_context", "toggling_repeat_track",
        ]
        var result = disallowedActions
        if !hasTrack { result.formUnion(transport) }
        if !acceptsPlayback || !engineCanPlay {
            result.formUnion(transport.union(["interrupting_playback", "volume"]))
        }
        if !volumeKnown { result.insert("volume") }
        return result
    }

    func confirmFavoriteFeedback(_ mutations: [LibraryMutation]) {
        for mutation in mutations {
            guard case .trackLiked(_, let liked) = mutation else { continue }
            let id = UUID()
            favoriteFeedbackID = id
            favoriteFeedbackLiked = liked
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.favoriteFeedbackID == id else { return }
                self.favoriteFeedbackID = nil
                self.favoriteFeedbackLiked = nil
                self.notifyPlayback()
            }
            break
        }
    }
}
