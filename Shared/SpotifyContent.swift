import SwiftUI

/// Public metadata identifiers only. Opening a link never invokes the Web API.
enum SpotifyDestination {
    static func url(kind: String, id: String, native: Bool = false) -> URL? {
        guard ["track", "album", "playlist", "artist"].contains(kind), !id.isEmpty,
            id.utf8.count <= 128,
            id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII })
        else { return nil }
        return URL(
            string: native ? "spotify:\(kind):\(id)" : "https://open.spotify.com/\(kind)/\(id)")
    }
}

struct SpotifyContentLink: View {
    let kind: String
    let id: String
    var title = L10n.text("Open in Spotify")
    @Environment(\.openURL) private var openURL
    var body: some View {
        if let web = SpotifyDestination.url(kind: kind, id: id),
            let native = SpotifyDestination.url(kind: kind, id: id, native: true)
        {
            Button {
                openURL(native) { accepted in
                    if !accepted { openURL(web) }
                }
            } label: {
                Label(title, systemImage: "arrow.up.right")
            }
        }
    }
}

struct SpotifyExplicitBadge: View {
    var body: some View {
        Text("E").font(.system(size: 9, weight: .bold))
            .foregroundStyle(Palette.canvas).padding(.horizontal, 3).padding(.vertical, 1)
            .background(Palette.textSecondary, in: RoundedRectangle(cornerRadius: 2))
            .accessibilityLabel(L10n.text("Explicit content"))
    }
}

struct SpotifyFavoriteFeedback: View {
    let liked: Bool
    var body: some View {
        Text(liked ? L10n.text("Added to Liked Songs") : L10n.text("Removed from Liked Songs"))
            .font(.system(size: 13)).foregroundStyle(Palette.textPrimary)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
