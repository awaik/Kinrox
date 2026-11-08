import AppKit
import MusicCore
import SwiftUI

struct TrackArtistLink: View {
    @Bindable var model: MusicViewModel
    let track: MusicTrack
    let anchor: String
    var font: Font = .system(size: 13)
    var onFocus: (() -> Void)? = nil
    @State private var hovered = false

    var body: some View {
        Button {
            onFocus?()
            let flags = NSEvent.modifierFlags.intersection([.command, .option])
            if !flags.isEmpty, let artist = track.artists.first {
                model.navigateToArtist(artist)
            } else {
                model.openArtistPreview(for: track, anchor: anchor)
            }
        } label: {
            Text(track.artistNames)
                .font(font)
                .underline(hovered || isPresented)
                .foregroundStyle(
                    hovered || isPresented ? Palette.textPrimary : Palette.textSecondary
                )
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(track.artists.isEmpty)
        .hoverHelp(track.artistNames, active: hovered)
        .onHover { hovered = $0 }
        .background {
            if isPresented {
                Color.clear.popover(
                    isPresented: Binding(
                        get: { isPresented },
                        set: { if !$0 { model.dismissPopovers() } }
                    ),
                    arrowEdge: .bottom
                ) {
                    ArtistPreviewPopover(
                        model: model,
                        artists: model.previewArtists.isEmpty ? track.artists : model.previewArtists
                    )
                }
            }
        }
    }

    private var isPresented: Bool {
        model.popovers.previewArtistAnchor == anchor && !track.artists.isEmpty
    }
}

struct TrackAlbumLink: View {
    @Bindable var model: MusicViewModel
    let track: MusicTrack
    let anchor: String
    var font: Font = .system(size: 13)
    var onFocus: (() -> Void)? = nil
    @State private var hovered = false

    var body: some View {
        Button {
            onFocus?()
            let flags = NSEvent.modifierFlags.intersection([.command, .option])
            if !flags.isEmpty {
                model.navigateToAlbum(albumID: track.albumID, trackID: track.id)
            } else {
                model.openAlbumPreview(for: track, anchor: anchor)
            }
        } label: {
            Text(track.albumTitle)
                .font(font)
                .underline(hovered || isPresented)
                .foregroundStyle(
                    hovered || isPresented ? Palette.textPrimary : Palette.textSecondary
                )
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(track.albumID.isEmpty)
        .hoverHelp(track.albumTitle, active: hovered)
        .onHover { hovered = $0 }
        .background {
            if isPresented {
                Color.clear.popover(
                    isPresented: Binding(
                        get: { isPresented },
                        set: { if !$0 { model.dismissPopovers() } }
                    ),
                    arrowEdge: .bottom
                ) {
                    AlbumPreviewPopover(
                        model: model,
                        albumID: model.previewAlbumID ?? track.albumID,
                        fallbackTrack: model.previewAlbumTrack ?? track)
                }
            }
        }
    }

    private var isPresented: Bool {
        model.popovers.previewAlbumAnchor == anchor
            && model.popovers.previewAlbumID == track.albumID
    }
}

extension View {
    @ViewBuilder
    func hoverHelp(_ text: String, active: Bool) -> some View {
        if active && !text.isEmpty {
            self.help(text)
        } else {
            self
        }
    }
}

struct AlbumPreviewPopover: View {
    @Bindable var model: MusicViewModel
    let albumID: String
    let fallbackTrack: MusicTrack

    private var album: MusicAlbum? { model.catalog.album(id: albumID) }

    private var tracks: [MusicTrack] {
        if let album {
            let resolved = model.catalog.tracks(in: album)
            if !resolved.isEmpty { return resolved }
        }
        let matching = model.catalog.tracks.filter { $0.albumID == albumID }
        return matching.isEmpty ? [fallbackTrack] : matching
    }

    var body: some View {
        let title = album?.title ?? fallbackTrack.albumTitle
        let artists = album?.artistNames ?? fallbackTrack.artistNames
        let year = album?.year ?? ""
        let totalCount = max(album?.totalTrackCount ?? 0, tracks.count)

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("Album") + (year.isEmpty ? "" : " · " + year))
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                            .textCase(.uppercase)
                            .foregroundStyle(Palette.textTertiary)
                        Text(title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(2)
                            .help(title)
                    }
                    Spacer(minLength: 0)
                    if let album {
                        MusicHeart(
                            liked: model.library.savedAlbumIDs.contains(album.id),
                            title: album.title
                        ) {
                            model.toggleAlbum(album)
                        }.disabled(!model.canMutate)
                    }
                }
                Text(artists + " · " + L10n.format("%@ tracks", totalCount.formatted()))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }.padding(16)
            Divider()
            Text(L10n.text("Tracks"))
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { index, item in
                        let isPlaying = model.currentTrack?.id == item.id
                        let isSource = item.id == fallbackTrack.id
                        Button {
                            model.play(tracks, at: index)
                        } label: {
                            HStack(spacing: 8) {
                                Group {
                                    if isPlaying {
                                        Image(systemName: "waveform").foregroundStyle(Palette.ember)
                                    } else {
                                        Text((index + 1).formatted())
                                            .font(KinroxFont.monoDigits(11))
                                            .foregroundStyle(Palette.textTertiary)
                                    }
                                }.frame(width: 22, alignment: .trailing)
                                Text(item.title)
                                    .font(
                                        .system(
                                            size: 12,
                                            weight: isPlaying || isSource ? .semibold : .regular)
                                    )
                                    .foregroundStyle(
                                        isPlaying || isSource ? Palette.flame : Palette.textPrimary
                                    )
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(TimeFormat.string(item.duration))
                                    .font(KinroxFont.monoDigits(11))
                                    .foregroundStyle(Palette.textTertiary)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(
                                isPlaying || isSource ? Palette.glass : .clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(item.isPlayable == false || !model.canPlayLibrary)
                    }
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }.frame(maxHeight: 184)
            Divider()
            HStack(spacing: 8) {
                Button {
                    model.navigateToAlbum(albumID: albumID, trackID: fallbackTrack.id)
                } label: {
                    Text(L10n.text("Go to album") + " →")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.flame)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(Palette.glassStrong, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.strokeGlass))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button {
                    if let album {
                        model.playAlbum(album)
                    } else {
                        model.play(tracks)
                    }
                } label: {
                    Label(L10n.text("Play"), systemImage: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.base)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Palette.textPrimary, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canPlayLibrary || tracks.isEmpty)
            }.padding(12)
        }
        .font(.system(size: 13))
        .foregroundStyle(Palette.textPrimary)
        .frame(width: 320)
        .background(Palette.elevated)
        .preferredColorScheme(.dark)
    }
}

struct ArtistPreviewPopover: View {
    @Bindable var model: MusicViewModel
    let artists: [MusicArtist]

    private var currentArtist: MusicArtist? {
        artists.first { $0.id == model.previewArtistID } ?? artists.first
    }

    private func albums(for artist: MusicArtist) -> [MusicAlbum] {
        model.catalog.albums.filter { album in
            album.artists.contains { $0.id == artist.id }
        }
    }

    private func tracks(for artist: MusicArtist) -> [MusicTrack] {
        model.catalog.tracks.filter { track in
            track.artists.contains { $0.id == artist.id }
        }
    }

    var body: some View {
        if let artist = currentArtist {
            let artistAlbums = albums(for: artist)
            let artistTracks = tracks(for: artist)
            VStack(alignment: .leading, spacing: 0) {
                if artists.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(artists) { item in
                                let active = item.id == artist.id
                                Button {
                                    model.selectPreviewArtist(item.id)
                                } label: {
                                    Text(item.name)
                                        .font(
                                            .system(size: 11, weight: active ? .semibold : .regular)
                                        )
                                        .foregroundStyle(
                                            active ? Palette.flame : Palette.textSecondary
                                        )
                                        .padding(.horizontal, 10)
                                        .frame(height: 24)
                                        .background(
                                            active ? Palette.glassStrong : .clear,
                                            in: RoundedRectangle(cornerRadius: 6)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6).stroke(
                                                active ? Palette.strokeGlass : .clear)
                                        )
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 12).padding(.vertical, 10)
                    }
                    Divider()
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("Artist"))
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.8)
                                .textCase(.uppercase)
                                .foregroundStyle(Palette.textTertiary)
                            Text(artist.name)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(2)
                                .help(artist.name)
                        }
                        Spacer(minLength: 0)
                        MusicHeart(
                            liked: model.library.followedArtistIDs.contains(artist.id),
                            title: artist.name
                        ) {
                            model.toggleArtist(artist)
                        }.disabled(!model.canMutate)
                    }
                    Text(
                        L10n.text("Albums") + ": " + artistAlbums.count.formatted() + " · "
                            + L10n.format("%@ tracks", artistTracks.count.formatted())
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                }.padding(16)
                Divider()
                Text(L10n.text(artistAlbums.isEmpty ? "Tracks" : "Albums"))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                ScrollView {
                    VStack(spacing: 4) {
                        if !artistAlbums.isEmpty {
                            ForEach(artistAlbums) { album in
                                HStack(spacing: 10) {
                                    Button {
                                        model.playAlbum(album)
                                    } label: {
                                        MusicIcon(name: "MusicPlay", size: 10)
                                            .frame(width: 24, height: 24)
                                            .foregroundStyle(Palette.textPrimary)
                                            .background(Palette.glass, in: Circle())
                                            .overlay(Circle().stroke(Palette.strokeGlass))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!model.canPlayLibrary)
                                    Button {
                                        model.navigateToAlbum(albumID: album.id)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(album.title)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(Palette.textPrimary)
                                                .lineLimit(1)
                                            Text(
                                                album.year + " · "
                                                    + L10n.format(
                                                        "%@ tracks",
                                                        album.totalTrackCount.formatted())
                                            )
                                            .font(.system(size: 11))
                                            .foregroundStyle(Palette.textSecondary)
                                            .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 40)
                                .background(Palette.glass, in: RoundedRectangle(cornerRadius: 6))
                            }
                        } else {
                            ForEach(Array(artistTracks.enumerated()), id: \.offset) { index, item in
                                Button {
                                    model.play(artistTracks, at: index)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(item.title)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Palette.textPrimary)
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(TimeFormat.string(item.duration))
                                            .font(KinroxFont.monoDigits(11))
                                            .foregroundStyle(Palette.textTertiary)
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(height: 28)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(item.isPlayable == false || !model.canPlayLibrary)
                            }
                        }
                    }.padding(.horizontal, 8).padding(.bottom, 8)
                }.frame(maxHeight: 184)
                Divider()
                HStack(spacing: 8) {
                    Button {
                        model.navigateToArtist(artist)
                    } label: {
                        Text(L10n.text("Go to artist") + " →")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.flame)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(Palette.glassStrong, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.strokeGlass))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button {
                        if !artistTracks.isEmpty {
                            model.play(artistTracks)
                        } else if let first = artistAlbums.first {
                            model.playAlbum(first)
                        }
                    } label: {
                        Label(L10n.text("Play"), systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.base)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(Palette.textPrimary, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        !model.canPlayLibrary || (artistTracks.isEmpty && artistAlbums.isEmpty))
                }.padding(12)
            }
            .font(.system(size: 13))
            .foregroundStyle(Palette.textPrimary)
            .frame(width: 320)
            .background(Palette.elevated)
            .preferredColorScheme(.dark)
        }
    }
}
