import MusicCore
import SwiftUI

struct MusicIcon: View {
    let name: String
    var size: CGFloat = 16
    var body: some View {
        Image(name).resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct MusicHeart: View {
    let liked: Bool
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            MusicIcon(name: liked ? "SpotifySaved" : "SpotifyAdd")
                .foregroundStyle(liked ? Palette.ember : Palette.textTertiary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.format("Favorite: %@", title))
        .accessibilityValue(liked ? L10n.text("On") : L10n.text("Off"))
    }
}

struct TrackHeart: View {
    @Bindable var model: MusicViewModel
    let track: MusicTrack
    let anchor: String
    var labeled = false

    private var isPopoverPresented: Bool {
        model.likeOptionsAnchor == anchor && model.likeOptionsTrackID == track.id
    }

    var body: some View {
        Button {
            model.toggleTrack(track, anchor: anchor)
        } label: {
            HStack(spacing: 8) {
                MusicIcon(name: liked ? "SpotifySaved" : "SpotifyAdd")
                    .foregroundStyle(liked ? Palette.ember : Palette.textTertiary)
                if labeled { Text(L10n.text("Favorite")).foregroundStyle(Palette.textPrimary) }
            }
            .frame(minWidth: labeled ? 100 : 24, minHeight: labeled ? 36 : 24)
            .contentShape(Rectangle())
            .background(labeled ? Palette.glass : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if labeled { RoundedRectangle(cornerRadius: 8).stroke(Palette.strokeGlass) }
            }
        }
        .buttonStyle(.plain)
        .disabled(!model.canMutate)
        .accessibilityLabel(L10n.format("Favorite: %@", track.title))
        .accessibilityValue(liked ? L10n.text("On") : L10n.text("Off"))
        .background {
            if isPopoverPresented {
                Color.clear.popover(
                    isPresented: Binding(
                        get: { isPopoverPresented },
                        set: {
                            if !$0 {
                                model.likeOptionsTrackID = nil
                                model.likeOptionsAnchor = nil
                            }
                        }
                    ), arrowEdge: .bottom
                ) {
                    LikePopover(model: model, track: track)
                }
            }
        }
    }

    private var liked: Bool { model.library.likedTrackIDs.contains(track.id) }
}

struct MusicSwitch: View {
    let title: String
    let enabled: Bool
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle().fill(enabled ? Palette.ember : Palette.textTertiary).frame(
                    width: 5, height: 5
                )
                .shadow(color: enabled ? Palette.ember.opacity(0.65) : .clear, radius: 4)
                Text(title).lineLimit(1)
            }
            .font(.system(size: 12)).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10).frame(height: 36)
            .background(Palette.glass, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hairline))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Palette.textPrimary : Palette.textSecondary)
        .accessibilityLabel(title)
        .accessibilityValue(value ?? (enabled ? L10n.text("On") : L10n.text("Off")))
    }
}

struct MusicActionButton: View {
    let title: String
    var symbol = "play.fill"
    var primary = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .medium))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 14).frame(height: 36)
                .background(
                    primary ? Palette.textPrimary : Palette.glass,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hairline))
        }
        .buttonStyle(.plain).foregroundStyle(primary ? Palette.base : Palette.textPrimary)
    }
}
