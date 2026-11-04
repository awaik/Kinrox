import Foundation
import SpotifyWebAPI

@MainActor
enum SpotifyStatus {
    static func message(_ error: any Error) -> String {
        if let failure = error as? SoloistFailure {
            if failure == .accountMismatch {
                return L10n.text("A different Spotify account is paired. Pair again.")
            }
            return L10n.text("Soloist could not confirm the playback command.")
        }
        if case SpotifyPlaybackError.otherDevice = error {
            return L10n.text("Spotify is playing on another device or outside Kinrox.")
        }
        if case SpotifyPlaybackError.restricted = error {
            return L10n.text("This action is unavailable in Spotify.")
        }
        guard let error = error as? SpotifyError else {
            return L10n.text("Spotify is unavailable. Check your connection.")
        }
        switch error {
        case .authentication: return L10n.text("Reconnect Spotify in Settings.")
        case .forbidden:
            return L10n.text("Spotify denied access. Check Premium and the app allowlist.")
        case .noDevice: return L10n.text("Open Spotify on this Mac and start a track.")
        case .rateLimited(_, let quota):
            return quota
                ? L10n.text("Spotify quota reached. Try again later.")
                : L10n.text("Spotify is busy. Try again later.")
        default: return L10n.text("Spotify is unavailable. Check your connection.")
        }
    }
}
