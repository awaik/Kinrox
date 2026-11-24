import Foundation

/// Shared commands for keyboard, overlay bar, menu, Now Playing, and remote.
extension PlayerViewModel {
    static let shortSeek: Double = 5
    static let longSeek: Double = 30
    static let volumeStep: Double = 5

    var canControl: Bool { hasMedia && !isClosing }
    var canNext: Bool { playlist?.hasNext ?? false }
    var canPrevious: Bool { playlist?.hasPrevious ?? false }

    /// "3 of 12 · Movies" for title; empty if folder has one video.
    var playlistCaption: String {
        guard let playlist, playlist.count > 1 else { return "" }
        return L10n.format(
            "%@ of %@ · %@", (playlist.index + 1).formatted(), playlist.count.formatted(),
            playlist.folderName)
    }

    @discardableResult
    func togglePause() -> Bool {
        guard canControl, !isScreensaverEngaged else { return false }
        return setPaused(isAtEnd && !replayPending ? false : !(requestedPause ?? paused))
    }

    @discardableResult
    func setPaused(_ paused: Bool) -> Bool {
        cancelEOFRefresh()
        guard canControl, paused || !isScreensaverEngaged else { return false }
        if paused { cancelPendingPlayback?() }
        if !paused, let beforeStartingPlayback {
            return beforeStartingPlayback { [weak self] in _ = self?.setPausedForPlayback(false) }
        }
        return setPausedForPlayback(paused)
    }

    @discardableResult
    private func setPausedForPlayback(_ paused: Bool) -> Bool {
        guard canControl, paused || !isScreensaverEngaged else { return false }
        if parkedVideo != nil {
            if paused {
                requestedPause = nil
                return true
            }
            return unpark(startPaused: false)
        }
        return perform {
            if !paused {
                cancelIdlePark()
                watchProgress.restoredAtEndKey = nil
                isStartingHome = false
                isShowingConnectPhone = false
                setShowingHome(false)
            }
            if !paused, isAtEnd, !replayPending {
                try engine.seek(absolute: 0)
                replayPending = true
            }
            try engine.setPaused(paused)
            requestedPause = paused
        }
    }

    @discardableResult
    func restartFromBeginning() -> Bool {
        cancelEOFRefresh()
        guard canControl else { return false }
        let run: @MainActor () -> Bool = { [weak self] in
            guard let self, self.canControl else { return false }
            self.stopScreensaver()
            if self.parkedVideo != nil {
                return self.unpark(startPaused: false, position: 0)
            }
            return self.perform {
                self.cancelIdlePark()
                self.isStartingHome = false
                self.isShowingConnectPhone = false
                self.setShowingHome(false)
                self.watchProgress.pending = nil
                self.watchProgress.restoredAtEndKey = nil
                try self.engine.seek(absolute: 0)
                try self.engine.setPaused(false)
                self.requestedPause = false
            }
        }
        if let beforeStartingPlayback {
            return beforeStartingPlayback { _ = run() }
        }
        return run()
    }

    @discardableResult
    func showHome() -> Bool {
        guard hasMedia, !isClosing, !isLoading, !isScreensaverEngaged else { return false }
        cancelPendingPlayback?()
        cancelEOFRefresh()
        trackController.presentation = nil
        if parkedVideo != nil || (paused && requestedPause != false) {
            isStartingHome = false
            recents?.refreshAvailability()
            setShowingHome(true)
            return true
        }
        isStartingHome = true
        guard setPaused(true) else {
            isStartingHome = false
            return false
        }
        return true
    }

    @discardableResult
    func returnToVideo() -> Bool {
        guard hasMedia, !isClosing else { return false }
        if parkedVideo != nil {
            return unpark(startPaused: true)
        }
        isStartingHome = false
        isShowingConnectPhone = false
        setShowingHome(false)
        return true
    }

    @discardableResult
    func toggleHome() -> Bool {
        isShowingHome || isStartingHome ? returnToVideo() : showHome()
    }

    @discardableResult
    func closeVideo() -> Bool {
        guard !isClosing, hasMedia || isLoading || currentURL != nil else { return false }
        cancelIdlePark()
        if parkedVideo == nil {
            guard perform({ try engine.stop() }) else { return false }
        } else {
            parkedVideo = nil
        }
        cancelPendingPlayback?()
        stopScreensaver()
        trackController.close()
        clearMedia()
        return true
    }

    @discardableResult
    func seek(by seconds: Double) -> Bool {
        cancelEOFRefresh()
        guard canControl, !isScreensaverEngaged else { return false }
        watchProgress.pending = nil
        watchProgress.restoredAtEndKey = nil
        if let parked = parkedVideo {
            let target = max(0, parked.position + seconds)
            let clamped = duration > 0 ? min(target, duration) : target
            if isShowingHome {
                updateParkedPosition(clamped)
                return true
            }
            return unpark(startPaused: true, position: clamped)
        }
        let accepted = perform { try engine.seek(relative: seconds) }
        if accepted {
            endReached = false
            updateIdleParkTimer()
        }
        return accepted
    }

    @discardableResult
    func seek(to seconds: Double) -> Bool {
        cancelEOFRefresh()
        guard canControl, !isScreensaverEngaged else { return false }
        watchProgress.pending = nil
        watchProgress.restoredAtEndKey = nil
        let upper = duration > 0 ? duration : seconds
        let target = min(max(0, seconds), upper)
        if parkedVideo != nil {
            if isShowingHome {
                updateParkedPosition(target)
                return true
            }
            return unpark(startPaused: true, position: target)
        }
        let accepted = perform { try engine.seek(absolute: target) }
        if accepted {
            endReached = false
            updateIdleParkTimer()
        }
        return accepted
    }

    @discardableResult
    func setVolume(_ value: Double) -> Bool {
        guard !isClosing, value.isFinite else { return false }
        let clamped = min(100, max(0, value))
        // Move slider immediately: mpv confirmation will arrive via volume event.
        volume = clamped
        return perform { try engine.setVolume(clamped) }
    }

    func changeVolume(by delta: Double) { setVolume(volume + delta) }

    @discardableResult
    func next() -> Bool {
        guard !isScreensaverEngaged, let url = playlist?.next else { return false }
        return open(url: url)
    }

    @discardableResult
    func previous() -> Bool {
        guard !isScreensaverEngaged, let url = playlist?.previous else { return false }
        return open(url: url)
    }

    @discardableResult
    func toggleFullscreen() -> Bool {
        guard !isClosing, let onToggleFullscreen else { return false }
        onToggleFullscreen()
        return true
    }

    @discardableResult
    func setFullscreen(_ fullscreen: Bool) -> Bool {
        guard !isClosing else { return false }
        if let onSetFullscreen {
            onSetFullscreen(fullscreen)
            return true
        }
        return isFullscreen == fullscreen || toggleFullscreen()
    }

    @discardableResult
    private func perform(_ command: () throws -> Void) -> Bool {
        do {
            try command()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
