import SwiftUI

/// Figma 116:3116 and variants: recovery stays inside the track column.
struct MusicServiceStatus: View {
    @Bindable var model: MusicViewModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let message = model.statusMessage, model.retryChange == nil,
            model.retryPlaylist == nil
        {
            HStack(spacing: 16) {
                Text(message).frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Palette.textSecondary)
                if !model.isLoading {
                    Button(L10n.text(needsSettings(message) ? "Settings" : "Retry")) {
                        if needsSettings(message) { openSettings() } else { model.retry() }
                    }.buttonStyle(.plain).foregroundStyle(Palette.flame)
                }
            }.font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 14)
        }
    }

    private func needsSettings(_ message: String) -> Bool {
        model.accountName == nil
            || message == L10n.text("Reconnect Spotify in Settings.")
            || message == L10n.text("Spotify denied access. Check Premium and the app allowlist.")
    }
}
