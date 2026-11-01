import RemoteProtocol
import SwiftUI

struct MusicTrackDetails: View {
    let track: RemoteMusicTrack
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SpotifyAttribution()
                    HStack(alignment: .firstTextBaseline) {
                        if track.explicit == true { SpotifyExplicitBadge() }
                        Text(track.title).font(.title2.bold())
                    }
                    Text(track.artists.joined(separator: ", "))
                    SpotifyContentLink(kind: "track", id: track.id)
                    Text(track.album)
                    if !track.year.isEmpty { Text(track.year) }
                    if let id = track.albumID {
                        SpotifyContentLink(
                            kind: "album", id: id, title: L10n.text("Open album in Spotify"))
                    }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(
                    24)
            }.background(Palette.canvas).foregroundStyle(Palette.textPrimary)
                .navigationTitle(L10n.text("Track details")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.text("Done")) { dismiss() }
                    }
                }
        }.tint(Palette.flame)
    }
}
