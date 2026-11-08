import MusicCore
import SwiftUI

struct DiscoveryWorkspaceView: View {
    @Bindable var model: MusicViewModel

    private var snapshot: MusicDiscoverySnapshot {
        model.discoverySnapshot
            ?? MusicDiscoveryEngine.build(catalog: model.catalog, library: model.library)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            MusicServiceStatus(model: model)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !snapshot.mixes.isEmpty {
                        mixesSection
                    }
                    tracksSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .background(Palette.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Similar & discovery"))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.flame)
                Text(L10n.text("Similar & discovery"))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.flame)
                if !snapshot.seedTitle.isEmpty {
                    Text("· \(snapshot.seedTitle)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(
                    snapshot.seedTitle.isEmpty
                        ? L10n.text("Similar & discovery") : snapshot.seedTitle
                )
                .font(.system(size: 24, weight: .bold).width(.expanded))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                Spacer(minLength: 0)
                MusicActionButton(title: L10n.text("Play all"), primary: true) {
                    model.play(snapshot.tracks)
                }
                .disabled(!model.canPlayLibrary || snapshot.tracks.isEmpty)
                MusicActionButton(title: L10n.text("Add to queue"), symbol: "plus") {
                    model.addTracksToQueue(snapshot.tracks)
                }
                .disabled(snapshot.tracks.isEmpty)
            }

            HStack(spacing: 6) {
                modePill(.sameSpirit, title: L10n.text("Same spirit"))
                modePill(.underground, title: L10n.text("Underground"))
                modePill(.fresh, title: L10n.text("Fresh"))

                Divider().frame(height: 18)

                Button {
                    model.toggleDiscoveryHideLiked()
                } label: {
                    HStack(spacing: 4) {
                        Image(
                            systemName: model.discoveryHideLiked
                                ? "checkmark.square.fill" : "square"
                        )
                        .font(.system(size: 11))
                        Text(L10n.text("Hide liked"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(
                        model.discoveryHideLiked ? Palette.flame : Palette.textSecondary
                    )
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(
                        model.discoveryHideLiked ? Palette.ember.opacity(0.16) : Palette.glass,
                        in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                if !snapshot.genres.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(snapshot.genres, id: \.self) { genre in
                                let active = model.discoverySelectedGenre == genre
                                Button {
                                    model.setDiscoveryGenre(genre)
                                } label: {
                                    Text("#\(genre)")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(
                                            active ? Palette.flame : Palette.textSecondary
                                        )
                                        .padding(.horizontal, 8)
                                        .frame(height: 24)
                                        .background(
                                            active ? Palette.ember.opacity(0.18) : Palette.glass,
                                            in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private func modePill(_ mode: MusicDiscoveryMode, title: String) -> some View {
        let active = model.discoveryMode == mode
        return Button {
            model.setDiscoveryMode(mode)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? Palette.textPrimary : Palette.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    active ? Palette.glassStrong : Palette.glass,
                    in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var mixesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Mixes & compilations"))
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textTertiary)
            HStack(spacing: 10) {
                ForEach(snapshot.mixes) { mix in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(mix.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                        Text(mix.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Button {
                                let tracks = mix.trackIDs.compactMap { model.catalog.track(id: $0) }
                                model.play(tracks)
                            } label: {
                                HStack(spacing: 4) {
                                    MusicIcon(name: "MusicPlay", size: 9)
                                    Text(L10n.text("Play"))
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(Palette.base)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(Palette.ember, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)

                            Button {
                                let tracks = mix.trackIDs.compactMap { model.catalog.track(id: $0) }
                                model.addTracksToQueue(tracks)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 9, weight: .bold))
                                    Text(L10n.text("Queue"))
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(Palette.textPrimary)
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                                .background(
                                    Palette.glassStrong, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 2)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.glass, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.strokeGlass))
                }
            }
        }
    }

    @ViewBuilder
    private var tracksSection: some View {
        HStack {
            Text(L10n.text("Recommended tracks"))
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textTertiary)
            Spacer()
            Text(L10n.text("Why this track"))
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, 8)

        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(Array(snapshot.items.enumerated()), id: \.element.id) { index, item in
                DiscoveryTrackRow(
                    model: model,
                    item: item,
                    index: index,
                    reasonText: reasonDescription(for: item)
                ) {
                    model.play(snapshot.tracks, at: index)
                }
            }
        }

        if snapshot.items.isEmpty {
            Text(L10n.text("No results"))
                .foregroundStyle(Palette.textSecondary)
                .padding(24)
        }
    }

    private func reasonDescription(for item: MusicDiscoveryItem) -> String {
        switch item.reasonKind {
        case .playlistCooccurrence:
            return L10n.format(
                "In %@ playlists: %@",
                item.matchCount.formatted(),
                item.contextName)
        case .compilation:
            return L10n.format("Compilation: %@", item.contextName)
        case .underground:
            return L10n.text("Underground · tag:hipster")
        case .freshRelease:
            return L10n.text("Fresh release · tag:new")
        case .sharedGenre:
            return L10n.format("Genre: %@", item.contextName)
        case .sharedArtist:
            return L10n.format("Artist: %@", item.contextName)
        }
    }
}

private struct DiscoveryTrackRow: View {
    @Bindable var model: MusicViewModel
    let item: MusicDiscoveryItem
    let index: Int
    let reasonText: String
    let play: () -> Void
    @State private var hovered = false

    private var track: MusicTrack { item.track }
    private var playing: Bool { model.currentTrack?.id == track.id }

    var body: some View {
        HStack(spacing: 10) {
            Text((index + 1).formatted())
                .font(KinroxFont.monoDigits(12))
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 24, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if track.explicit == true { SpotifyExplicitBadge() }
                    Text(track.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(playing ? Palette.flame : Palette.textPrimary)
                        .lineLimit(1)
                }
                Text("\(track.artistNames) · \(track.albumTitle)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(reasonText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.flame)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Palette.ember.opacity(0.14), in: Capsule())

            Button {
                model.addToQueue(track)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                    Text(L10n.text("Queue"))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Palette.glassStrong, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            TrackHeart(
                model: model,
                track: track,
                anchor: "discovery-\(index)"
            )

            Text(TimeFormat.string(track.duration))
                .font(KinroxFont.monoDigits(12))
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(
            playing || hovered ? Palette.glass : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) {
            if track.isPlayable != false { play() }
        }
        .draggable("track:\(track.id)")
        .contextMenu {
            Button(L10n.text("Play"), action: play)
            Button(L10n.text("Add to queue")) { model.addToQueue(track) }
            Button(L10n.text("Similar")) { model.openSimilar(forTrack: track) }
            Divider()
            SpotifyContentLink(kind: "track", id: track.id)
        }
    }
}
