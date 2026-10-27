import Foundation
import RemoteProtocol

/// Regular position progress throttled to 2 Hz; confirmed transitions sent immediately.
@MainActor
final class RemoteStatePublisher {
    private var last: PlayerState?
    private var lastTime = -Double.infinity
    private var pending: PlayerState?
    private var timer: Task<Void, Never>?
    private let now: () -> TimeInterval
    private let publish: (PlayerState) -> Void

    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        publish: @escaping (PlayerState) -> Void
    ) {
        self.now = now
        self.publish = publish
    }

    func update(_ state: PlayerState, immediate: Bool = false) {
        if state == last, !immediate {
            pending = nil
            return
        }
        let time = now()
        let positionOnly =
            last.map { previous in
                PlayerState(
                    title: state.title, position: previous.position, duration: state.duration,
                    paused: state.paused, volume: state.volume, fullscreen: state.fullscreen,
                    hasMedia: state.hasMedia, canNext: state.canNext, canPrevious: state.canPrevious
                ) == previous
            } ?? false
        if immediate || !positionOnly || time - lastTime >= 0.5 {
            timer?.cancel()
            timer = nil
            pending = nil
            last = state
            lastTime = time
            publish(state)
        } else {
            pending = state
            guard timer == nil else { return }
            let delay = max(0, 0.5 - (time - lastTime))
            timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self else { return }
                self.timer = nil
                if let pending = self.pending { self.update(pending, immediate: true) }
            }
        }
    }

    func cancelPending() {
        timer?.cancel()
        timer = nil
        pending = nil
    }

    func reset() {
        cancelPending()
        last = nil
        lastTime = -Double.infinity
    }

    deinit { timer?.cancel() }
}
