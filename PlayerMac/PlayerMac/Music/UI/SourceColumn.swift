import MusicCore
import SwiftUI

struct SourceColumn: View {
    @Bindable var model: MusicViewModel

    var body: some View {
        VStack(spacing: 0) {
            if model.leftSection != .home {
                expandedHeader
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    switch model.leftSection {
                    case .home: homeContent
                    case .playlists:
                        ForEach(model.filteredLeftPlaylists) { playlistRow($0) }
                    case .artists:
                        ForEach(model.filteredLeftArtists) { artistRow($0) }
                    case .albums:
                        ForEach(model.filteredLeftAlbums) { albumRow($0) }
                    }
                }.padding(.horizontal, 8).padding(.vertical, 10)
            }
        }
        .font(.system(size: 13)).foregroundStyle(Palette.textPrimary).background(Palette.canvas)
        .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("Library"))
    }

    private var expandedHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.collapseLeftSection()
            } label: {
                HStack(spacing: 6) {
                    Text(L10n.text("‹ Back to library"))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.flame)
                    Spacer(minLength: 4)
                    Text("Esc").font(KinroxFont.monoDigits(10)).foregroundStyle(
                        Palette.textTertiary)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(Palette.glassStrong, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.strokeGlass))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)

            HStack(spacing: 6) {
                Text(expandedSectionTitle)
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 4)
                Text(expandedSectionCount.formatted())
                    .font(KinroxFont.monoDigits(11)).foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(Palette.glass, in: Capsule())
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(
                    Palette.textTertiary)
                TextField(L10n.text("Search"), text: $model.leftFilterQuery)
                    .textFieldStyle(.plain).font(.system(size: 12))
                if !model.leftFilterQuery.isEmpty {
                    Button {
                        model.leftFilterQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                            .foregroundStyle(Palette.textTertiary)
                    }.buttonStyle(.plain).accessibilityLabel(L10n.text("Clear search"))
                }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(Palette.glass, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.strokeGlass))

            if model.leftSection == .playlists {
                playlistFilters
            } else if model.leftSection == .albums {
                albumFilters
            }
        }
        .padding(10).background(Palette.elevated.opacity(0.6))
    }

    private var playlistFilters: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                filterPill(title: L10n.text("All"), active: model.playlistFilter == .all) {
                    model.playlistFilter = .all
                }
                filterPill(title: L10n.text("Mine"), active: model.playlistFilter == .mine) {
                    model.playlistFilter = .mine
                }
                filterPill(
                    title: L10n.text("Subscribed"), active: model.playlistFilter == .subscribed
                ) {
                    model.playlistFilter = .subscribed
                }
            }
            Text(L10n.text("Themes")).font(.system(size: 9, weight: .semibold)).tracking(0.7)
                .textCase(.uppercase).foregroundStyle(Palette.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(MusicViewModel.playlistThemes, id: \.self) { theme in
                        let selected = model.selectedPlaylistTheme == theme
                        Button {
                            model.selectPlaylistTheme(theme)
                        } label: {
                            Text(theme).font(.system(size: 11, weight: .medium))
                                .foregroundStyle(selected ? Palette.flame : Palette.textSecondary)
                                .padding(.horizontal, 8).frame(height: 22)
                                .background(
                                    selected ? Palette.ember.opacity(0.18) : Palette.glass,
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule().stroke(
                                        selected ? Palette.ember.opacity(0.5) : Palette.hairline))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var albumFilters: some View {
        HStack(spacing: 4) {
            filterPill(title: L10n.text("Saved"), active: model.albumsFilterSavedOnly) {
                model.albumsFilterSavedOnly = true
            }
            filterPill(title: L10n.text("All"), active: !model.albumsFilterSavedOnly) {
                model.albumsFilterSavedOnly = false
            }
            Spacer(minLength: 4)
            Button {
                model.sortAlbumsByArtist.toggle()
            } label: {
                Text(model.sortAlbumsByArtist ? L10n.text("By artist") : L10n.text("By title"))
                    .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
            }.buttonStyle(.plain)
        }
    }

    private func filterPill(title: String, active: Bool, action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Palette.textPrimary : Palette.textSecondary)
                .padding(.horizontal, 8).frame(height: 24)
                .background(
                    active ? Palette.glassStrong : Palette.glass,
                    in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private var homeContent: some View {
        if !model.query.isEmpty {
            heading(L10n.text("Search"))
            row(
                .search(model.query), title: model.query, symbol: "magnifyingglass",
                count: model.contents.tracks.count)
        }
        heading(L10n.text("Library"))
        row(
            .similar, title: L10n.text("Similar & discovery"), symbol: "sparkles",
            count: model.discoverySnapshot?.items.count ?? model.catalog.tracks.count,
            accent: true
        ) {
            model.focusedColumn = .source
            model.openSimilar()
        }
        row(
            .liked, title: L10n.text("Liked tracks"), symbol: "checkmark.circle.fill",
            count: model.library.likedTrackIDs.count)
        HStack(spacing: 4) {
            Button {
                model.focusedColumn = .source
                model.openAlbumsOverview()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "opticaldisc").frame(width: 14)
                    Text(L10n.text("All albums")).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(model.library.savedAlbumIDs.count.formatted())
                        .monospacedDigit().foregroundStyle(Palette.textTertiary)
                }
                .padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(
                model.selection.source == .albums && model.isAlbumsOverview ? .isSelected : [])
            Button {
                model.expandLeftSection(.albums)
            } label: {
                Text(L10n.text("Show all  →")).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.flame).padding(.horizontal, 6).frame(height: 24)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .background(
            model.selection.source == .albums && model.isAlbumsOverview
                ? Palette.glassStrong : .clear,
            in: RoundedRectangle(cornerRadius: 6))

        sectionHeader(L10n.text("Playlists"), count: model.library.playlists.count) {
            model.expandLeftSection(.playlists)
        }
        ForEach(model.library.playlists.prefix(6)) { playlistRow($0) }

        sectionHeader(L10n.text("Artists"), count: model.catalog.artists.count) {
            model.expandLeftSection(.artists)
        }
        ForEach(model.catalog.artists.prefix(6)) { artistRow($0) }
    }

    private func albumRow(_ album: MusicAlbum) -> some View {
        HStack(spacing: 6) {
            Button {
                model.focusedColumn = .albums
                model.selectAlbum(album.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).lineLimit(1).fontWeight(.medium)
                        .foregroundStyle(
                            model.selection.albumID == album.id
                                ? Palette.flame : Palette.textPrimary)
                    Text("\(album.artistNames) · \(album.year)").font(.system(size: 11))
                        .foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: 40)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button {
                model.insertAlbumInQueue(album)
            } label: {
                Image(systemName: "plus.circle").font(.system(size: 13))
                    .foregroundStyle(Palette.textSecondary).frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help(L10n.text("Add to queue"))
        }
        .padding(.horizontal, 10)
        .background(
            model.selection.albumID == album.id && !model.isAlbumsOverview
                ? Palette.glassStrong : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .draggable("album:\(album.id)")
        .contextMenu {
            Button(L10n.text("Play album")) { model.playAlbum(album) }
            Button(L10n.text("Add to queue")) { model.insertAlbumInQueue(album) }
            Button(L10n.text("Similar")) { model.openSimilar(album: album) }
            Divider()
            SpotifyContentLink(kind: "album", id: album.id)
        }
    }

    private func playlistRow(_ playlist: MusicPlaylist) -> some View {
        let selected = model.selection.source == .playlist(playlist.id)
        return HStack(spacing: 4) {
            Button {
                model.focusedColumn = .source
                model.select(.playlist(playlist.id))
            } label: {
                HStack(spacing: 8) {
                    Image(
                        systemName: playlist.isEditable(by: model.library.userID)
                            ? "music.note.list" : "dot.radiowaves.left.and.right"
                    )
                    .font(.system(size: 11)).foregroundStyle(Palette.textTertiary).frame(width: 14)
                    Text(playlist.title).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(
                        playlist.itemsAvailable
                            ? playlist.trackIDs.count.formatted() : "—"
                    )
                    .monospacedDigit().foregroundStyle(Palette.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: 30)
                .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])

            Button {
                model.insertPlaylistInQueue(playlist)
            } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary).frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!playlist.itemsAvailable)
            .help(
                playlist.itemsAvailable
                    ? L10n.text("Add to queue")
                    : L10n.text(
                        "Spotify only provides tracks for playlists you own or collaborate on."))
        }
        .padding(.horizontal, 10)
        .background(selected ? Palette.glassStrong : .clear, in: RoundedRectangle(cornerRadius: 6))
        .draggable("playlist:\(playlist.id)")
        .contextMenu {
            Button(L10n.text("Add to queue")) { model.insertPlaylistInQueue(playlist) }
                .disabled(!playlist.itemsAvailable)
            Button(L10n.text("Similar")) { model.openSimilar(playlist: playlist) }
            Divider()
            SpotifyContentLink(kind: "playlist", id: playlist.id)
        }
    }

    private func artistRow(_ artist: MusicArtist) -> some View {
        HStack(spacing: 4) {
            Button {
                model.focusedColumn = .source
                model.select(.artist(artist.id))
            } label: {
                Text(artist.name).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: 30)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
            MusicHeart(
                liked: model.library.followedArtistIDs.contains(artist.id), title: artist.name
            ) {
                model.toggleArtist(artist)
            }.disabled(!model.canMutate)
        }
        .padding(.horizontal, 10)
        .background(
            model.selection.source == .artist(artist.id) ? Palette.glassStrong : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contextMenu {
            Button(L10n.text("Similar")) { model.openSimilar(artist: artist) }
            Divider()
            SpotifyContentLink(kind: "artist", id: artist.id)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.8).textCase(.uppercase)
            .foregroundStyle(Palette.textTertiary).padding(.top, 16).padding(.bottom, 6)
            .padding(.leading, 10)
    }

    private func sectionHeader(
        _ title: String, count: Int, action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.8).textCase(
                .uppercase
            )
            .foregroundStyle(Palette.textTertiary)
            Text(count.formatted()).font(KinroxFont.monoDigits(10)).foregroundStyle(
                Palette.textTertiary)
            Spacer(minLength: 4)
            Button(action: action) {
                Text(L10n.text("Show all  →")).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.flame).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.top, 18).padding(.bottom, 6).padding(.horizontal, 10)
    }

    private func row(
        _ source: MusicSource, title: String, symbol: String? = nil, count: Int,
        accent: Bool = false, customAction: (() -> Void)? = nil
    ) -> some View {
        let isSelected =
            model.selection.source == source && (source != .albums || !model.isAlbumsOverview)
        return Button {
            if let customAction {
                customAction()
            } else {
                model.focusedColumn = .source
                model.select(source)
            }
        } label: {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(accent ? Palette.flame : Palette.textSecondary)
                        .frame(width: 14)
                }
                Text(title).lineLimit(1)
                    .foregroundStyle(accent && isSelected ? Palette.flame : Palette.textPrimary)
                Spacer(minLength: 4)
                Text(count.formatted()).monospacedDigit().foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
            .background(
                isSelected ? Palette.glassStrong : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var expandedSectionTitle: String {
        switch model.leftSection {
        case .home: L10n.text("Library")
        case .playlists: L10n.text("Playlists")
        case .artists: L10n.text("Artists")
        case .albums: L10n.text("Albums")
        }
    }

    private var expandedSectionCount: Int {
        switch model.leftSection {
        case .home: 0
        case .playlists: model.filteredLeftPlaylists.count
        case .artists: model.filteredLeftArtists.count
        case .albums: model.filteredLeftAlbums.count
        }
    }
}

struct MusicSourcePicker: View {
    @Bindable var model: MusicViewModel
    var body: some View {
        HStack(spacing: 8) {
            Picker(
                L10n.text("Library"),
                selection: Binding(
                    get: { model.selection.source },
                    set: { source in
                        if case .albums = source {
                            model.openAlbumsOverview()
                        } else {
                            model.select(source)
                        }
                    })
            ) {
                Text(L10n.text("Similar & discovery")).tag(MusicSource.similar)
                Text(L10n.text("Liked tracks")).tag(MusicSource.liked)
                Text(L10n.text("All albums")).tag(MusicSource.albums)
                Text(L10n.text("Queue")).tag(MusicSource.queue)
                ForEach(model.library.playlists) { Text($0.title).tag(MusicSource.playlist($0.id)) }
                ForEach(model.catalog.artists) { Text($0.name).tag(MusicSource.artist($0.id)) }
                if !model.query.isEmpty { Text(model.query).tag(MusicSource.search(model.query)) }
            }.labelsHidden().pickerStyle(.menu).controlSize(.large)
            if model.selection.source == .albums && !model.isAlbumsOverview {
                Button {
                    model.openAlbumsOverview()
                } label: {
                    Text(L10n.text("All albums"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.flame)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Palette.glassStrong, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
    }
}
