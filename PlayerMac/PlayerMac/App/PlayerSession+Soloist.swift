import Foundation

extension PlayerSession {
    func excludeLegacyQueue(from store: SpotifyLibraryStore, clientID: String, userID: String) {
        let key = SpotifyAccount.queuePreferencePrefix + clientID + "." + userID
        if let id = UserDefaults.standard.string(forKey: key) { store.excludeQueuePlaylist(id) }
    }

    /// Native playback is the only production engine; setup never falls back to Spotify.app.
    func configureSoloist() {
        soloist.beforeChange = { [weak self] in
            guard let self else { return }
            self.music.acceptsPlayback = false
            self.playback.cancelPending(.music)
            await self.playback.settle()
            await self.music.shutdownPlayback()
        }
        soloist.onAvailability = { [weak self] availability in
            guard let self else { return }
            self.music.engineAvailability = availability
            self.music.engineNeedsSetup = !self.soloist.canRecoverPlayback
            if availability != .ready { self.music.volumeKnown = false }
            self.music.notifyPlayback()
        }
        soloist.onReady = { [weak self] in
            guard let self, self.spotify.connected else { return }
            await self.music.shutdownPlayback()
            do {
                let engine = try self.soloist.makeEngine()
                self.music.engineFactory = { [weak self] in
                    guard let self else { throw SoloistFailure.closed }
                    return try self.soloist.makeEngine()
                }
                self.music.connect(engine: engine)
                self.music.acceptsPlayback = true
                self.music.notifyPlayback()
            } catch {
                self.music.engineAvailability = .failed(SpotifyStatus.message(error))
                self.music.notifyPlayback()
            }
        }
        music.engineAvailabilityChanged = { [weak self] availability in
            guard let self else { return }
            self.soloist.observeRuntime(availability)
            self.music.engineNeedsSetup = !self.soloist.canRecoverPlayback
        }
        music.engineRecovery = { [weak self] in
            guard let self else { return }
            self.soloist.recover { [weak self] in
                guard let self else { return }
                if let retry = self.music.retryPlayback {
                    retry()
                } else {
                    self.music.setPaused(false)
                }
            }
        }
    }
}
