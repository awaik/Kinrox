import AppKit
import SwiftUI

/// Application menu. Unmodified keys (space, arrows, F) operate through menu items,
/// so they disable while open panel is presented.
struct PlayerCommands: Commands {
    let delegate: AppDelegate

    private var session: PlayerSession { delegate.session }
    private var model: PlayerViewModel? { session.model }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L10n.text("About Kinrox")) { AboutPanel.show() }
        }
        CommandGroup(after: .appInfo) {
            if session.updates.isEnabled { UpdateMenuItem(updates: session.updates) }
        }
        CommandGroup(replacing: .help) {
            ForEach(ProjectLink.allCases) { link in
                Button(link.title) { NSWorkspace.shared.open(link.url) }
            }
        }
        TrackCommands(session: session)
        CommandMenu(L10n.text("Screensaver")) {
            Button("Matrix") { model?.startMatrix() }
                .disabled(
                    model == nil || model?.isLoading == true || session.isOpenPanelShown
                        || session.pairing.prompt != nil
                        || model?.trackController.isChoosingFile == true)
        }
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
                .disabled(!session.trackShortcutsAllowed || !(model?.canPrevious ?? false))
            Button(L10n.text("Next File")) { model?.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!session.trackShortcutsAllowed || !(model?.canNext ?? false))
            Divider()
            Button(L10n.text("Louder")) { model?.changeVolume(by: PlayerViewModel.volumeStep) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(!session.trackShortcutsAllowed || model == nil)
            Button(L10n.text("Quieter")) { model?.changeVolume(by: -PlayerViewModel.volumeStep) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(!session.trackShortcutsAllowed || model == nil)
        }
        CommandGroup(before: .windowSize) {
            Button(
                model?.isFullscreen == true
                    ? L10n.text("Exit Full Screen") : L10n.text("Full Screen")
            ) {
                model?.toggleFullscreen()
            }
            .keyboardShortcut("f", modifiers: [])
            .disabled(!session.trackShortcutsAllowed || model == nil)
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

/// Kinrox → Check for Updates…, with the pending version as a badge (Figma page 05).
private struct UpdateMenuItem: View {
    let updates: UpdateCenter

    var body: some View {
        Button {
            updates.checkForUpdates()
        } label: {
            Label(L10n.text("Check for Updates…"), systemImage: "arrow.up.circle")
        }
        .disabled(!updates.canCheckForUpdates)
        .badge(updates.available.map { Text(L10n.format("%@ available", $0.version)) })
    }
}
