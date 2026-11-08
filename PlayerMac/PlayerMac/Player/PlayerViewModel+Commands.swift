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
        return perform {
            if !paused {
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
    func showHome() -> Bool {
        guard hasMedia, !isClosing, !isLoading else { return false }
        cancelPendingPlayback?()
        stopScreensaver()
        cancelEOFRefresh()
        trackController.presentation = nil
        if paused, requestedPause != false {
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
        guard perform({ try engine.stop() }) else { return false }
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
        return perform { try engine.seek(relative: seconds) }
    }

    @discardableResult
    func seek(to seconds: Double) -> Bool {
        cancelEOFRefresh()
        guard canControl, !isScreensaverEngaged else { return false }
        let upper = duration > 0 ? duration : seconds
        return perform { try engine.seek(absolute: min(max(0, seconds), upper)) }
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
