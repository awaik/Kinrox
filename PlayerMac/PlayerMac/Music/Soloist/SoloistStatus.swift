import Foundation

extension MusicEngineAvailability {
    var message: String? {
        switch self {
        case .notInstalled: L10n.text("Download Soloist in Settings to play on this Mac.")
        case .downloading: L10n.text("Downloading and verifying Soloist…")
        case .needsKey: L10n.text("Add your personal Soloist API key in Settings.")
        case .needsPairing: L10n.text("Pair Spotify from your iPhone in Settings.")
        case .starting: L10n.text("Starting playback…")
        case .ready: nil
        case .reconnecting: L10n.text("Connection to Soloist was lost.")
        case .expired: L10n.text("Soloist has expired. Download a current version.")
        case .externalTakeover: L10n.text("Music is playing on another device.")
        case .failed(let text):
            text == "Soloist playback stopped."
                ? L10n.text("Soloist playback stopped.") : L10n.text(text)
        }
    }
}

extension MusicViewModel {
    var playbackStatusMessage: String? { engineAvailability.message ?? statusMessage }
}
