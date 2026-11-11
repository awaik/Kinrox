import Foundation
import RemoteProtocol

/// A confirmed Not interested choice, offered for Undo for a few seconds.
struct SimilarHiddenFeedback: Equatable {
    let id = UUID()
    let trackId: String
    let scope: RemoteNotInterestedScope
    let name: String

    var text: String {
        scope == .artist
            ? L10n.format("Hidden %@ from Similar", name)
            : L10n.format("Hidden “%@” from Similar", name)
    }
}

extension RemoteAppModel {
    /// Older Macs omit `state.music.similar`; the button then explains the update.
    var supportsSimilar: Bool { supportsMusic && state.music?.similar != nil }
    var similarActive: Bool {
        supportsSimilar && state.music?.similar?.active == true
            && state.music?.similar?.finding != true
    }
    var similarFinding: Bool {
        supportsSimilar && (similarRequestPending || state.music?.similar?.finding == true)
    }
    var canStartSimilar: Bool {
        controlsEnabled && state.hasMedia && !similarFinding
            && (!supportsSimilar || state.music?.similar?.available == true)
    }

    func setSimilar(_ active: Bool) {
        guard supportsMusic, !similarRequestPending else { return }
        guard supportsSimilar else {
            commandError = L10n.text("Update Kinrox on Mac to use Similar.")
            return
        }
        if active, state.music?.similar?.available != true { return }
        similarRequestPending = true
        send(.setSimilar(active: active)) { [weak self] _ in
            self?.similarRequestPending = false
        }
    }

    /// Offered only while Similar runs: the Mac also drops matching pending similar tracks.
    func hideFromSimilar(_ track: RemoteMusicTrack, scope: RemoteNotInterestedScope) {
        guard similarActive else { return }
        let name = scope == .artist ? track.artists.first : track.title
        guard let name, !name.isEmpty else { return }
        send(.setNotInterested(trackId: track.id, scope: scope, excluded: true)) {
            [weak self] accepted in
            guard let self, accepted else { return }
            self.showSimilarFeedback(.init(trackId: track.id, scope: scope, name: name))
        }
    }

    func undoHiddenFromSimilar() {
        guard let feedback = similarFeedback else { return }
        clearSimilarFeedback()
        send(.setNotInterested(trackId: feedback.trackId, scope: feedback.scope, excluded: false))
    }

    private func showSimilarFeedback(_ feedback: SimilarHiddenFeedback) {
        clearSimilarFeedback()
        similarFeedback = feedback
        let attempt = epoch
        similarFeedbackTimer = scheduler.schedule(after: 6) { [weak self] in
            guard let self, self.epoch == attempt, self.similarFeedback?.id == feedback.id else {
                return
            }
            self.clearSimilarFeedback()
        }
    }

    func clearSimilarFeedback() {
        similarFeedbackTimer?.cancel()
        similarFeedbackTimer = nil
        similarFeedback = nil
    }
}
