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
        CommandGroup(after: .toolbar) {
            Button(L10n.text("Video")) { session.mode = .video }
                .keyboardShortcut("1", modifiers: .command)
            Button("Spotify") { session.mode = .music }
                .keyboardShortcut("2", modifiers: .command)
            if session.mode == .music {
                Button(L10n.text("Refresh list")) { session.music.syncLibrary() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(session.music.isLoading || session.music.isMutating)
            }
        }
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
            Button(
                (session.controlsMusic ? !session.music.paused : model?.paused == false)
                    ? L10n.text("Pause") : L10n.text("Play")
            ) {
                if session.controlsMusic {
                    session.music.togglePause()
                } else {
                    model?.togglePause()
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(
                !session.canControl || (session.controlsMusic && !session.music.canTogglePause))
            Divider()
            seekButton(L10n.text("Backward 5s"), -PlayerViewModel.shortSeek, .leftArrow, [])
            seekButton(L10n.text("Forward 5s"), PlayerViewModel.shortSeek, .rightArrow, [])
            seekButton(L10n.text("Backward 30s"), -PlayerViewModel.longSeek, .leftArrow, .shift)
            seekButton(L10n.text("Forward 30s"), PlayerViewModel.longSeek, .rightArrow, .shift)
            Divider()
            Button(
                session.controlsMusic ? L10n.text("Previous track") : L10n.text("Previous File")
            ) {
                if session.controlsMusic { session.music.previous() } else { model?.previous() }
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(
                session.controlsMusic
                    ? (!session.musicShortcutsAllowed || !session.music.canPrevious)
                    : (!session.trackShortcutsAllowed || !(model?.canPrevious ?? false)))
            Button(session.controlsMusic ? L10n.text("Next track") : L10n.text("Next File")) {
                if session.controlsMusic { session.music.next() } else { model?.next() }
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(
                session.controlsMusic
                    ? (!session.musicShortcutsAllowed || !session.music.canNext)
                    : (!session.trackShortcutsAllowed || !(model?.canNext ?? false)))
            Divider()
            Button(L10n.text("Louder")) { changeVolume(by: PlayerViewModel.volumeStep) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(
                    session.controlsMusic
                        ? (!session.musicShortcutsAllowed || !session.music.canAdjustVolume)
                        : !session.canControl)
            Button(L10n.text("Quieter")) { changeVolume(by: -PlayerViewModel.volumeStep) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(
                    session.controlsMusic
                        ? (!session.musicShortcutsAllowed || !session.music.canAdjustVolume)
                        : !session.canControl)
            Divider()
            Button(
                model?.isShowingHome == true
                    ? L10n.text("Back to Video") : L10n.text("Video Home")
            ) {
                model?.toggleHome()
            }
            .disabled(!session.videoNavigationAllowed)
            Button(L10n.text("Close Video")) {
                model?.closeVideo()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!session.videoCloseAllowed)
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

    private func changeVolume(by delta: Double) {
        if session.controlsMusic {
            session.music.setVolume(session.music.volume + delta)
        } else {
            model?.changeVolume(by: delta)
        }
    }

    private func seekButton(
        _ title: String, _ seconds: Double, _ key: KeyEquivalent, _ modifiers: EventModifiers
    ) -> some View {
        Button(title) {
            if session.controlsMusic {
                session.music.seek(session.music.displayedPosition + seconds)
            } else {
                model?.seek(by: seconds)
            }
        }
        .keyboardShortcut(key, modifiers: modifiers)
        .disabled(!session.canControl || (session.controlsMusic && !session.music.canSeek))
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
