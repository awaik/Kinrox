import Foundation

struct ParkedVideo: Equatable, Sendable {
    let url: URL
    let position: Double
    let duration: Double
    let title: String
    let isAtEnd: Bool
    let trackSelection: TrackController.SessionSelection
}

extension PlayerViewModel {
    static let defaultIdleParkDelay: Duration = .seconds(30 * 60)

    var isParked: Bool { parkedVideo != nil }

    var shouldIdlePark: Bool {
        hasMedia && !isLoading && !isClosing && parkedVideo == nil && eofTask == nil
            && !isVideoSurfaceVisible
            && ((paused && requestedPause != false) || (isAtEnd && !replayPending))
    }

    func setVideoSurfaceVisible(_ visible: Bool) {
        guard isVideoSurfaceVisible != visible else { return }
        isVideoSurfaceVisible = visible
        if visible, parkedVideo != nil, !isShowingHome, !isScreensaverEngaged {
            _ = unpark(startPaused: true)
        } else {
            updateIdleParkTimer()
        }
    }

    func updateIdleParkTimer() {
        guard shouldIdlePark else {
            cancelIdlePark()
            return
        }
        scheduleIdlePark()
    }

    func scheduleIdlePark() {
        idleParkTask?.cancel()
        let delay = idleParkDelay
        idleParkTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.parkIfIdle()
        }
    }

    func cancelIdlePark() {
        idleParkTask?.cancel()
        idleParkTask = nil
    }

    func parkIfIdle() {
        idleParkTask = nil
        guard shouldIdlePark, let url = currentURL else { return }
        if trackController.presentation != nil || trackController.isChoosingFile {
            scheduleIdlePark()
            return
        }
        recordWatchProgress(force: true)
        parkedVideo = ParkedVideo(
            url: url, position: playbackPosition, duration: duration, title: title,
            isAtEnd: isAtEnd, trackSelection: trackController.captureSessionSelection())
        trackController.stop()
        engine.park()
        notifyPlayback()
    }

    @discardableResult
    func unpark(
        startPaused: Bool, position target: Double? = nil, tracks: MediaTrackKind? = nil
    ) -> Bool {
        guard let parked = parkedVideo else { return false }
        let start = target ?? (parked.isAtEnd && !startPaused ? 0 : parked.position)
        let restoringAtEnd = startPaused && target == nil && parked.isAtEnd
        return loadForPlayback(
            parked.url, startPosition: start, paused: startPaused, tracks: tracks,
            preserveShortStart: true, restoringTracks: parked.trackSelection,
            restoringAtEnd: restoringAtEnd)
    }
}
