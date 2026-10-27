import Foundation

@MainActor
protocol RemoteCancellation: AnyObject { func cancel() }

/// Single monotonic clock for position, retries, command timeouts, and volume.
@MainActor
protocol RemoteScheduler: AnyObject {
    var now: TimeInterval { get }
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void)
        -> any RemoteCancellation
}

@MainActor
final class LiveRemoteScheduler: RemoteScheduler {
    private let origin = ContinuousClock.now
    var now: TimeInterval {
        let duration = origin.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void)
        -> any RemoteCancellation
    {
        ScheduledTask(delay: delay, action: action)
    }
}

@MainActor
private final class ScheduledTask: RemoteCancellation {
    private var task: Task<Void, Never>?
    init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        task = Task {
            do { try await Task.sleep(for: .seconds(max(0, delay))) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
    }
    func cancel() {
        task?.cancel()
        task = nil
    }
    deinit { task?.cancel() }
}

struct RemoteRetryPolicy {
    static let timeout: TimeInterval = 120
    static func delay(at attempt: Int) -> TimeInterval {
        let initial: [TimeInterval] = [0.5, 1, 2, 4, 8]
        return initial.indices.contains(attempt) ? initial[attempt] : 10
    }
}
