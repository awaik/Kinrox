import SwiftUI

/// Unmodified official white artwork, with clear space around the wordmark.
/// Both platforms open content links only after an explicit user action.
struct SpotifyAttribution: View {
    var body: some View {
        Image("SpotifyLogo").resizable().scaledToFit().frame(width: 78, height: 22)
            .padding(10).accessibilityLabel("Spotify")
    }
}
