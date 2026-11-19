import Foundation
import os

// handle is immutable; wait_event is called by one Thread, stopRequested protected by lock.
// Owner destroys handle only after stopAndWait().
final class MPVEventLoop: @unchecked Sendable {
    private let handle: OpaquePointer
    private let receive: (mpv_event) -> Bool
    private let finish: () -> Void
    private let lock = NSLock()
    private let finished = DispatchGroup()
    private var stopRequested = false

    convenience init(handle: OpaquePointer, continuation: AsyncStream<PlaybackEvent>.Continuation) {
        let delivery = VideoEventDelivery(handle: handle, continuation: continuation)
        self.init(handle: handle, receive: delivery.receive, finish: { continuation.finish() })
    }

    init(
        handle: OpaquePointer, receive: @escaping (mpv_event) -> Bool, finish: @escaping () -> Void
    ) {
        self.handle = handle
        self.receive = receive
        self.finish = finish
    }

    func start() {
        finished.enter()
        let thread = Thread { [self] in run() }
        thread.name = "kinrox.mpv.events"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stopAndWait() {
        lock.withLock { stopRequested = true }
        mpv_wakeup(handle)
        finished.wait()
    }

    private func run() {
        defer {
            finish()
            finished.leave()
        }
        while !lock.withLock({ stopRequested }) {
            guard let pointer = mpv_wait_event(handle, -1) else { continue }
            if !receive(pointer.pointee) { return }
        }
    }
}

private final class VideoEventDelivery {
    private let handle: OpaquePointer
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let logger = Logger(subsystem: "app.kinrox.player", category: "mpv")
    private var lastPositionLog = -Double.infinity

    init(handle: OpaquePointer, continuation: AsyncStream<PlaybackEvent>.Continuation) {
        self.handle = handle
        self.continuation = continuation
    }

    func receive(_ event: mpv_event) -> Bool {
        if event.event_id == MPV_EVENT_LOG_MESSAGE, let data = event.data {
            let log = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            let prefix = log.prefix.map { String(cString: $0) } ?? "mpv"
            let message = log.text.map { String(cString: $0) } ?? ""
            logger.warning("[\(prefix, privacy: .public)] \(message, privacy: .private)")
        }
        guard let copied = MPVEvent.copy(event) else { return true }
        if case .property(let key, let value) = copied {
            let now = ProcessInfo.processInfo.systemUptime
            if key == .position, value == .unavailable { lastPositionLog = -Double.infinity }
            if key != .position || now - lastPositionLog >= 1 {
                if key == .position, case .number = value { lastPositionLog = now }
                if key == .title || key == .tracks {
                    logger.info(
                        "\(key.rawValue, privacy: .public): \(String(describing: value), privacy: .private)"
                    )
                } else {
                    logger.info(
                        "\(key.rawValue, privacy: .public): \(String(describing: value), privacy: .public)"
                    )
                }
            }
        }
        continuation.yield(copied)
        if copied == .loaded, let snapshot = MPVTracks.loadedSnapshot(handle: handle) {
            continuation.yield(snapshot)
        }
        return copied != .shutdown
    }
}
