import MusicCore
import SwiftUI

struct CollectionHeader: View {
    @Bindable var model: MusicViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(
                    model.album.map { L10n.text("Album") + " · " + $0.year }
                        ?? L10n.text("Library")
                )
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textTertiary)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .help(title)
                    .font(.system(size: 28, weight: .bold).width(.expanded))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !model.isQueue {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textTertiary)
                        TextField(L10n.text("Search"), text: $model.collectionFilterQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .onChange(of: model.collectionFilterQuery) { _, _ in
                                model.refreshContents()
                            }
                        if !model.collectionFilterQuery.isEmpty {
                            Button {
                                model.collectionFilterQuery = ""
                                model.refreshContents()
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
                    .frame(width: 180, height: 28)
                    .background(Palette.glass, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.strokeGlass))
                }
            }
            Text(
                model.album?.artistNames
                    ?? L10n.format("%@ tracks", model.contents.tracks.count.formatted())
            )
            .help(model.album?.artistNames ?? "")
            .font(.system(size: 15))
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(1)
            HStack(spacing: 8) {
                if !model.isQueue {
                    MusicActionButton(
                        title: model.album == nil ? L10n.text("Play all") : L10n.text("Play album"),
                        primary: true
                    ) {
                        model.play(model.contents.tracks)
                    }.disabled(!model.canPlayLibrary)
                }
                MusicActionButton(title: L10n.text("Shuffle"), symbol: "shuffle") {
                    model.shuffleCollection()
                }.disabled(
                    !model.allows("toggling_shuffle") || !model.canPlayLibrary)
                if !model.isQueue {
                    MusicActionButton(title: L10n.text("Add to queue"), symbol: "plus") {
                        model.addTracksToQueue(model.contents.tracks)
                    }.disabled(model.contents.tracks.isEmpty)
                    MusicActionButton(title: L10n.text("Similar"), symbol: "sparkles") {
                        openSimilarForCurrentCollection()
                    }
                }
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
                    }.buttonStyle(.plain).disabled(!model.canMutate)
                        .accessibilityLabel(L10n.format("Favorite: %@", album.title))
                        .accessibilityValue(
                            model.library.savedAlbumIDs.contains(album.id)
                                ? L10n.text("On") : L10n.text("Off"))
                }
                Spacer(minLength: 0)
            }.padding(.top, 8)
            if showsAlbumFilterBar {
                albumFilterBar
            }
        }
        .contextMenu {
            if let album = model.album {
                SpotifyContentLink(kind: "album", id: album.id)
            } else if case .playlist(let id) = model.selection.source {
                SpotifyContentLink(kind: "playlist", id: id)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var showsAlbumFilterBar: Bool {
        switch model.selection.source {
        case .artist, .search:
            return !model.contents.albums.isEmpty
        default:
            return false
        }
    }

    private var albumFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button {
                    model.selectAlbum(nil)
                } label: {
                    Text(L10n.text("All tracks"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(
                            model.selection.albumID == nil
                                ? Palette.textPrimary : Palette.textSecondary
                        )
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(
                            model.selection.albumID == nil ? Palette.glassStrong : Palette.glass,
                            in: Capsule())
                }
                .buttonStyle(.plain)

                ForEach(model.sortedAlbums) { item in
                    Button {
                        model.selectAlbum(item.id)
                    } label: {
                        Text(item.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(
                                model.selection.albumID == item.id
                                    ? Palette.flame : Palette.textSecondary
                            )
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(
                                model.selection.albumID == item.id
                                    ? Palette.ember.opacity(0.16) : Palette.glass,
                                in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 4)
    }

    private func openSimilarForCurrentCollection() {
        if let album = model.album {
            model.openSimilar(album: album)
        } else if case .playlist(let id) = model.selection.source,
            let playlist = model.library.playlists.first(where: { $0.id == id })
        {
            model.openSimilar(playlist: playlist)
        } else if case .artist(let id) = model.selection.source,
            let artist = model.catalog.artists.first(where: { $0.id == id })
        {
            model.openSimilar(artist: artist)
        } else {
            model.openSimilar(forTrack: model.contents.tracks.first)
        }
    }

    private var title: String {
        if let album = model.album { return album.title }
        switch model.selection.source {
        case .albums: return L10n.text("All albums")
        case .liked: return L10n.text("Liked tracks")
        case .queue: return L10n.text("Queue")
        case .similar: return L10n.text("Similar & discovery")
        case .playlist(let id):
            return model.library.playlists.first { $0.id == id }?.title ?? L10n.text("Playlists")
        case .artist(let id):
            return model.catalog.artists.first { $0.id == id }?.name ?? L10n.text("Artists")
        case .search(let query): return L10n.format("Search: %@", query)
        }
    }
}
