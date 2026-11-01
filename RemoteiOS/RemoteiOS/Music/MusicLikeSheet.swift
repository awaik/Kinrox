import RemoteProtocol
import SwiftUI

struct MusicLikeSheet: View {
    @Bindable var store: RemoteAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var title = ""
    private var track: RemoteMusicTrack? {
        if store.state.music?.track?.id == store.likeOptionsTrackID {
            return store.state.music?.track
        }
        return store.musicQueue.first { $0.track.id == store.likeOptionsTrackID }?.track
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        RemoteMusicIcon(name: "SpotifySaved", size: 22).foregroundStyle(
                            Palette.ember)
                        Text(L10n.text("Liked")).font(.system(size: 20, weight: .semibold))
                    }
                    Text(track.map { $0.title + " — " + $0.artists.joined(separator: ", ") } ?? "")
                        .font(.system(size: 15)).foregroundStyle(Palette.textSecondary).fixedSize(
                            horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                SpotifyAttribution()
                Button(L10n.text("Done")) { dismiss() }.font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.flame)
            }.padding(.horizontal, 20).padding(.vertical, 14)
            Divider().overlay(Palette.hairline)
            ScrollView {
                VStack(spacing: 0) {
                    if let feedback = store.state.music?.favoriteFeedback {
                        SpotifyFavoriteFeedback(liked: feedback.liked).padding(12)
                    }
                    heading(L10n.text("Add to playlist"))
                    ForEach(store.likeOptions.filter { $0.kind == .playlist }) { option in
                        row(option)
                    }
                    Button {
                        creating.toggle()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "plus").frame(width: 22)
                            Text(L10n.text("New playlist…"))
                            Spacer()
                        }.font(.system(size: 17)).foregroundStyle(Palette.flame).padding(
                            .horizontal, 20
                        ).frame(height: 52)
                    }.buttonStyle(.plain)
                    if creating {
                        HStack {
                            TextField(L10n.text("Playlist name"), text: $title).textFieldStyle(
                                .roundedBorder)
                            Button(L10n.text("Create")) {
                                store.createMusicPlaylist(title)
                                creating = false
                                title = ""
                            }.disabled(
                                title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }.padding(.horizontal, 20).padding(.bottom, 12)
                    }
                    Divider().overlay(Palette.hairline)
                    heading(L10n.text("Follow"))
                    ForEach(store.likeOptions.filter { $0.kind == .artist }) { option in row(option)
                    }
                    if store.optionsLoading { ProgressView().padding(10) }
                    Text(L10n.text("Saved immediately")).font(.system(size: 13)).foregroundStyle(
                        Palette.textTertiary
                    )
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                    .padding(.top, 12)
                    if let message = store.state.music?.status ?? store.commandError {
                        Text(message).font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
                            .padding(20)
                    }
                }
            }
        }.padding(.top, 14).foregroundStyle(Palette.textPrimary)
            .presentationDetents([.height(533), .large]).presentationDragIndicator(.visible)
            .presentationCornerRadius(24).presentationBackground(Palette.elevated)
            .task { if let id = store.likeOptionsTrackID { store.requestLikeOptions(id) } }
    }
    private func heading(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 12, weight: .semibold)).foregroundStyle(
            Palette.textTertiary
        )
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 14)
        .padding(.bottom, 6)
    }
    private func row(_ option: RemoteLikeOption) -> some View {
        Button {
            store.setMusicOption(option, selected: !option.selected)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(option.selected ? Palette.ember : .clear)
                    RoundedRectangle(cornerRadius: 5).stroke(
                        option.selected ? Palette.ember : Palette.strokeGlass)
                    if option.selected {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black)
                    }
                }.frame(width: 22, height: 22)
                Text(option.title).font(.system(size: 17)).fixedSize(
                    horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(.horizontal, 20).frame(minHeight: 52).contentShape(Rectangle())
        }.buttonStyle(.plain).contextMenu {
            SpotifyContentLink(
                kind: option.kind == .playlist ? "playlist" : "artist", id: option.id)
        }.disabled(!store.controlsEnabled)
            .accessibilityLabel(option.title).accessibilityValue(
                option.selected ? L10n.text("On") : L10n.text("Off"))
    }
}
