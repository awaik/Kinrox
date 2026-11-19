import Foundation
import Observation

/// Serializes cross-engine transitions. A superseded in-flight network command is
/// allowed to settle before its successor pauses it, preventing late double audio.
@MainActor @Observable
final class PlaybackCoordinator {
    enum Source { case video, localAudio, music }
    private(set) var activeSource = Source.video
    @ObservationIgnored private weak var video: PlayerViewModel?
    @ObservationIgnored private weak var music: MusicViewModel?
    @ObservationIgnored private weak var localAudio: LocalAudioViewModel?
    @ObservationIgnored private var transition: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var pendingSource: Source?
    @ObservationIgnored var sourceChanged: ((Source) -> Void)?
    @ObservationIgnored private var nowPlaying: NowPlayingController?

    func connectNowPlaying(_ controller: NowPlayingController) {
        nowPlaying?.disconnect()
        nowPlaying = controller
        publishSource()
    }

    private func publishSource() {
        switch activeSource {
        case .music:
            if let music { nowPlaying?.connect(to: music) }
        case .localAudio:
            if let localAudio { nowPlaying?.connect(to: localAudio) }
        case .video:
            if let video { nowPlaying?.connect(to: video) }
        }
    }

    func connect(
        video: PlayerViewModel?, music: MusicViewModel, localAudio: LocalAudioViewModel? = nil
    ) {
        self.video?.beforeStartingMatrix = nil
        self.video?.beforeStartingPlayback = nil
        self.video?.cancelPendingPlayback = nil
        self.video = video
        self.music = music
        self.localAudio = localAudio
        localAudio?.coordinator = self
        music.coordinator = self
        video?.beforeStartingPlayback = { [weak self] action in
            guard let self else { return false }
            self.start(.video, action: { action() })
            return true
        }
        video?.cancelPendingPlayback = { [weak self] in self?.cancelPending(.video) }
        video?.beforeStartingMatrix = { [weak self, weak video] action in
            guard let self,
                self.localAudio?.currentTrack != nil || self.pendingSource == .localAudio
            else {
                return false
            }
            self.cancelPending(.localAudio)
            self.perform(.video) { [weak self, weak video] in
                do {
                    try self?.localAudio?.pauseForSourceChange()
                    action(true)
                } catch {
                    video?.errorMessage = error.localizedDescription
                    action(false)
                }
            }
            return true
        }
    }

    func start(_ source: Source, action: @escaping @MainActor () async throws -> Void) {
        perform(source, startsPlayback: true, action: action)
    }

    func perform(
        _ source: Source, startsPlayback: Bool = false,
        action: @escaping @MainActor () async throws -> Void
    ) {
        let previous = transition
        if startsPlayback {
            generation = UUID()
            pendingSource = source
        }
        let generation = generation
        transition = Task { [weak self] in
            await previous?.value
            guard let self, !startsPlayback || self.generation == generation else { return }
            defer {
                if startsPlayback, self.generation == generation { self.pendingSource = nil }
            }
            do {
                if startsPlayback {
                    if source == .localAudio, self.blocksLocalAudioTransport { return }
                    if source != .video { try await self.pauseVideo() }
                    if source != .localAudio { try self.localAudio?.pauseForSourceChange() }
                    if source != .music { try await self.music?.pauseForSourceChange() }
                    guard self.generation == generation else { return }
                    if source == .localAudio { self.video?.showHome() }
                }
                try await action()
                if startsPlayback, self.generation == generation {
                    self.activeSource = source
                    self.publishSource()
                    self.sourceChanged?(source)
                }
            } catch {
                switch source {
                case .music: self.music?.statusMessage = SpotifyStatus.message(error)
                case .video: self.video?.errorMessage = SpotifyStatus.message(error)
                case .localAudio:
                    self.localAudio?.errorMessage = LocalAudioFailure.alertMessage(for: error)
                }
            }
        }
    }

    private func pauseVideo() async throws {
        guard let video else { return }
        for _ in 0..<100 {
            if !video.isLoading { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !video.isLoading else { throw PlaybackTransitionError.pauseTimeout }
        guard video.canControl else { return }
        // setPaused(true) invalidates pending video starts, but must not cancel this music transition.
        let cancel = video.cancelPendingPlayback
        video.cancelPendingPlayback = nil
        let accepted = video.setPaused(true)
        video.cancelPendingPlayback = cancel
        guard accepted else { throw PlaybackTransitionError.pauseRejected }
        for _ in 0..<100 {
            if !video.canControl || (video.paused && video.requestedPause != false) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PlaybackTransitionError.pauseTimeout
    }

    func cancelPending(_ source: Source) {
        // A user pause cancels a queued start; it does not cancel a request already on the wire.
        if pendingSource == source {
            generation = UUID()
            pendingSource = nil
        }
    }

    func allowsPendingStart(_ source: Source) -> Bool { pendingSource == source }

    var blocksLocalAudioTransport: Bool { video?.isScreensaverEngaged == true }

    var mayAdvanceLocalAudio: Bool {
        pendingSource == nil && activeSource == .localAudio && !blocksLocalAudioTransport
    }

    func exitScreensaverForLocalAudioOpen() { video?.stopScreensaver() }

    func settle() async { await transition?.value }

    func close() async { await beginClose().value }

    /// Capture the retiring window synchronously, before AppKit can reopen it.
    /// New starts join this task and cannot use an engine while it is shutting down.
    func beginClose() -> Task<Void, Never> {
        generation = UUID()
        pendingSource = nil
        let video = video
        let music = music
        let localAudio = localAudio
        try? localAudio?.pauseForSourceChange()
        activeSource = .video
        nowPlaying?.disconnect()
        nowPlaying = nil
        video?.beforeStartingPlayback = nil
        video?.cancelPendingPlayback = nil
        video?.beforeStartingMatrix = nil
        let previous = transition
        let closing = Task { [weak self] in
            await previous?.value
            async let musicStopped: Void? = music?.shutdownPlayback()
            async let localStopped: Void? = localAudio?.shutdownPlayback()
            _ = await (musicStopped, localStopped)
            if self?.video === video { self?.video = nil }
        }
        transition = closing
        return closing
    }
}

enum PlaybackTransitionError: Error { case pauseRejected, pauseTimeout }
