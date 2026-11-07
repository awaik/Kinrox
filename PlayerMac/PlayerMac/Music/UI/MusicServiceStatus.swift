import SwiftUI

/// Figma 116:3116 and variants: recovery stays inside the track column.
struct MusicServiceStatus: View {
    @Bindable var model: MusicViewModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let message = model.playbackStatusMessage, model.retryChange == nil,
            model.retryPlaylist == nil
        {
            HStack(spacing: 16) {
                Text(message).frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Palette.textSecondary)
                if isPlaylistItemsRestriction(message),
                    case .playlist(let id) = model.selection.source
                {
                    SpotifyContentLink(kind: "playlist", id: id)
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.flame)
                } else if showsAction {
                    Button(buttonTitle(message)) {
                        if needsSettings(message) {
                            openSettings()
                        } else if model.engineAvailability != .ready,
                            let recovery = model.engineRecovery
                        {
                            recovery()
                        } else {
                            model.retry()
                        }
                    }.buttonStyle(.plain).foregroundStyle(Palette.flame)
                }
            }.font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 14)
        }
    }

    var showsAction: Bool {
        if let message = model.playbackStatusMessage, isPlaylistItemsRestriction(message) {
            return false
        }
        return model.engineAvailability != .ready
            ? (model.engineAvailability != .starting && model.engineAvailability != .downloading)
            : (!model.isLoading && !model.isRefreshing)
    }

    private func isPlaylistItemsRestriction(_ message: String) -> Bool {
        message
            == L10n.text("Spotify only provides tracks for playlists you own or collaborate on.")
    }

    func needsSettings(_ message: String) -> Bool {
        switch model.engineAvailability {
        case .notInstalled, .needsKey, .needsPairing, .expired: return true
        case .failed where model.engineNeedsSetup: return true
        default: break
        }
        return model.accountName == nil
            || message == L10n.text("Reconnect Spotify in Settings.")
            || message == L10n.text("Spotify denied access. Check Premium and the app allowlist.")
    }

    private func buttonTitle(_ message: String) -> String {
        if needsSettings(message) { return L10n.text("Settings") }
        if model.engineAvailability == .externalTakeover { return L10n.text("Play on this Mac") }
        return L10n.text("Retry")
    }
}
