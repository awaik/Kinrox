import MusicCore
import SwiftUI

struct DiscoverySkeletonRows: View {
    let count: Int
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        bar(width: [180, 140, 210, 160, 120, 190][index % 6], height: 10)
                        bar(width: [120, 160, 110, 140, 150, 100][index % 6], height: 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    bar(width: 30, height: 8)
                }
                .padding(.leading, 40)
                .padding(.trailing, 8)
                .frame(height: 42)
            }
        }
        .opacity(pulse ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityElement()
        .accessibilityLabel(L10n.text("Loading"))
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Palette.glassStrong)
            .frame(width: width, height: height)
    }
}

struct DiscoveryEmptyState: View {
    let hideLiked: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 20))
                .foregroundStyle(Palette.textTertiary)
            Text(L10n.text("Nothing similar found yet"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text(
                hideLiked
                    ? L10n.text("Try another mode, or show tracks you already like.")
                    : L10n.text("Try another mode or another seed track.")
            )
            .font(.system(size: 11))
            .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// Real playlists, compilations and albums related to the seed.
struct DiscoveryMixesStrip: View {
    @Bindable var model: MusicViewModel
    let mixes: [MusicDiscoveryMix]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Mixes & compilations"))
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(mixes) { mix in card(mix) }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.top, 14)
    }

    private func card(_ mix: MusicDiscoveryMix) -> some View {
        let tracks = mix.trackIDs.compactMap { model.catalog.track(id: $0) }
        return VStack(alignment: .leading, spacing: 4) {
            Text(mix.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            HStack(spacing: 10) {
                Text(mix.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    model.play(tracks)
                } label: {
                    MusicIcon(name: "MusicPlay", size: 9).foregroundStyle(Palette.flame)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(tracks.isEmpty || !model.canPlayLibrary)
                .accessibilityLabel(L10n.format("Play %@", mix.title))
                Button {
                    model.addTracksToQueue(tracks)
                } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.flame)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(tracks.isEmpty)
                .help(L10n.text("Add to queue"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 232, alignment: .leading)
        .background(Palette.glass, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.hairline))
    }
}

struct DiscoveryUndoToast: View {
    let message: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Button(L10n.text("Undo"), action: undo)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.flame)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.strokeGlass))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
    }
}
