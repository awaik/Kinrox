import SwiftUI

/// Recent file card (Figma: `Card/Recent`).
struct RecentCard: View {
    let item: RecentItem
    let isAvailable: Bool
    let open: () -> Void
    let revealInFinder: () -> Void
    let remove: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(KinroxFont.bodyStrong)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.subtitle(available: isAvailable))
                        .font(KinroxFont.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isAvailable ? 1 : 0.38)
        .scaleEffect(isHovering && isAvailable ? 1.02 : 1)
        .animation(.spring(duration: 0.25), value: isHovering)
        .onHover { isHovering = $0 }
        .help(isAvailable ? item.path : L10n.format("File not found: %@", item.path))
        .contextMenu {
            if isAvailable {
                Button(L10n.text("Show in Finder"), action: revealInFinder)
            }
            Button(L10n.text("Remove from Recent"), role: .destructive, action: remove)
        }
    }

    private var artwork: some View {
        StillArtwork(seed: StillArtwork.seed(for: item.title))
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                if let duration = item.duration {
                    Text(TimeFormat.string(duration))
                        .font(KinroxFont.caption.monospacedDigit())
                        .foregroundStyle(Palette.textPrimary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                        .padding(10)
                }
            }
            .overlay {
                if isHovering && isAvailable {
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 48, height: 48)
                        .kinroxGlass(in: Circle())
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isHovering && isAvailable ? Palette.ember.opacity(0.7) : Palette.hairline,
                        lineWidth: 1))
    }
}
