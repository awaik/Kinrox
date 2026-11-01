import MusicCore
import SwiftUI

struct LikePopover: View {
    @Bindable var model: MusicViewModel
    let track: MusicTrack
    @State private var creatingPlaylist = false
    @State private var playlistTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Label {
                    Text(L10n.text("Liked"))
                } icon: {
                    MusicIcon(name: "SpotifySaved")
                }
                .foregroundStyle(Palette.ember).font(.system(size: 13, weight: .medium))
                Text(track.title + " — " + track.artistNames)
                    .font(.system(size: 12)).foregroundStyle(Palette.textSecondary).lineLimit(2)
                    .help(track.title + " — " + track.artistNames)
            }.padding(16)
            Divider()
            section(L10n.text("Add to playlist"))
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.library.editablePlaylists) { playlist in
                        Toggle(
                            isOn: Binding(
                                get: { playlist.trackIDs.contains(track.id) },
                                set: {
                                    model.setMembership(
                                        trackID: track.id, playlistID: playlist.id, included: $0)
                                }
                            )
                        ) {
                            HStack {
                                Text(playlist.title).help(playlist.title).lineLimit(1)
                                Spacer()
                                Text(playlist.trackIDs.count.formatted()).monospacedDigit()
                                    .foregroundStyle(Palette.textTertiary)
                            }
                        }.toggleStyle(.checkbox).frame(height: 32).padding(.horizontal, 16)
                            .contextMenu { SpotifyContentLink(kind: "playlist", id: playlist.id) }
                    }
                }
            }.frame(maxHeight: 160)
            if creatingPlaylist {
                HStack {
                    TextField(L10n.text("Playlist name"), text: $playlistTitle)
                        .onSubmit(createPlaylist)
                    Button(L10n.text("Create"), action: createPlaylist)
                        .disabled(
                            playlistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(12)
            } else {
                Button {
                    creatingPlaylist = true
                } label: {
                    Label(L10n.text("New playlist…"), systemImage: "plus")
                }.buttonStyle(.plain).foregroundStyle(Palette.flame).padding(16)
            }
            Divider()
            section(L10n.text("Follow"))
            ForEach(track.artists) { artist in
                Toggle(
                    artist.name,
                    isOn: Binding(
                        get: { model.library.followedArtistIDs.contains(artist.id) },
                        set: { model.setFollowed(artist, followed: $0) }
                    )
                ).toggleStyle(.checkbox).frame(height: 32).padding(.horizontal, 16).help(
                    artist.name)
            }
            Divider().padding(.top, 8)
            Text(L10n.text("Saved immediately · Esc to close"))
                .font(.system(size: 11)).foregroundStyle(Palette.textTertiary).padding(16)
        }
        .font(.system(size: 13)).foregroundStyle(Palette.textPrimary).tint(Palette.ember)
        .frame(width: 300).background(Palette.elevated).preferredColorScheme(.dark)
        .disabled(model.isMutating)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).textCase(.uppercase)
            .tracking(0.8).foregroundStyle(Palette.textTertiary)
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
    }

    private func createPlaylist() {
        model.createPlaylist(playlistTitle, trackID: track.id)
        creatingPlaylist = false
        playlistTitle = ""
    }
}
