import MusicCore
import SwiftUI

struct CollectionHeader: View {
    @Bindable var model: MusicViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.album.map { L10n.text("Album") + " · " + $0.year } ?? L10n.text("Library"))
                .font(.system(size: 10, weight: .semibold)).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(Palette.textTertiary)
            Text(title).help(title).font(.system(size: 28, weight: .bold).width(.expanded))
                .foregroundStyle(Palette.textPrimary).lineLimit(1)
            Text(
                model.album?.artistNames
                    ?? L10n.format("%@ tracks", model.contents.tracks.count.formatted())
            )
            .help(model.album?.artistNames ?? "")
            .font(.system(size: 15)).foregroundStyle(Palette.textSecondary).lineLimit(1)
            HStack(spacing: 8) {
                if !model.isQueue {
                    MusicActionButton(
                        title: model.album == nil ? L10n.text("Play all") : L10n.text("Play album"),
                        primary: true
                    ) {
                        model.play(model.contents.tracks)
                    }.disabled(!model.allows("interrupting_playback"))
                }
                MusicActionButton(title: L10n.text("Shuffle"), symbol: "shuffle") {
                    model.shuffleCollection()
                }.disabled(
                    !model.allows("toggling_shuffle") || !model.allows("interrupting_playback"))
                if let album = model.album {
                    Button {
                        model.toggleAlbum(album)
                    } label: {
                        HStack(spacing: 6) {
                            MusicIcon(
                                name: model.library.savedAlbumIDs.contains(album.id)
                                    ? "SpotifySaved" : "SpotifyAdd", size: 14
                            )
                            .foregroundStyle(
                                model.library.savedAlbumIDs.contains(album.id)
                                    ? Palette.ember : Palette.textSecondary)
                            Text(L10n.text("Favorite"))
                        }.padding(.horizontal, 12).frame(height: 36)
                            .background(Palette.glass, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(L10n.format("Favorite: %@", album.title))
                        .accessibilityValue(
                            model.library.savedAlbumIDs.contains(album.id)
                                ? L10n.text("On") : L10n.text("Off"))
                }
                Spacer(minLength: 0)
            }.padding(.top, 12)
        }.contextMenu {
            if let album = model.album {
                SpotifyContentLink(kind: "album", id: album.id)
            } else if case .playlist(let id) = model.selection.source {
                SpotifyContentLink(kind: "playlist", id: id)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        if let album = model.album { return album.title }
        switch model.selection.source {
        case .albums: return L10n.text("All albums")
        case .liked: return L10n.text("Liked tracks")
        case .queue: return L10n.text("Queue")
        case .playlist(let id):
            return model.library.playlists.first { $0.id == id }?.title ?? L10n.text("Playlists")
        case .artist(let id):
            return model.catalog.artists.first { $0.id == id }?.name ?? L10n.text("Artists")
        case .search(let query): return L10n.format("Search: %@", query)
        }
    }
}
