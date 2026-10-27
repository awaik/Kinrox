import Foundation

struct Heartbeat {
    enum Action { case none, ping, timeout }
    let interval: Duration
    let timeout: Duration
    private var lastReceived: ContinuousClock.Instant
    private var nextPing: ContinuousClock.Instant

    init(now: ContinuousClock.Instant, interval: Duration, timeout: Duration) {
        self.interval = interval
        self.timeout = timeout
        lastReceived = now
        nextPing = now.advanced(by: interval)
    }

    mutating func received(at now: ContinuousClock.Instant) { lastReceived = now }

    mutating func tick(at now: ContinuousClock.Instant) -> Action {
        if lastReceived.duration(to: now) >= timeout { return .timeout }
        if now >= nextPing {
            nextPing = now.advanced(by: interval)
            return .ping
        }
        return .none
    }
}
