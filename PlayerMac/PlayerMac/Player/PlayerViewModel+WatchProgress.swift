import Foundation

struct VideoWatchProgress {
    struct Start {
        let key: String
        let seconds: Double
        var seekSubmitted = false
    }

    var pending: Start?
    var panel: (key: String, kind: MediaTrackKind)?
    var lastWrite = -Double.infinity
    var finishedAt: Double?
}

extension PlayerViewModel {
    func recordWatchProgress(force: Bool = false, completed: Bool = false) {
        guard let writeWatchProgress, let currentURL, !isLoading, watchProgress.pending == nil,
            hasMedia
        else { return }
        let position = playbackPosition
        let completed = completed || isAtEnd || (duration >= 60 && position >= duration * 0.92)
        guard completed || position >= 5 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let finishedAt = watchProgress.finishedAt {
            guard !completed, position < finishedAt else { return }
        } else {
            guard force || completed || now - watchProgress.lastWrite >= 5 else { return }
        }
        watchProgress.lastWrite = now
        watchProgress.finishedAt = completed ? position : nil
        writeWatchProgress(
            WatchProgress(
                path: VideoFiles.key(currentURL), position: position, duration: duration,
                completed: completed, updated: Date()))
    }

    func setVideoStart(_ url: URL, at seconds: Double?, showTracks kind: MediaTrackKind?) {
        let key = VideoFiles.key(url)
        watchProgress = VideoWatchProgress()
        if let seconds, seconds.isFinite, seconds >= 5 {
            watchProgress.pending = .init(key: key, seconds: seconds)
        }
        if let kind { watchProgress.panel = (key, kind) }
    }

    func applyVideoStart(path: String? = nil) {
        guard let currentURL else { return }
        let key = VideoFiles.key(currentURL)
        if let path, key != VideoFiles.key(URL(fileURLWithPath: path)) { return }
        if let start = watchProgress.pending, start.key == key, !start.seekSubmitted {
            do {
                try engine.seek(absolute: start.seconds)
                watchProgress.pending?.seekSubmitted = true
            } catch {
                watchProgress.pending = nil
                errorMessage = error.localizedDescription
            }
        }
        if let panel = watchProgress.panel, panel.key == key {
            watchProgress.panel = nil
            openTrackPanel(kind: panel.kind)
        }
    }

    func observeResumedPosition(_ position: Double) {
        guard let start = watchProgress.pending, start.seekSubmitted else { return }
        // An initial zero or stale tick must never overwrite the saved checkpoint.
        let target = duration > 0 ? min(start.seconds, duration) : start.seconds
        if position >= target - 2 {
            watchProgress.pending = nil
        }
    }

    func openTrackPanel(kind: MediaTrackKind = .audio) {
        guard canControl, !isLoading, !isScreensaverEngaged else { return }
        returnToVideo()
        trackController.selectedKind = kind
        trackController.presentation = .quick
    }

    @discardableResult
    func resume(_ url: URL, from progress: WatchProgress?, showTracks: Bool = false) -> Bool {
        let position = progress.flatMap { $0.completed ? nil : $0.position }
        if hasMedia, !isLoading, currentURL.map(VideoFiles.key) == VideoFiles.key(url) {
            returnToVideo()
            if showTracks {
                openTrackPanel()
                return true
            }
            return setPaused(false)
        }
        return open(
            url: url, startPosition: position, startPaused: showTracks,
            showTracks: showTracks ? .audio : nil)
    }
}
