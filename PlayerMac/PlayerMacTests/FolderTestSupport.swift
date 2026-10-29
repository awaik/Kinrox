import Foundation
import Testing

@testable import Kinrox

enum FolderTestError: Error { case unreadable, timeout }

@MainActor
func waitForFolder(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw FolderTestError.timeout }
        await Task.yield()
    }
}

/// Every delay is released explicitly; no wall-clock debounce assumptions in unit tests.
actor FolderTestClock {
    private var sleepers: [(UUID, Duration, CheckedContinuation<Void, Error>)] = []

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { sleepers.append((id, duration, $0)) }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.0 == id }) else { return }
        sleepers.remove(at: index).2.resume(throwing: CancellationError())
    }

    func advance(_ duration: Duration = .milliseconds(250)) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !sleepers.contains(where: { $0.1 == duration }) {
            guard ContinuousClock.now < deadline else { throw FolderTestError.timeout }
            await Task.yield()
        }
        let index = sleepers.firstIndex(where: { $0.1 == duration })!
        sleepers.remove(at: index).2.resume()
    }

    var pending: [Duration] { sleepers.map(\.1) }
}

/// Enumeration can be held after taking a snapshot to reproduce stale completions.
final class FolderTestDriver: @unchecked Sendable {
    private let lock = NSCondition()
    private var contents: [URL] = []
    private var fails = false
    private var held = false
    private var unavailable = false
    private var continuations: [AsyncStream<FolderWatchEvent>.Continuation] = []
    private var scanCount = 0
    private var inFlight = 0
    private var maximumInFlight = 0
    private var terminationCount = 0
    private var watchedFolders: [URL] = []
    let clock = FolderTestClock()

    var scans: Int { lock.withLock { scanCount } }
    var active: Int { lock.withLock { inFlight } }
    var maxActive: Int { lock.withLock { maximumInFlight } }
    var watches: [URL] { lock.withLock { watchedFolders } }
    var terminations: Int { lock.withLock { terminationCount } }

    func setItems(_ items: [URL], fails: Bool = false) {
        lock.withLock {
            contents = items
            self.fails = fails
        }
    }

    func holdScans(_ hold: Bool) {
        lock.withLock {
            held = hold
            lock.broadcast()
        }
    }

    func setWatchUnavailable(_ unavailable: Bool) {
        lock.withLock { self.unavailable = unavailable }
    }

    func send(_ event: FolderWatchEvent = .changed) {
        let continuation = lock.withLock { continuations.last }
        continuation?.yield(event)
        if case .invalidated = event { continuation?.finish() }
    }

    private func scan(_ folder: URL) throws -> [URL] {
        lock.lock()
        scanCount += 1
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        let items = contents
        let fails = fails
        #expect(watchedFolders.contains(folder), "Watch must be registered before enumeration")
        while held { lock.wait() }
        inFlight -= 1
        lock.unlock()
        if fails { throw FolderTestError.unreadable }
        return items
    }

    private func watch(_ folder: URL) -> AsyncStream<FolderWatchEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.terminationCount += 1 }
            }
            let unavailable = lock.withLock {
                watchedFolders.append(folder)
                continuations.append(continuation)
                return self.unavailable
            }
            if unavailable { continuation.finish() }
        }
    }

    var dependencies: FolderMonitor.Dependencies {
        FolderMonitor.Dependencies(
            scan: { [self] in try scan($0) }, watch: { [self] in watch($0) },
            sleep: { [clock] in try await clock.sleep($0) }, isReachable: { _ in true })
    }
}

/// Only this UUID directory and files created by the test may be removed.
struct LivePlaylistFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "kinrox-live-playlist-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ name: String) throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data("test".utf8).write(to: file)
        return file
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}
