import MusicCore
import SwiftUI

struct TrackTable: View {
    @Bindable var model: MusicViewModel

    var body: some View {
        VStack(spacing: 0) {
            CollectionHeader(model: model)
            MusicServiceStatus(model: model)
            MusicTrackHeader(showAlbum: model.album == nil).padding(.horizontal, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.contents.tracks.enumerated()), id: \.offset) {
                            index, track in
                            MusicTrackRow(
                                model: model, track: track, index: index,
                                showAlbum: model.album == nil, anchor: "track-\(index)"
                            ) {
                                model.play(model.contents.tracks, at: index)
                            }.id(track.id)
                        }
                        if model.contents.tracks.isEmpty, model.statusMessage == nil {
                            Text(L10n.text("No results")).foregroundStyle(Palette.textSecondary)
                                .padding(32)
                        }
                    }.padding(.horizontal, 12).padding(.top, 4)
                }
                .onChange(of: model.focusedTrackID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            // Reset lazy row geometry when moving between flat search and album columns.
            .id(model.selection.source).id(model.selection.albumID)
        }.background(Palette.canvas).accessibilityElement(children: .contain).accessibilityLabel(
            L10n.text("Tracks"))
    }
}

struct MusicTrackHeader: View {
    let showAlbum: Bool
    var body: some View {
        GeometryReader { geometry in
            let columns = MusicTrackColumns(width: geometry.size.width, showAlbum: showAlbum)
            HStack(spacing: 12) {
                Text("№").frame(width: 28, alignment: .trailing)
                Text(L10n.text("Title")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.text("Artists")).frame(width: columns.artists, alignment: .leading)
                if showAlbum {
                    Text(L10n.text("Album")).frame(width: columns.album, alignment: .leading)
                }
                MusicIcon(name: "SpotifyAdd", size: 12).frame(width: 24)
                Text(L10n.text("Time")).frame(width: 56, alignment: .trailing)
            }.font(.system(size: 10, weight: .semibold)).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(Palette.textTertiary).padding(.horizontal, 8).frame(height: 28)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        }.frame(height: 28)
    }
}

struct MusicTrackRow: View {
    @Bindable var model: MusicViewModel
    let track: MusicTrack
    let index: Int
    let showAlbum: Bool
    let anchor: String
    var queueID: UUID? = nil
    let play: () -> Void
    @State private var hovered = false

    var body: some View {
        GeometryReader { geometry in
            let columns = MusicTrackColumns(width: geometry.size.width, showAlbum: showAlbum)
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
                Text(track.artistNames).help(track.artistNames).frame(
                    width: columns.artists, alignment: .leading)
                if showAlbum {
                    Text(track.albumTitle).help(track.albumTitle).frame(
                        width: columns.album, alignment: .leading)
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
            }.padding(.horizontal, 8).frame(height: 34)
        }.frame(height: 34).font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
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
            .onTapGesture {
                model.focusedColumn = .tracks
                model.focusedTrackID = track.id
                model.focusedQueueID = queueID
            }
            .contextMenu {
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

    private var selected: Bool {
        model.focusedColumn == .tracks
            && (queueID.map { model.focusedQueueID == $0 } ?? (model.focusedTrackID == track.id))
    }
    private var playing: Bool {
        queueID.map { model.queue.current?.id == $0 } ?? (model.currentTrack?.id == track.id)
    }
}

/// Keeps title space at intermediate window widths while retaining all metadata columns.
private struct MusicTrackColumns {
    let artists: CGFloat
    let album: CGFloat
    init(width: CGFloat, showAlbum: Bool) {
        let available = max(0, width - 28 - 24 - 56 - 16 - (showAlbum ? 60 : 48))
        artists = min(200, available * (showAlbum ? 0.34 : 0.45))
        album = min(190, available * 0.3)
    }
}
