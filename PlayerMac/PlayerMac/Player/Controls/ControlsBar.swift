import SwiftUI

/// Glass control bar at bottom of window (Figma: Controls · Liquid Glass).
struct ControlsBar: View {
    let model: PlayerViewModel
    let recents: RecentFilesStore?
    let overlay: OverlayController
    let actions: PlayerActions
    @State private var showsPlaylist = false
    @State private var showsRecents = false

    var body: some View {
        VStack(spacing: 14) {
            Scrubber(model: model, overlay: overlay)
            HStack(spacing: 0) {
                VolumeControl(model: model)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 18) {
                    IconButton(
                        systemName: "backward.end.fill", help: L10n.text("Previous file (⌘←)"),
                        isEnabled: model.canPrevious
                    ) { model.previous() }
                    PlayPauseButton(paused: model.paused) { model.togglePause() }
                    IconButton(
                        systemName: "forward.end.fill", help: L10n.text("Next file (⌘→)"),
                        isEnabled: model.canNext
                    ) { model.next() }
                }
                .environment(\.layoutDirection, .leftToRight)
                HStack(spacing: 4) {
                    IconButton(systemName: "list.bullet", help: L10n.text("Files in folder")) {
                        showsPlaylist.toggle()
                    }
                    .popover(isPresented: $showsPlaylist, arrowEdge: .top) { playlistPopover }
                    IconButton(systemName: "clock.arrow.circlepath", help: L10n.text("Recent")) {
                        recents?.refreshAvailability()
                        showsRecents.toggle()
                    }
                    .popover(isPresented: $showsRecents, arrowEdge: .top) { recentsPopover }
                    IconButton(
                        systemName: model.isFullscreen
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right",
                        help: model.isFullscreen
                            ? L10n.text("Exit Full Screen (F)") : L10n.text("Full Screen (F)")
                    ) { model.toggleFullscreen() }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
        // Dark backing maintains contrast on bright frames.
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 32))
        .kinroxGlass(in: RoundedRectangle(cornerRadius: 32))
        .onHover { overlay.set(.hover, active: $0) }
        .onChange(of: showsPlaylist || showsRecents) { _, open in
            overlay.set(.popover, active: open)
        }
    }

    private var playlistPopover: some View {
        let items = model.playlist?.items ?? []
        let current = model.playlist?.index
        return MediaListPopover(
            title: model.playlist.map { L10n.format("Folder “%@”", $0.folderName) }
                ?? L10n.text("Folder"),
            emptyText: L10n.text("No other videos in folder."), isEmpty: items.count < 2
        ) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, url in
                MediaListRow(
                    title: url.lastPathComponent, subtitle: "", isCurrent: index == current
                ) {
                    showsPlaylist = false
                    if index != current { actions.open(url) }
                }
            }
        }
    }

    private var recentsPopover: some View {
        let items = recents?.items ?? []
        return MediaListPopover(
            title: L10n.text("Recent"), emptyText: L10n.text("Opened videos will appear here."),
            isEmpty: items.isEmpty
        ) {
            ForEach(items) { item in
                let available = !(recents?.unavailable.contains(item.id) ?? false)
                MediaListRow(
                    title: item.title, subtitle: item.subtitle(available: available),
                    isCurrent: VideoFiles.key(URL(fileURLWithPath: item.path))
                        == model.currentURL.map(VideoFiles.key),
                    isAvailable: available
                ) {
                    showsRecents = false
                    actions.openRecent(item)
                }
            }
        }
    }
}
