import MusicCore
import SwiftUI

struct AlbumColumn: View {
    @Bindable var model: MusicViewModel
    let compact: Bool

    var body: some View {
        VStack(spacing: 0) {
            if compact { MusicSourcePicker(model: model) }
            HStack {
                Text(L10n.text("Albums")).textCase(.uppercase).tracking(0.8)
                Text(model.contents.albums.count.formatted()).monospacedDigit()
                Spacer()
                Button {
                    model.sortAlbumsByArtist.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(
                            model.sortAlbumsByArtist
                                ? L10n.text("By artist") : L10n.text("By title"))
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                }.buttonStyle(.plain)
            }.font(.system(size: 11)).foregroundStyle(Palette.textTertiary).padding(18)
            ScrollView {
                LazyVStack(spacing: 2) {
                    if model.selection.source != .albums {
                        Button {
                            model.selectAlbum(nil)
                            model.focusedColumn = .albums
                        } label: {
                            HStack {
                                Text(
                                    model.isQueue
                                        ? L10n.text("Entire queue") : L10n.text("All tracks"))
                                Spacer()
                            }.padding(12).frame(height: 52).contentShape(Rectangle())
                                .background(
                                    model.selection.albumID == nil ? Palette.glassStrong : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                    ForEach(model.sortedAlbums) { album in albumRow(album) }
                }.padding(.horizontal, 8)
            }
        }.background(Palette.canvas).foregroundStyle(Palette.textPrimary).font(.system(size: 13))
            .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("Albums"))
    }

    private func albumRow(_ album: MusicAlbum) -> some View {
        let current = model.currentTrack?.albumID == album.id
        return HStack(spacing: 12) {
            Button {
                if current && !model.paused { model.togglePause() } else { model.playAlbum(album) }
            } label: {
                MusicIcon(name: current && !model.paused ? "MusicPause" : "MusicPlay", size: 12)
                    .frame(width: 28, height: 28)
                    .foregroundStyle(current && !model.paused ? Palette.base : Palette.textPrimary)
                    .background(current && !model.paused ? Palette.ember : .clear, in: Circle())
                    .overlay(Circle().stroke(Palette.strokeGlass))
            }.buttonStyle(.plain).disabled(
                !model.allows(current && !model.paused ? "pausing" : "interrupting_playback")
            ).accessibilityLabel(L10n.format("Play album: %@", album.title))
            Button {
                model.selectAlbum(album.id)
                model.focusedColumn = .albums
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(album.title).help(album.title).fontWeight(.medium).foregroundStyle(
                        current ? Palette.flame : Palette.textPrimary)
                    Text(album.artistNames + " · " + album.year).help(
                        album.artistNames + " · " + album.year
                    ).font(.system(size: 12))
                        .foregroundStyle(Palette.textSecondary)
                }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 52).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Text(album.totalTrackCount.formatted()).font(KinroxFont.monoDigits(11)).foregroundStyle(
                Palette.textTertiary)
            MusicHeart(liked: model.library.savedAlbumIDs.contains(album.id), title: album.title) {
                model.toggleAlbum(album)
            }.disabled(model.isMutating)
        }.padding(.horizontal, 10).frame(height: 52)
            .background(
                model.selection.albumID == album.id ? Palette.glassStrong : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contextMenu { SpotifyContentLink(kind: "album", id: album.id) }
            .accessibilityAddTraits(model.selection.albumID == album.id ? .isSelected : [])
    }
}
