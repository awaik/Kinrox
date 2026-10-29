import Foundation
import Observation

/// Shared application state upon which menus and player window depend.
@MainActor @Observable
final class PlayerSession {
    var model: PlayerViewModel? { didSet { remote?.connect(to: model) } }
    var remote: RemoteServer?
    /// While file open panel is displayed, unmodified keys belong to it.
    var isOpenPanelShown = false
    let recents: RecentFilesStore
    let pairing = PairingCenter()

    init(recents: RecentFilesStore) {
        self.recents = recents
    }

    var canControl: Bool {
        trackShortcutsAllowed && pairing.prompt == nil && (model?.canControl ?? false)
    }

    var trackShortcutsAllowed: Bool {
        !isOpenPanelShown && model?.trackController.presentation == nil
            && model?.trackController.isChoosingFile != true
    }
}
