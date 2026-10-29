import AppKit
import Darwin
import Foundation

enum FolderWatchEvent: Sendable {
    case changed, invalidated
}

/// One serial enumeration worker; watcher events only invalidate its snapshot.
@MainActor
final class FolderMonitor {
    struct Dependencies: Sendable {
        var scan: @Sendable (URL) throws -> [URL] = FolderPlaylist.scanItems
        var watch: @Sendable (URL) -> AsyncStream<FolderWatchEvent> = FolderMonitor.watch
        var sleep: @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0, clock: .suspending)
        }
        var isReachable: @Sendable (URL) -> Bool = { (try? $0.checkResourceIsReachable()) == true }
    }

    let folder: URL
    private let dependencies: Dependencies
    private let publish: (Result<[URL], Error>) -> Void
    private let signal: AsyncStream<Void>.Continuation
    private var worker: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var coalescing: Task<Void, Error>?
    private var wakeObserver: NSObjectProtocol?
    private var waiters: [UUID: CheckedContinuation<[URL]?, Never>] = [:]
    private var needsRescan = true
    private var immediate = true
    private var scanning = false
    private var invalidated = false
    private var lastScanFailed = false
    private var stopped = false

    var isDirty: Bool { needsRescan || scanning || invalidated || lastScanFailed }

    init(
        folder: URL, dependencies: Dependencies = Dependencies(),
        publish: @escaping (Result<[URL], Error>) -> Void
    ) {
        self.folder = folder
        self.dependencies = dependencies
        self.publish = publish
        let (signals, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.signal = signal
        // Register before the initial enumeration, including events during that enumeration.
        let initialStream = dependencies.watch(folder)
        watcher = Task { [weak self] in
            var stream = initialStream
            while !Task.isCancelled {
                var invalidated = false
                for await event in stream {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .changed: self?.requestRescan()
                    case .invalidated:
                        invalidated = true
                        self?.invalidated = true
                    }
                }
                guard !Task.isCancelled else { return }
                do {
                    try await dependencies.sleep(invalidated ? .milliseconds(250) : .seconds(10))
                } catch { return }
                guard !Task.isCancelled else { return }
                stream = dependencies.watch(folder)
                self?.invalidated = false
                self?.requestRescan(immediately: true)
            }
        }
        worker = Task { [weak self] in
            for await _ in signals {
                guard !Task.isCancelled else { return }
                await self?.drain()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.requestRescan(immediately: true) }
        }
        signal.yield(())
    }

    isolated deinit { stop() }

    func requestRescan(immediately: Bool = false) {
        guard !stopped else { return }
        needsRescan = true
        immediate = immediate || immediately
        if immediately { coalescing?.cancel() }
        signal.yield(())
    }

    /// EOF shares the worker, so it cannot race another enumeration's publication.
    func refresh() async -> [URL]? {
        guard !stopped, !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            waiters[UUID()] = continuation
            requestRescan(immediately: true)
        }
    }

    private func drain() async {
        while needsRescan, !stopped, !Task.isCancelled {
            if !immediate {
                let sleep = dependencies.sleep
                let delay = Task { try await sleep(.milliseconds(250)) }
                coalescing = delay
                do { try await delay.value } catch {
                    guard immediate, !stopped, !Task.isCancelled else { return }
                }
                coalescing = nil
            }
            guard !stopped, !Task.isCancelled else { return }
            needsRescan = false
            immediate = false
            scanning = true
            let pending = Set(waiters.keys)
            let scan = dependencies.scan
            let folder = folder
            let result = await Task.detached(priority: .utility) {
                Result { try scan(folder) }
            }.value
            scanning = false
            guard !stopped, !Task.isCancelled else { return }
            let items = try? result.get()
            lastScanFailed = items == nil
            publish(result)
            for id in pending {
                waiters.removeValue(forKey: id)?.resume(returning: items)
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        watcher?.cancel()
        worker?.cancel()
        coalescing?.cancel()
        signal.finish()
        for continuation in waiters.values { continuation.resume(returning: nil) }
        waiters.removeAll()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// The source alone owns its descriptor, including cancellation during event delivery.
    nonisolated static func watch(_ folder: URL) -> AsyncStream<FolderWatchEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let descriptor = open(folder.path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                continuation.finish()
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .link, .delete, .rename, .revoke],
                queue: .global(qos: .utility))
            source.setEventHandler { [weak source] in
                guard let source else { return }
                if !source.data.intersection([.delete, .rename, .revoke]).isEmpty {
                    continuation.yield(.invalidated)
                    continuation.finish()
                } else {
                    continuation.yield(.changed)
                }
            }
            source.setCancelHandler { close(descriptor) }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }
}
