import Foundation
import os

// Immutable resources accessible to owner on MainActor. After beginShutdown()
// owner ceases commands; background deallocation runs exactly once.
final class MPVLifetime: @unchecked Sendable {
    let handle: OpaquePointer
    let eventLoop: MPVEventLoop
    let videoLayer: VideoLayer
    private let lock = NSLock()
    private var closing = false
    private let finished = DispatchGroup()

    init(handle: OpaquePointer, eventLoop: MPVEventLoop, videoLayer: VideoLayer) {
        self.handle = handle
        self.eventLoop = eventLoop
        self.videoLayer = videoLayer
        finished.enter()
    }

    func beginShutdown() {
        let shouldClose = lock.withLock {
            guard !closing else { return false }
            closing = true
            return true
        }
        guard shouldClose else { return }
        // Main thread remains free: Core Animation can finalize its display.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            videoLayer.resources.shutdown()
            eventLoop.stopAndWait()
            mpv_terminate_destroy(handle)
            Logger(subsystem: "app.kinrox.player", category: "lifecycle")
                .info("mpv core stopped")
            finished.leave()
        }
    }

    func waitForShutdown() async {
        beginShutdown()
        await withCheckedContinuation { continuation in
            finished.notify(queue: .global()) { continuation.resume() }
        }
    }
}
