import Foundation

public enum SpotifyRequestPriority: Int, Sendable { case control, interactive, background }

/// A resource revision prevents revalidation from joining an older, pre-mutation read.
public enum SpotifyRequestContext {
    @TaskLocal public static var priority: SpotifyRequestPriority = .interactive
    @TaskLocal public static var revision: String = ""
}

/// Owned by SpotifyClient's actor. One slot is always reserved for playback control.
struct SpotifyRequestScheduler {
    struct Waiter {
        let id: UUID
        let priority: SpotifyRequestPriority
        let continuation: CheckedContinuation<Void, any Error>
    }
    var active = 0
    var nonControl = 0
    var waiters: [Waiter] = []

    mutating func enqueue(_ waiter: Waiter) {
        waiters.append(waiter)
        drain()
    }
    mutating func release(_ priority: SpotifyRequestPriority) {
        active -= 1
        if priority != .control { nonControl -= 1 }
        drain()
    }
    mutating func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    mutating func close() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: CancellationError()) }
    }
    private mutating func drain() {
        while active < 3 {
            guard
                let index = waiters.indices.filter({
                    waiters[$0].priority == .control || nonControl < 2
                }).min(by: { waiters[$0].priority.rawValue < waiters[$1].priority.rawValue })
            else { return }
            let waiter = waiters.remove(at: index)
            active += 1
            if waiter.priority != .control { nonControl += 1 }
            waiter.continuation.resume()
        }
    }
}

public struct SpotifyResource<Value: Sendable>: Sendable {
    /// nil means HTTP 304: the store retains its typed data and renews freshness.
    public let value: Value?
    public let etag: String?
}

struct SpotifyHTTPResponse: Sendable {
    let data: Data
    let etag: String?
    let notModified: Bool
}
