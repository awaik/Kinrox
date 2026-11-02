import MusicCore
import SwiftUI

struct SourceColumn: View {
    @Bindable var model: MusicViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if !model.query.isEmpty {
                    heading(L10n.text("Search"))
                    row(
                        .search(model.query), title: model.query, symbol: "magnifyingglass",
                        count: model.contents.tracks.count)
                }
                heading(L10n.text("Library"))
                row(
                    .liked, title: L10n.text("Liked tracks"), symbol: "checkmark.circle.fill",
                    count: model.library.likedTrackIDs.count)
                row(
                    .albums, title: L10n.text("All albums"), symbol: "opticaldisc",
                    count: model.library.savedAlbumIDs.count)
                row(
                    .queue, title: L10n.text("Queue"), symbol: "list.bullet",
                    count: model.queue.items.count)
                heading(L10n.text("Playlists"))
                ForEach(model.library.playlists) { playlist in
                    row(
                        .playlist(playlist.id), title: playlist.title,
                        count: playlist.trackIDs.count)
                }
                heading(L10n.text("Artists"))
                ForEach(model.catalog.artists) { artist in
                    HStack(spacing: 4) {
                        Button {
                            model.focusedColumn = .source
                            model.select(.artist(artist.id))
                        } label: {
                            Text(artist.name).help(artist.name).lineLimit(1).frame(
                                maxWidth: .infinity, alignment: .leading
                            )
                            .frame(height: 30).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        MusicHeart(
                            liked: model.library.followedArtistIDs.contains(artist.id),
                            title: artist.name
                        ) {
                            model.toggleArtist(artist)
                        }.disabled(!model.canMutate)
                    }.padding(.horizontal, 10)
                        .background(
                            model.selection.source == .artist(artist.id)
                                ? Palette.glassStrong : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                }
            }.padding(.horizontal, 8).padding(.bottom, 16)
        }
        .font(.system(size: 13)).foregroundStyle(Palette.textPrimary).background(Palette.canvas)
        .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("Library"))
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.8).textCase(.uppercase)
            .foregroundStyle(Palette.textTertiary).padding(.top, 20).padding(.bottom, 8).padding(
                .leading, 10)
    }

    private func row(_ source: MusicSource, title: String, symbol: String? = nil, count: Int)
        -> some View
    {
        Button {
            model.focusedColumn = .source
            model.select(source)
        } label: {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).frame(width: 14) }
                Text(title).help(title).lineLimit(1)
                Spacer(minLength: 4)
                Text(count.formatted()).monospacedDigit().foregroundStyle(Palette.textTertiary)
            }.padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
                .background(
                    model.selection.source == source ? Palette.glassStrong : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).contextMenu {
            if case .playlist(let id) = source { SpotifyContentLink(kind: "playlist", id: id) }
        }.accessibilityAddTraits(
            model.selection.source == source ? .isSelected : [])
    }
}

struct MusicSourcePicker: View {
    @Bindable var model: MusicViewModel
    var body: some View {
        Picker(
            L10n.text("Library"),
            selection: Binding(
                get: { model.selection.source }, set: { model.select($0) }
            )
        ) {
            Text(L10n.text("Liked tracks")).tag(MusicSource.liked)
            Text(L10n.text("All albums")).tag(MusicSource.albums)
            Text(L10n.text("Queue")).tag(MusicSource.queue)
            ForEach(model.library.playlists) { Text($0.title).tag(MusicSource.playlist($0.id)) }
            ForEach(model.catalog.artists) { Text($0.name).tag(MusicSource.artist($0.id)) }
            if !model.query.isEmpty { Text(model.query).tag(MusicSource.search(model.query)) }
        }.labelsHidden().pickerStyle(.menu).controlSize(.large).padding(8)
    }
}
