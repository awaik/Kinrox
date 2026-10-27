import SwiftUI

/// Application menu. Unmodified keys (space, arrows, F) operate through menu items,
/// so they disable while open panel is presented.
struct PlayerCommands: Commands {
    let delegate: AppDelegate

    private var session: PlayerSession { delegate.session }
    private var model: PlayerViewModel? { session.model }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.text("Open File…")) { delegate.openFile() }
                .keyboardShortcut("o", modifiers: .command)
            Menu(L10n.text("Open Recent")) {
                ForEach(session.recents.items) { item in
                    Button(item.title) { delegate.openRecent(item) }
                }
                if !session.recents.items.isEmpty { Divider() }
                Button(L10n.text("Clear Menu")) { delegate.clearRecents() }
                    .disabled(session.recents.items.isEmpty)
            }
        }
        CommandMenu(L10n.text("Playback")) {
            Button(model?.paused == false ? L10n.text("Pause") : L10n.text("Play")) {
                model?.togglePause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!session.canControl)
            Divider()
            seekButton(L10n.text("Backward 5s"), -PlayerViewModel.shortSeek, .leftArrow, [])
            seekButton(L10n.text("Forward 5s"), PlayerViewModel.shortSeek, .rightArrow, [])
            seekButton(L10n.text("Backward 30s"), -PlayerViewModel.longSeek, .leftArrow, .shift)
            seekButton(L10n.text("Forward 30s"), PlayerViewModel.longSeek, .rightArrow, .shift)
            Divider()
            Button(L10n.text("Previous File")) { model?.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(session.isOpenPanelShown || !(model?.canPrevious ?? false))
            Button(L10n.text("Next File")) { model?.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(session.isOpenPanelShown || !(model?.canNext ?? false))
            Divider()
            Button(L10n.text("Louder")) { model?.changeVolume(by: PlayerViewModel.volumeStep) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(session.isOpenPanelShown || model == nil)
            Button(L10n.text("Quieter")) { model?.changeVolume(by: -PlayerViewModel.volumeStep) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(session.isOpenPanelShown || model == nil)
        }
        CommandGroup(before: .windowSize) {
            Button(
                model?.isFullscreen == true
                    ? L10n.text("Exit Full Screen") : L10n.text("Full Screen")
            ) {
                model?.toggleFullscreen()
            }
            .keyboardShortcut("f", modifiers: [])
            .disabled(session.isOpenPanelShown || model == nil)
            Divider()
        }
    }

    private func seekButton(
        _ title: String, _ seconds: Double, _ key: KeyEquivalent, _ modifiers: EventModifiers
    ) -> some View {
        Button(title) { model?.seek(by: seconds) }
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(!session.canControl)
    }
}
