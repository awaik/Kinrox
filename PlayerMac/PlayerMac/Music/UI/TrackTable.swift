import MusicCore
import SwiftUI

struct TrackTable: View {
    @Bindable var model: MusicViewModel

    var body: some View {
        VStack(spacing: 0) {
            CollectionHeader(model: model)
            MusicServiceStatus(model: model)
            GeometryReader { geometry in
                let columns = MusicTrackColumns(
                    width: max(0, geometry.size.width - 24),
                    showAlbum: model.album == nil,
                    showAdded: model.showsAddedColumn)
                VStack(spacing: 0) {
                    MusicTrackHeader(
                        showAlbum: model.album == nil,
                        showAdded: model.showsAddedColumn,
                        columns: columns,
                        sortOrder: model.currentTrackSortOrder
                    ) { column in
                        model.toggleTrackSort(column)
                    }.padding(.horizontal, 12)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(model.contents.tracks.enumerated()), id: \.offset) {
                                    index, track in
                                    MusicTrackRow(
                                        model: model, track: track, index: index,
                                        showAlbum: model.album == nil,
                                        showAdded: model.showsAddedColumn,
                                        columns: columns,
                                        anchor: "track-\(index)"
                                    ) {
                                        model.play(model.contents.tracks, at: index)
                                    }.id(track.id)
                                }
                                if model.contents.tracks.isEmpty, model.statusMessage == nil {
                                    Text(L10n.text("No results")).foregroundStyle(
                                        Palette.textSecondary
                                    )
                                    .padding(32)
                                }
                            }.padding(.horizontal, 12).padding(.top, 4)
                        }
                        .onAppear {
                            if let id = model.focusedTrackID { proxy.scrollTo(id, anchor: .center) }
                        }
                        .onChange(of: model.focusedTrackID) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                    }
                    // Reset lazy row geometry when moving between flat search and album columns.
                    .id(model.selection.source).id(model.selection.albumID)
                }
            }
        }.background(Palette.canvas).accessibilityElement(children: .contain).accessibilityLabel(
            L10n.text("Tracks"))
    }
}

struct MusicTrackHeader: View {
    let showAlbum: Bool
    var showAdded = false
    let columns: MusicTrackColumns
    var sortOrder: TrackSortOrder? = nil
    var onSort: ((TrackSortColumn) -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            headerCell("№", column: .number, alignment: .trailing)
                .frame(width: 28, alignment: .trailing)
            headerCell(L10n.text("Title"), column: .title, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            headerCell(L10n.text("Artists"), column: .artists, alignment: .leading)
                .frame(width: columns.artists, alignment: .leading)
            if showAlbum {
                headerCell(L10n.text("Album"), column: .album, alignment: .leading)
                    .frame(width: columns.album, alignment: .leading)
            }
            if showAdded {
                headerCell(L10n.text("Added"), column: .added, alignment: .leading)
                    .frame(width: columns.added, alignment: .leading)
            }
            MusicIcon(name: "SpotifyAdd", size: 12).frame(width: 24)
            headerCell(L10n.text("Time"), column: .duration, alignment: .trailing)
                .frame(width: 56, alignment: .trailing)
        }.font(.system(size: 10, weight: .semibold)).tracking(0.8).textCase(.uppercase)
            .foregroundStyle(Palette.textTertiary).padding(.horizontal, 8).frame(height: 28)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    @ViewBuilder
    private func headerCell(_ title: String, column: TrackSortColumn, alignment: Alignment)
        -> some View
    {
        let isActive =
            sortOrder?.column == column && (column != .number || sortOrder?.ascending == false)
        let arrow = isActive ? (sortOrder?.ascending == true ? " ↑" : " ↓") : ""
        if let onSort {
            Button {
                onSort(column)
            } label: {
                Text(title + arrow)
                    .foregroundStyle(isActive ? Palette.flame : Palette.textTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: alignment)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
        } else {
            Text(title).lineLimit(1)
        }
    }
}

struct MusicTrackRow: View {
    @Bindable var model: MusicViewModel
    let track: MusicTrack
    let index: Int
    let showAlbum: Bool
    var showAdded = false
    let columns: MusicTrackColumns
    let anchor: String
    var queueID: UUID? = nil
    let play: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let queueID, model.queue.current?.id != queueID, hovered {
                    Image(systemName: "line.3.horizontal").draggable(queueID.uuidString)
                        .accessibilityLabel(L10n.text("Reorder track"))
                } else if playing {
                    Image(systemName: "waveform").foregroundStyle(Palette.ember)
                } else {
                    Text((index + 1).formatted()).monospacedDigit()
                }
            }.frame(width: 28, alignment: .trailing).foregroundStyle(Palette.textTertiary)
            HStack(spacing: 5) {
                if track.explicit == true { SpotifyExplicitBadge() }
                Text(track.title).help(track.title).foregroundStyle(
                    playing ? Palette.flame : Palette.textPrimary
                )
            }.frame(maxWidth: .infinity, alignment: .leading)
            TrackArtistLink(
                model: model, track: track, anchor: "artist-\(anchor)", onFocus: focusRow
            )
            .frame(width: columns.artists, alignment: .leading)
            if showAlbum {
                TrackAlbumLink(
                    model: model, track: track, anchor: "album-\(anchor)", onFocus: focusRow
                )
                .frame(width: columns.album, alignment: .leading)
            }
            if showAdded {
                Text(model.formattedAddedDate(for: track))
                    .font(KinroxFont.monoDigits(11))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: columns.added, alignment: .leading)
            }
            TrackHeart(model: model, track: track, anchor: anchor)
            if let queueID, model.queue.current?.id != queueID, hovered {
                Button {
                    model.removeFromQueue(queueID)
                } label: {
                    Image(systemName: "xmark").frame(width: 56, height: 28).contentShape(
                        Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(L10n.text("Remove from queue"))
            } else {
                Text(TimeFormat.string(track.duration)).font(KinroxFont.monoDigits(12))
                    .foregroundStyle(Palette.textTertiary).frame(
                        width: 56, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .font(.system(size: 13))
        .foregroundStyle(Palette.textSecondary)
        .lineLimit(1)
        .contentShape(Rectangle())
        .background(
            playing || hovered ? Palette.glass : .clear, in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(selected ? Palette.strokeGlass : .clear)
        )
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { if track.isPlayable != false { play() } }
        .onTapGesture { focusRow() }
        .contextMenu {
            if let artist = track.artists.first {
                Button(L10n.text("Go to artist")) { model.navigateToArtist(artist) }
            }
            if !track.albumID.isEmpty {
                Button(L10n.text("Go to album")) {
                    model.navigateToAlbum(albumID: track.albumID, trackID: track.id)
                }
            }
            Divider()
            SpotifyContentLink(kind: "track", id: track.id)
            SpotifyContentLink(
                kind: "album", id: track.albumID, title: L10n.text("Open album in Spotify"))
            Divider()
            Button(L10n.text("Play"), action: play).disabled(
                track.isPlayable == false || !model.canPlayLibrary)
            Button(L10n.text("Add to queue")) { model.addToQueue(track) }.disabled(
                track.isPlayable == false)
            if let queueID, model.queue.current?.id != queueID {
                Button(L10n.text("Remove from queue")) { model.removeFromQueue(queueID) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: L10n.text("Play"), play)
        .dropDestination(for: String.self) { values, _ in
            guard let queueID, let value = values.first, let id = UUID(uuidString: value) else {
                return false
            }
            model.moveQueue(id, before: queueID)
            return true
        }
    }

    private func focusRow() {
        model.focusedColumn = .tracks
        model.focusTrack(track.id, queueID: queueID)
    }

    private var selected: Bool {
        model.focusedColumn == .tracks
            && (queueID.map { model.focusedQueueID == $0 } ?? (model.focusedTrackID == track.id))
    }
    private var playing: Bool {
        queueID.map { model.queue.current?.id == $0 } ?? (model.currentTrack?.id == track.id)
    }
}

/// Keeps title space at intermediate window widths while retaining all metadata columns.
struct MusicTrackColumns {
    let artists: CGFloat
    let album: CGFloat
    let added: CGFloat
    init(width: CGFloat, showAlbum: Bool, showAdded: Bool = false) {
        added = showAdded ? 92 : 0
        let gaps: CGFloat = 48 + (showAlbum ? 12 : 0) + (showAdded ? 12 : 0)
        let available = max(0, width - 28 - 24 - 56 - 16 - added - gaps)
        artists = min(190, available * (showAlbum ? (showAdded ? 0.30 : 0.34) : 0.45))
        album = min(180, available * (showAdded ? 0.27 : 0.30))
    }
}
