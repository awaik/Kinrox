import Foundation
import RemoteProtocol
import RemoteTransport

extension RemoteAppModel {
    struct PendingCommand {
        let command: Command
        let completion: ((Bool) -> Void)?
        let timeout: any RemoteCancellation
    }

    func receiveMessage(_ message: Message) {
        guard connectionState == .connected else { return }
        switch message {
        case .state(_, let state):
            guard state.position.isFinite, state.duration.isFinite, state.volume.isFinite,
                state.position >= 0, state.duration >= 0, (0...100).contains(state.volume)
            else {
                connectionLost(.invalidMessage)
                return
            }
            if self.state.title != state.title || !state.hasMedia { scrubTarget = nil }
            self.state = state
            receivedAt = scheduler.now
            frozenPosition = min(state.duration, state.position)
            hasState = true
        case .recent(_, let items): recents = items
        case .ack(_, let ack):
            guard let request = pending.removeValue(forKey: ack.replyTo) else { return }
            request.timeout.cancel()
            request.completion?(true)  // Acceptance only; player state unchanged.
        case .error(_, let error):
            if error.code == .authFailed || error.code == .notPaired {
                connectionLost(.protocolFailure(error))
                return
            }
            if let replyTo = error.replyTo {
                guard let request = pending.removeValue(forKey: replyTo) else { return }
                request.timeout.cancel()
                if case .openRecent(let id) = request.command, error.code == .itemNotFound,
                    let index = recents.firstIndex(where: { $0.id == id })
                {
                    recents[index].available = false
                }
                request.completion?(false)
            }
            commandError = Self.message(for: error)
        default: break
        }
    }

    @discardableResult
    func send(_ command: Command, completion: ((Bool) -> Void)? = nil) -> UUID? {
        guard controlsEnabled else {
            completion?(false)
            return nil
        }
        if isDemo {
            performDemo(command)
            completion?(true)
            return UUID()
        }
        guard let client else {
            completion?(false)
            return nil
        }
        guard pending.count < 32 else {
            commandError = L10n.text(
                "Mac is still processing commands. Wait for response and retry.")
            completion?(false)
            return nil
        }
        let header = Message.Header()
        let attempt = epoch
        let timeout = scheduler.schedule(after: 15) { [weak self] in
            guard let self, self.epoch == attempt,
                let request = self.pending.removeValue(forKey: header.id)
            else { return }
            self.commandError = L10n.text("Mac did not confirm command. Check player state.")
            request.completion?(false)
        }
        pending[header.id] = PendingCommand(
            command: command, completion: completion, timeout: timeout)
        tasks[header.id] = Task { [weak self] in
            guard let self, self.epoch == attempt, !Task.isCancelled else { return }
            do { try await client.send(.command(header, command)) } catch {
                if self.epoch == attempt {
                    self.connectionLost(error as? TransportFailure ?? .closed)
                }
            }
            self.tasks[header.id] = nil
        }
        return header.id
    }

    func togglePause() { if state.hasMedia { send(.togglePause) } }
    func seek(by seconds: Double) {
        guard state.hasMedia, seconds.isFinite else { return }
        send(.seekRelative(seconds: seconds))
    }
    func seek(to seconds: Double) {
        guard state.hasMedia, seconds.isFinite else { return }
        send(.seekAbsolute(seconds: min(state.duration, max(0, seconds))))
    }
    func next() { if canNext { send(.next) } }
    func previous() { if canPrevious { send(.previous) } }
    func toggleFullscreen() { send(.toggleFullscreen) }
    func open(_ item: RecentItem, completion: @escaping (Bool) -> Void) {
        guard item.available else {
            commandError = L10n.text("File not found on Mac.")
            completion(false)
            return
        }
        send(.openRecent(itemId: item.id), completion: completion)
    }

    /// Last value is not lost on release. Even final frame respects 10 Hz.
    func setVolume(_ value: Double) {
        guard controlsEnabled, value.isFinite else { return }
        pendingVolume = min(100, max(0, value))
        let delay = max(0, 0.1 - (scheduler.now - lastVolumeSent))
        if delay <= 0.000_001 {
            flushVolume()
        } else if volumeTimer == nil {
            let attempt = epoch
            volumeTimer = scheduler.schedule(after: delay) { [weak self] in
                guard let self, self.epoch == attempt else { return }
                self.volumeTimer = nil
                self.flushVolume()
            }
        }
    }
    func flushVolume() {
        volumeTimer?.cancel()
        volumeTimer = nil
        guard controlsEnabled, let value = pendingVolume else {
            pendingVolume = nil
            return
        }
        pendingVolume = nil
        lastVolumeSent = scheduler.now
        send(.setVolume(volume: value))
    }
}
