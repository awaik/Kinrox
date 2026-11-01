import Foundation
import MusicCore

extension MusicViewModel {
    func allows(_ action: String) -> Bool { !disallowedActions.contains(action) }

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
