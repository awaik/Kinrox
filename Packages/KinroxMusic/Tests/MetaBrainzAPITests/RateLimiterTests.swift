import Foundation
import Testing

@testable import MetaBrainzAPI

struct RateLimiterTests {
    final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var time: TimeInterval = 0
        var starts: [TimeInterval] = []
        func now() -> Date { lock.withLock { Date(timeIntervalSince1970: time) } }
        func sleep(_ interval: TimeInterval) { lock.withLock { time += interval } }
        func record() { lock.withLock { starts.append(time) } }
    }
    @Test func spacesConcurrentStartsByOneSecond() async throws {
        let clock = Clock()
        let limiter = MusicBrainzRateLimiter(now: { clock.now() }, sleep: { clock.sleep($0) })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { try await limiter.perform { clock.record() } } }
            try await group.waitForAll()
        }
        #expect(clock.starts == [0, 1, 2, 3, 4])
    }
}
