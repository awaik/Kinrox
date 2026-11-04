import Foundation
import SpotifyWebAPI

@testable import Kinrox

@MainActor
enum SoloistProbeAccount {
    /// One bounded, read-only page; identifiers are retained only in the test's memory.
    static func tenDistinctTrackURIs() async throws -> [String] {
        guard let clientID = UserDefaults.standard.string(forKey: SpotifyAccount.preference),
            let refresh = try KeychainSpotifyCredentialStore().refreshToken(clientID: clientID)
        else { throw SoloistProbeFailure.configuration }
        let token = try await SpotifyOAuth.refresh(refresh, clientID: clientID)
        if let next = token.refreshToken {
            try KeychainSpotifyCredentialStore().save(next, clientID: clientID)
        }
        let client = SpotifyClient { _ in token.accessToken }
        do {
            let page = try await client.resource(
                SpotifyPage<SpotifySavedTrack>.self, path: "me/tracks?limit=50")
            var seen = Set<String>()
            let tracks = (page.value?.items ?? []).compactMap(\.track).compactMap {
                track -> String? in
                guard track.durationMS > 170_000, track.isLocal != true, track.isPlayable != false,
                    let uri = track.uri,
                    uri.range(of: #"^spotify:track:[A-Za-z0-9]{22}$"#, options: .regularExpression)
                        != nil,
                    seen.insert(uri).inserted
                else { return nil }
                return uri
            }
            await client.close()
            guard tracks.count >= 10 else { throw SoloistProbeFailure.configuration }
            return Array(tracks.prefix(10))
        } catch {
            await client.close()
            throw SoloistProbeFailure.rejected
        }
    }

    /// Read-only device binding; never modifies playlists, favorites, library or playback.
    static func verify(deviceName: String) async throws -> [String: Any] {
        guard let clientID = UserDefaults.standard.string(forKey: SpotifyAccount.preference),
            !clientID.isEmpty
        else { return ["web_api_available": false] }
        let credentials = KeychainSpotifyCredentialStore()
        guard let refresh = try credentials.refreshToken(clientID: clientID) else {
            return ["web_api_available": false]
        }
        let token = try await SpotifyOAuth.refresh(refresh, clientID: clientID)
        if let next = token.refreshToken { try credentials.save(next, clientID: clientID) }
        let client = SpotifyClient { _ in token.accessToken }
        do {
            _ = try await client.profile()
            let matches = try await client.devices().filter { $0.name == deviceName }
            await client.close()
            return [
                "web_api_available": true,
                "same_account_device_visible": matches.count == 1,
                "matching_devices": matches.count,
            ]
        } catch {
            await client.close()
            throw SoloistProbeFailure.rejected
        }
    }
}
