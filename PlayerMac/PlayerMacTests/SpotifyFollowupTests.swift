import Foundation
import MusicCore
import RemoteProtocol
import Testing

@testable import Kinrox

@MainActor
struct SpotifyFollowupTests {
    @Test func consentBlocksBothConnectAndRestoreBeforeAnyCredentialAccess() async throws {
        let defaults = try #require(UserDefaults(suiteName: "app.kinrox.tests.consent.\(UUID())"))
        defaults.set(String(repeating: "a", count: 32), forKey: SpotifyAccount.preference)
        defaults.set("old-version", forKey: SpotifyAccount.consentPreference)
        let credentials = ConsentCredentials()
        let account = SpotifyAccount(credentials: credentials, defaults: defaults)
        var restoreFailure: String?
        account.onRestoreFailed = { restoreFailure = $0 }
        #expect(!account.termsAccepted)
        #expect(account.hasStoredConnection)
        account.restore()
        #expect(restoreFailure == L10n.text("Reconnect Spotify in Settings."))
        #expect(account.errorMessage == L10n.text("Reconnect Spotify in Settings."))
        account.connect()
        for _ in 0..<20 { await Task.yield() }
        #expect(!account.isConnecting && !account.connected)
        #expect(credentials.reads == 0)
        #expect(defaults.string(forKey: SpotifyAccount.consentPreference) == "old-version")
        let documents = try #require(SpotifyDocuments.bundled)
        #expect(documents.version == SpotifyDocuments.currentVersion)
    }

    @Test func restrictedActionsNeverReachMusicEngineOrChangeQueue() async throws {
        let model = MusicViewModel()
        let engine = FakeMusicEngine()
        model.connect(engine: engine)
        let before = model.queue
        model.disallowedActions = [
            "seeking", "pausing", "resuming", "skipping_next", "skipping_prev",
            "toggling_shuffle", "toggling_repeat_context", "volume", "interrupting_playback",
        ]
        model.seek(25)
        model.setVolume(80)
        model.setPaused(true)
        model.setPaused(false)
        model.next()
        model.previous()
        model.shuffle()
        model.cycleRepeat()
        model.play(model.catalog.tracks)
        for _ in 0..<20 { await Task.yield() }
        #expect(engine.commands.isEmpty)
        #expect(model.queue == before)
        await model.shutdownPlayback()
    }

    @Test func favoriteFeedbackIsConfirmedTransientAndClearedOnDisconnect() async throws {
        let model = MusicViewModel()
        let track = try #require(
            model.catalog.tracks.first { !model.library.likedTrackIDs.contains($0.id) })
        model.toggleTrack(track, anchor: "test")
        #expect(model.favoriteFeedbackID == nil)
        for _ in 0..<1000 where model.isMutating { await Task.yield() }
        let id = try #require(model.favoriteFeedbackID)
        #expect(model.favoriteFeedbackLiked == true)
        try await Task.sleep(for: .milliseconds(3200))
        #expect(model.favoriteFeedbackID == nil)
        model.toggleTrack(track, anchor: "test")
        for _ in 0..<1000 where model.isMutating { await Task.yield() }
        #expect(model.favoriteFeedbackLiked == false && model.favoriteFeedbackID != id)
        model.replaceStore(DisconnectedMusicLibraryStore())
        #expect(model.favoriteFeedbackID == nil && model.favoriteFeedbackLiked == nil)
    }

    @Test func spotifyLinksRejectNonIdentifiersAndPreserveContext() {
        #expect(
            SpotifyDestination.url(kind: "track", id: "abc123")?.absoluteString
                == "https://open.spotify.com/track/abc123")
        #expect(
            SpotifyDestination.url(kind: "album", id: "abc", native: true)?.absoluteString
                == "spotify:album:abc")
        #expect(SpotifyDestination.url(kind: "playlist", id: "a/b?x=1") == nil)
        #expect(SpotifyDestination.url(kind: "evil", id: "abc") == nil)
    }
}

@MainActor
private final class ConsentCredentials: SpotifyCredentialStore {
    var reads = 0
    func refreshToken(clientID: String) throws -> String? {
        reads += 1
        return nil
    }
    func save(_ token: String, clientID: String) throws {}
    func remove(clientID: String) throws {}
}
