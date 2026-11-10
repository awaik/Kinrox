import Foundation

/// Serializes request starts, including retries and calls from different discovery tasks.
public actor MusicBrainzRateLimiter {
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var lastStart: Date?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.now = now
        self.sleep = sleep
    }

    public func perform<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T
    {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        if let lastStart {
            let delay = 1 - now().timeIntervalSince(lastStart)
            if delay > 0 { try await sleep(delay) }
        }
        try Task.checkCancellation()
        lastStart = now()
        return try await operation()
    }
}
