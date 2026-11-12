import MusicCore
import SwiftUI

/// Recommended track: reason is quiet grey text; actions appear on hover.
struct DiscoveryTrackRow: View {
    @Bindable var model: MusicViewModel
    let item: MusicDiscoveryItem
    let number: Int
    let play: () -> Void
    let hide: (String) -> Void
    @State private var hovered = false

    private var track: MusicTrack { item.track }
    private var playing: Bool { model.currentTrack?.id == track.id }
    private var focused: Bool {
        model.focusedColumn == .tracks && model.focusedTrackID == track.id
    }
    private var showsActions: Bool { hovered || focused || isFavoritePopoverOpen }
    private var playable: Bool { track.isPlayable != false && model.canPlayLibrary }
    private var isFavoritePopoverOpen: Bool {
        model.likeOptionsTrackID == track.id && model.likeOptionsAnchor == anchor
    }
    private var anchor: String { "discovery-\(track.id)" }

    var body: some View {
        rowContent
            .padding(.horizontal, 8)
            .frame(height: 42)
            .background(rowBackground)
            .opacity(track.isPlayable == false ? 0.45 : 1)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture(count: 2) {
                if playable { play() }
            }
            .draggable("track:\(track.id)")
            .contextMenu { menuItems }
            .modifier(accessibility)
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            leading.frame(width: 22, alignment: .trailing)
            titles.frame(maxWidth: .infinity, alignment: .leading)
            trailing
            Text(TimeFormat.string(track.duration))
                .font(KinroxFont.monoDigits(12))
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var leading: some View {
        if hovered {
            Button(action: play) {
                MusicIcon(name: "MusicPlay", size: 10).foregroundStyle(Palette.textPrimary)
            }
            .buttonStyle(.plain)
            .disabled(!playable)
            .accessibilityLabel(L10n.format("Play %@", track.title))
        } else {
            Text(number.formatted())
                .font(KinroxFont.monoDigits(12))
                .foregroundStyle(playing ? Palette.flame : Palette.textTertiary)
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if track.explicit == true { SpotifyExplicitBadge() }
                Text(track.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(playing ? Palette.flame : Palette.textPrimary)
                    .lineLimit(1)
            }
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
        }
    }

    /// Actions stay mounted so an open "…" menu survives the pointer leaving the row.
    private var trailing: some View {
        ZStack(alignment: .trailing) {
            if let reason = item.primaryReason {
                DiscoveryReasonLabel(reason: reason, hovered: hovered).opacity(showsActions ? 0 : 1)
            }
            actions
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
                .accessibilityHidden(!showsActions)
        }
    }

    private var rowBackground: some View {
        let highlighted = playing || hovered || focused
        return RoundedRectangle(cornerRadius: 8)
            .fill(highlighted ? Palette.glass : Color.clear)
            .overlay {
                if focused { RoundedRectangle(cornerRadius: 8).stroke(Palette.strokeGlass) }
            }
    }

    private var accessibility: DiscoveryRowAccessibility {
        DiscoveryRowAccessibility(
            label: "\(track.title), \(track.artistNames)",
            hint: item.primaryReason.map { DiscoveryReasonLabel.text(for: $0) } ?? "",
            play: { if playable { play() } },
            queue: { model.addToQueue(track) },
            similar: { model.openSimilar(forTrack: track) },
            favorite: { model.toggleTrack(track, anchor: anchor) },
            hide: hideTrack)
    }

    private func hideTrack() {
        model.notInterested(track: track)
        hide(L10n.format("Hidden “%@” from Similar", track.title))
    }

    private var subtitle: String {
        track.albumTitle.isEmpty ? track.artistNames : "\(track.artistNames) · \(track.albumTitle)"
    }

    private var actions: some View {
        HStack(spacing: 4) {
            iconButton("plus", L10n.text("Add to queue")) { model.addToQueue(track) }
                .disabled(track.isPlayable == false)
            TrackHeart(model: model, track: track, anchor: anchor)
                .frame(width: 26, height: 26)
                .background(Palette.glassStrong, in: RoundedRectangle(cornerRadius: 6))
            iconButton("sparkles", L10n.text("More like this")) {
                model.openSimilar(forTrack: track)
            }
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .hoverHelp(L10n.text("More"), active: showsActions)
                    .frame(width: 26, height: 26)
                    .background(Palette.glassStrong, in: RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel(L10n.text("More"))
            .fixedSize()
            .foregroundStyle(Palette.textPrimary)
        }
    }

    private func iconButton(
        _ symbol: String, _ label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 26, height: 26)
                .background(Palette.glassStrong, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .hoverHelp(label, active: showsActions)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(L10n.text("Play"), action: play).disabled(!playable)
        Button(L10n.text("Add to queue")) { model.addToQueue(track) }
            .disabled(track.isPlayable == false)
        Button(L10n.text("More like this")) { model.openSimilar(forTrack: track) }
        Divider()
        Button(L10n.text("Not interested in this track"), action: hideTrack)
        if let artist = track.artists.first {
            Button(L10n.format("Not interested in %@", artist.name)) {
                model.notInterested(artist: artist)
                hide(L10n.format("Hidden %@ from Similar", artist.name))
            }
        }
        Divider()
        SpotifyContentLink(kind: "track", id: track.id)
    }
}

/// Grey, icon-led explanation of why a track was recommended.
struct DiscoveryReasonLabel: View {
    let reason: MusicDiscoveryReason
    var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Self.symbol(for: reason.kind))
                .font(.system(size: 9, weight: .semibold))
            Text(Self.text(for: reason)).lineLimit(1)
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.textTertiary)
        .fixedSize()
        .hoverHelp(Self.text(for: reason, shortened: false), active: hovered)
    }

    static func symbol(for kind: MusicDiscoveryReasonKind) -> String {
        switch kind {
        case .listenBrainzRecording, .listenBrainzArtist: "person.2.wave.2"
        case .collaborator, .remixer: "arrow.left.arrow.right"
        case .compilation: "square.stack"
        case .ownPlaylist: "music.note.list"
        case .likedSameDay: "calendar"
        case .playHistory: "clock.arrow.circlepath"
        case .sharedGenre: "number"
        case .freshRelease: "sparkle"
        case .underground: "eye.slash"
        }
    }

    /// Long details (playlist or compilation names) are shortened so titles keep the space.
    static func text(for reason: MusicDiscoveryReason, shortened: Bool = true) -> String {
        let detail =
            shortened && reason.detail.count > 28
            ? String(reason.detail.prefix(27)) + "…" : reason.detail
        switch reason.kind {
        case .listenBrainzRecording:
            return L10n.text("Often played together")
        case .listenBrainzArtist:
            return L10n.text("Similar artist")
        case .collaborator:
            return L10n.format("Collaborator: %@", detail)
        case .remixer:
            return L10n.format("Remixer: %@", detail)
        case .compilation:
            return L10n.format("Compilation: %@", detail)
        case .ownPlaylist:
            return reason.matchCount > 1
                ? L10n.format("In %@ of your playlists", reason.matchCount.formatted())
                : L10n.format("In your playlist %@", detail)
        case .likedSameDay:
            return L10n.text("Liked the same day")
        case .playHistory:
            return L10n.text("You often play it next")
        case .sharedGenre:
            return L10n.format("Genre: %@", detail)
        case .freshRelease:
            return L10n.text("New release")
        case .underground:
            return L10n.text("Under the radar")
        }
    }
}

/// VoiceOver label and custom actions for a discovery row (hover actions are hidden from it).
struct DiscoveryRowAccessibility: ViewModifier {
    let label: String
    let hint: String
    let play: () -> Void
    let queue: () -> Void
    let similar: () -> Void
    let favorite: () -> Void
    let hide: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityHint(hint)
            .accessibilityAction(named: L10n.text("Play"), play)
            .accessibilityAction(named: L10n.text("Add to queue"), queue)
            .accessibilityAction(named: L10n.text("More like this"), similar)
            .accessibilityAction(named: L10n.text("Favorite"), favorite)
            .accessibilityAction(named: L10n.text("Not interested in this track"), hide)
    }
}
