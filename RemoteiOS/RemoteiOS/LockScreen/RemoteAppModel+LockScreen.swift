import Foundation
import RemoteProtocol

/// Lock Screen card (Figma `212:304`). In the background iOS keeps no socket open, so a
/// button press reconnects briefly, sends one command and refreshes the card.
extension RemoteAppModel {
    /// Keeps the connection for quick repeated presses, then says bye.
    static let lockScreenIdleDelay: TimeInterval = 10
    static let lockScreenConnectTimeout: TimeInterval = 6
    static let lockScreenStateTimeout: TimeInterval = 1.5

    var lockScreenContent: LockScreenAttributes.ContentState? {
        guard hasState, state.hasMedia, let mac = selected?.name else { return nil }
        let music = state.source == .music ? state.music : nil
        let track = music?.track
        return .init(
            media: track == nil ? .video : .music,
            title: track?.title ?? state.title,
            subtitle: track.map { $0.artists.joined(separator: ", ") } ?? L10n.text("Video"),
            macName: mac,
            paused: state.paused || state.screensaver == .matrix,
            position: position,
            duration: state.duration,
            anchor: Date(),
            canPrevious: track == nil || state.canPrevious,
            canNext: track == nil || state.canNext,
            canVolume: state.source != .music || musicAllows("volume"),
            nextTitle: music?.nextTrack?.title,
            nextSubtitle: music?.nextTrack.map { $0.artists.joined(separator: ", ") })
    }

    /// Called whenever confirmed state arrives.
    func lockScreenStateChanged() {
        stateRevision &+= 1
        if lockScreenRequests == 0 || lockScreenVolumeTarget == state.volume {
            lockScreenVolumeTarget = nil
        }
        syncLockScreen()
    }

    func syncLockScreen() {
        guard let lockScreen else { return }
        guard lockScreenControls else {
            lockScreen.end()
            return
        }
        guard hasState else { return }  // Reconnecting keeps the last confirmed card.
        lockScreen.sync(lockScreenContent)
    }

    func lockScreenCommand(_ action: LockScreenAction) -> Command? {
        let step = 5.0
        switch action {
        case .previous: return .previous
        case .togglePause: return .togglePause
        case .next: return .next
        case .back10: return .seekRelative(seconds: -10)
        case .forward10: return .seekRelative(seconds: 10)
        case .volumeDown, .volumeUp:
            guard state.source != .music || musicAllows("volume") else { return nil }
            let value =
                (lockScreenVolumeTarget ?? state.volume)
                + (action == .volumeUp ? step : -step)
            return .setVolume(volume: min(100, max(0, value)))
        }
    }

    func performLockScreen(_ action: LockScreenAction) async {
        guard let lockScreen, lockScreenControls else { return }
        lockScreenRequests += 1
        defer {
            lockScreenRequests -= 1
            if lockScreenRequests == 0 {
                lockScreenVolumeTarget = nil
                if controlsEnabled {
                    lockScreen.finishSending()
                    syncLockScreen()
                } else {
                    lockScreen.markUnreachable()
                }
                scheduleLockScreenSessionEnd()
            }
        }
        lockScreen.markSending(action)
        if !controlsEnabled { beginLockScreenSession() }
        lockScreenIdle?.cancel()
        lockScreenIdle = nil
        let failed: Set<ConnectionState> = [.failed, .needsPairing, .incompatible, .idle]
        await waitForLockScreen(Self.lockScreenConnectTimeout) {
            self.controlsEnabled || failed.contains(self.connectionState)
        }
        guard controlsEnabled, let command = lockScreenCommand(action) else {
            if !controlsEnabled { lockScreen.markUnreachable() }
            return
        }
        if case .setVolume(let volume) = command { lockScreenVolumeTarget = volume }
        let revision = stateRevision
        let accepted = await withCheckedContinuation { continuation in
            send(command) { continuation.resume(returning: $0) }
        }
        if accepted {
            await waitForLockScreen(Self.lockScreenStateTimeout) {
                self.stateRevision != revision
            }
        }
    }

    /// Opens the network for a background button press, without touching navigation.
    func beginLockScreenSession() {
        guard !foreground else { return }
        lockScreenSession = true
        if monitorNetwork, lockScreenLease == nil {
            lockScreenLease = RemoteBackgroundLease { [weak self] in
                self?.endLockScreenSession()
            }
        }
        if !started {
            start()
            sceneActive = false
            return
        }
        foreground = true
        if isDemo {
            if screen == .remote { connectionState = .connected }
            syncDemo()
            return
        }
        startDiscovery()
        restoreSelected()
    }

    func scheduleLockScreenSessionEnd() {
        lockScreenIdle?.cancel()
        guard lockScreenSession else {
            lockScreenIdle = nil
            return
        }
        lockScreenIdle = scheduler.schedule(after: Self.lockScreenIdleDelay) { [weak self] in
            self?.endLockScreenSession()
        }
    }

    func endLockScreenSession() {
        lockScreenVolumeTarget = nil
        lockScreenIdle?.cancel()
        lockScreenIdle = nil
        let lease = lockScreenLease
        lockScreenLease = nil
        defer { lease?.end() }
        guard lockScreenSession else { return }
        lockScreenSession = false
        guard !sceneActive else { return }
        suspendNetwork()
    }

    /// Opening the remote takes over a live background session.
    func claimLockScreenSession() {
        guard lockScreenSession else { return }
        lockScreenSession = false
        lockScreenIdle?.cancel()
        lockScreenIdle = nil
        lockScreenLease?.end()
        lockScreenLease = nil
    }

    private func waitForLockScreen(_ timeout: TimeInterval, _ done: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(timeout * 1000)))
        while !done(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
}
