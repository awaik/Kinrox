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
            // Figma `239:596`: the Connect iPhone sheet carries the remote's QR code.
            Button(L10n.text("Kinrox Remote for iPhone…")) {
                guard let model, !model.isScreensaverEngaged else {
                    RemoteAppLink.open()
                    return
                }
                session.mode = .video
                model.isShowingConnectPhone = true
            }
            Divider()
            ForEach(ProjectLink.allCases) { link in
                Button(link.title) { NSWorkspace.shared.open(link.url) }
            }
        }
        TrackCommands(session: session)
        CommandGroup(after: .toolbar) {
            Button(L10n.text("Home"), action: session.selectHome)
                .keyboardShortcut("1", modifiers: .command)
            Button("Spotify") { session.mode = .music }
                .keyboardShortcut("2", modifiers: .command)
            if session.mode == .music {
                Button(L10n.text("Refresh list")) { session.music.syncLibrary() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(session.music.isLoading || session.music.isMutating)
            } else if session.isOnHome {
                Button(L10n.text("Check Now")) {
                    session.mediaLibrary.rescanAll(refreshMetadata: true)
                }
                .keyboardShortcut("r", modifiers: .command)
                Button(L10n.text("Search Library")) { session.focusHomeSearch() }
                    .keyboardShortcut("f", modifiers: .command)
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
                transportPaused ? L10n.text("Play") : L10n.text("Pause")
            ) {
                switch session.activeControlTarget {
                case .music: session.music.togglePause()
                case .localAudio: session.localAudio.togglePause()
                case .video: model?.togglePause()
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
                session.activeControlTarget == .video
                    ? L10n.text("Previous File") : L10n.text("Previous track")
            ) {
                moveTrack(next: false)
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!canMoveTrack(next: false))
            Button(
                session.activeControlTarget == .video
                    ? L10n.text("Next File") : L10n.text("Next track")
            ) {
                moveTrack(next: true)
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!canMoveTrack(next: true))
            Divider()
            Button(L10n.text("Louder")) { changeVolume(by: PlayerViewModel.volumeStep) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(
                    session.controlsMusic
                        ? (!session.unmodifiedShortcutsAllowed || !session.music.canAdjustVolume)
                        : !session.canControl)
            Button(L10n.text("Quieter")) { changeVolume(by: -PlayerViewModel.volumeStep) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(
                    session.controlsMusic
                        ? (!session.unmodifiedShortcutsAllowed || !session.music.canAdjustVolume)
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

    private var transportPaused: Bool {
        switch session.activeControlTarget {
        case .music: session.music.paused
        case .localAudio: session.localAudio.paused
        case .video: model?.paused != false
        }
    }

    private func canMoveTrack(next: Bool) -> Bool {
        guard session.unmodifiedShortcutsAllowed else { return false }
        switch session.activeControlTarget {
        case .music: return next ? session.music.canNext : session.music.canPrevious
        case .localAudio: return next ? session.localAudio.canNext : session.localAudio.canPrevious
        case .video: return (next ? model?.canNext : model?.canPrevious) == true
        }
    }

    private func moveTrack(next: Bool) {
        switch session.activeControlTarget {
        case .music:
            if next { session.music.next() } else { session.music.previous() }
        case .localAudio:
            if next { session.localAudio.next() } else { session.localAudio.previous() }
        case .video:
            if next { model?.next() } else { model?.previous() }
        }
    }

    private func changeVolume(by delta: Double) {
        switch session.activeControlTarget {
        case .music: session.music.setVolume(session.music.volume + delta)
        case .localAudio: session.localAudio.setVolume(session.localAudio.volume + delta)
        case .video: model?.changeVolume(by: delta)
        }
    }

    private func seekButton(
        _ title: String, _ seconds: Double, _ key: KeyEquivalent, _ modifiers: EventModifiers
    ) -> some View {
        Button(title) {
            switch session.activeControlTarget {
            case .music: session.music.seek(session.music.displayedPosition + seconds)
            case .localAudio: session.localAudio.seek(session.localAudio.position + seconds)
            case .video: model?.seek(by: seconds)
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
