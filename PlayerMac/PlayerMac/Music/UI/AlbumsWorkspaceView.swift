import MusicCore
import SwiftUI

struct AlbumsWorkspaceView: View {
    @Bindable var model: MusicViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            MusicServiceStatus(model: model)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.overviewAlbums) { album in
                        AlbumWorkspaceCard(model: model, album: album)
                    }
                    if model.overviewAlbums.isEmpty, model.statusMessage == nil {
                        Text(L10n.text("No results"))
                            .foregroundStyle(Palette.textSecondary)
                            .padding(32)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(Palette.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("All albums"))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Library"))
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(L10n.text("All albums"))
                    .font(.system(size: 28, weight: .bold).width(.expanded))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(model.overviewAlbums.count.formatted())
                    .font(KinroxFont.monoDigits(14))
                    .foregroundStyle(Palette.textTertiary)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                pill(
                    title: L10n.text("Saved"),
                    active: model.albumsFilterSavedOnly
                ) {
                    model.albumsFilterSavedOnly = true
                }
                pill(
                    title: L10n.text("All"),
                    active: !model.albumsFilterSavedOnly
                ) {
                    model.albumsFilterSavedOnly = false
                }
                Button {
                    model.sortAlbumsByArtist.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(
                            model.sortAlbumsByArtist
                                ? L10n.text("By artist") : L10n.text("By title"))
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 10))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Palette.glass, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                    TextField(L10n.text("Search"), text: $model.collectionFilterQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !model.collectionFilterQuery.isEmpty {
                        Button {
                            model.collectionFilterQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("Clear search"))
                    }
                }
                .padding(.horizontal, 10)
                .frame(width: 200, height: 30)
                .background(Palette.glass, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.strokeGlass))
            }
        }
        .padding(20)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private func pill(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? Palette.textPrimary : Palette.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(
                    active ? Palette.glassStrong : Palette.glass,
                    in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct AlbumWorkspaceCard: View {
    @Bindable var model: MusicViewModel
    let album: MusicAlbum
    @State private var hoveredTrack = MusicRowHoverState()

    private var isExpanded: Bool {
        model.expandedAlbumCardIDs.contains(album.id)
    }

    private var isPlayingAlbum: Bool {
        model.currentTrack?.albumID == album.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    if isPlayingAlbum && !model.paused {
                        model.togglePause()
                    } else {
                        model.playAlbum(album)
                    }
                } label: {
                    MusicIcon(
                        name: isPlayingAlbum && !model.paused ? "MusicPause" : "MusicPlay",
                        size: 12
                    )
                    .frame(width: 32, height: 32)
                    .foregroundStyle(
                        isPlayingAlbum && !model.paused ? Palette.base : Palette.textPrimary
                    )
                    .background(
                        isPlayingAlbum && !model.paused ? Palette.ember : Palette.glass,
                        in: Circle()
                    )
                    .overlay(Circle().stroke(Palette.strokeGlass))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.format("Play album: %@", album.title))

                Button {
                    model.selectAlbum(album.id)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(album.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isPlayingAlbum ? Palette.flame : Palette.textPrimary)
                            .lineLimit(1)
                        Text(
                            "\(album.artistNames) · \(album.year) · "
                                + L10n.format("%@ tracks", album.totalTrackCount.formatted())
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    model.insertAlbumInQueue(album)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text(L10n.text("Add to queue"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Palette.glassStrong, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Button {
                    model.openSimilar(album: album)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                        Text(L10n.text("Similar"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Palette.flame)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Palette.ember.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                MusicHeart(
                    liked: model.library.savedAlbumIDs.contains(album.id),
                    title: album.title
                ) {
                    model.toggleAlbum(album)
                }
                .disabled(!model.canMutate)

                Button {
                    model.toggleAlbumCardExpansion(album.id)
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isExpanded ? L10n.text("Collapse") : L10n.text("Tracks"))
            }
            .padding(12)

            if isExpanded {
                let tracks = model.catalog.tracks(in: album)
                Rectangle().fill(Palette.hairline).frame(height: 1)
                LazyVStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        HStack(spacing: 10) {
                            Text((index + 1).formatted())
                                .font(KinroxFont.monoDigits(11))
                                .foregroundStyle(Palette.textTertiary)
                                .frame(width: 24, alignment: .trailing)
                            Text(track.title)
                                .font(.system(size: 12))
                                .foregroundStyle(
                                    model.currentTrack?.id == track.id
                                        ? Palette.flame : Palette.textPrimary
                                )
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                model.addToQueue(track)
                            } label: {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.textSecondary)
                                    .hoverHelp(
                                        L10n.text("Add to queue"),
                                        active: hoveredTrack.id == track.id)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.text("Add to queue"))
                            Text(TimeFormat.string(track.duration))
                                .font(KinroxFont.monoDigits(11))
                                .foregroundStyle(Palette.textTertiary)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            model.play(tracks, at: index)
                        }
                        .onHover { hoveredTrack.update(track.id, hovering: $0) }
                        .draggable("track:\(track.id)")
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(Palette.glass, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.strokeGlass))
        .draggable("album:\(album.id)")
        .contextMenu {
            Button(L10n.text("Play album")) { model.playAlbum(album) }
            Button(L10n.text("Add to queue")) { model.insertAlbumInQueue(album) }
            Button(L10n.text("Similar")) { model.openSimilar(album: album) }
            Divider()
            SpotifyContentLink(kind: "album", id: album.id)
        }
    }
}
