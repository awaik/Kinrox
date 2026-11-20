import Foundation
import ImageIO
import RemoteProtocol
import UniformTypeIdentifiers

/// Encodes and caches remote-sized artwork JPEGs off the main actor.
actor RemoteArtworkService {
    static let maxBytes = 40_000
    private static let qualities: [Double] = [0.75, 0.58, 0.42, 0.28, 0.18]

    private let artwork: ArtworkCache
    private let cache = NSCache<NSString, NSData>()

    init(artwork: ArtworkCache) {
        self.artwork = artwork
        cache.countLimit = 200
        cache.totalCostLimit = 4 * 1024 * 1024
    }

    func jpeg(forKey key: String, maxPixel: Int) async -> Data? {
        let clamped = min(360, max(64, maxPixel))
        let cacheKey = "\(key)|\(clamped)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached as Data }
        guard !Task.isCancelled, let raw = await artwork.thumbnailForRemote(key), !Task.isCancelled
        else {
            return nil
        }
        let encoded = await Self.encodeOffActor(raw, maxPixel: clamped)
        guard !Task.isCancelled, let encoded, encoded.count <= Self.maxBytes else { return nil }
        cache.setObject(encoded as NSData, forKey: cacheKey, cost: encoded.count)
        return encoded
    }

    private nonisolated static func encodeOffActor(_ raw: Data, maxPixel: Int) async -> Data? {
        encodeJPEG(raw, maxPixel: maxPixel)
    }

    nonisolated static func encodeJPEG(_ raw: Data, maxPixel: Int) -> Data? {
        autoreleasepool {
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard
                let source = CGImageSourceCreateWithData(
                    raw as CFData, sourceOptions as CFDictionary)
            else { return nil }
            let steps = [maxPixel, max(32, maxPixel / 2)]
            for pixel in steps {
                guard !Task.isCancelled else { return nil }
                let encoded: Data? = autoreleasepool {
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: pixel,
                        kCGImageSourceShouldCache: false,
                        kCGImageSourceShouldCacheImmediately: false,
                    ]
                    guard
                        let image = CGImageSourceCreateThumbnailAtIndex(
                            source, 0, options as CFDictionary)
                    else { return nil }
                    for quality in qualities {
                        guard !Task.isCancelled else { return nil }
                        let attempt: Data? = autoreleasepool {
                            let output = NSMutableData()
                            guard
                                let destination = CGImageDestinationCreateWithData(
                                    output, UTType.jpeg.identifier as CFString, 1, nil)
                            else { return nil }
                            CGImageDestinationAddImage(
                                destination, image,
                                [kCGImageDestinationLossyCompressionQuality: quality]
                                    as CFDictionary)
                            guard CGImageDestinationFinalize(destination) else { return nil }
                            let data = output as Data
                            return data.count <= maxBytes ? data : nil
                        }
                        if let attempt { return attempt }
                    }
                    return nil
                }
                if let encoded { return encoded }
            }
            return nil
        }
    }
}

/// Per-connection bounded artwork scheduler with outbox backpressure.
/// Caps concurrent ImageIO work to 4, queued requests to 64, and waits while outbox has >= 16 items.
@MainActor
final class RemoteArtworkScheduler {
    static let maxConcurrent = 4
    static let maxQueued = 64
    static let maxReady = 512
    static let outboxHighWater = 16

    private struct Item {
        let replyTo: UUID
        let id: String
        let artworkKey: String
        let maxPixel: Int
    }

    private final class ConnectionQueue {
        weak var outbox: RemoteOutbox?
        var pending: [Item] = []
        var ready: [Message] = []
        var inFlight: [UUID: Task<Void, Never>] = [:]
        var cancelled = false

        init(outbox: RemoteOutbox) { self.outbox = outbox }
    }

    private let service: RemoteArtworkService
    private var queues: [UUID: ConnectionQueue] = [:]

    init(service: RemoteArtworkService) {
        self.service = service
    }

    func enqueue(
        connectionId: UUID, replyTo: UUID, id: String, artworkKey: String?, maxPixel: Int,
        outbox: RemoteOutbox
    ) {
        let queue = queue(for: connectionId, outbox: outbox)
        guard let artworkKey else {
            appendReady(.artwork(.init(), .init(replyTo: replyTo, id: id, jpeg: nil)), to: queue)
            pump(connectionId)
            return
        }
        guard queue.pending.count < Self.maxQueued else {
            appendReady(.artwork(.init(), .init(replyTo: replyTo, id: id, jpeg: nil)), to: queue)
            pump(connectionId)
            return
        }
        queue.pending.append(
            Item(replyTo: replyTo, id: id, artworkKey: artworkKey, maxPixel: maxPixel))
        pump(connectionId)
    }

    func notifyDrained(connectionId: UUID) {
        pump(connectionId)
    }

    func cancel(connectionId: UUID) {
        guard let queue = queues.removeValue(forKey: connectionId) else { return }
        queue.cancelled = true
        for task in queue.inFlight.values { task.cancel() }
        queue.inFlight.removeAll()
        queue.pending.removeAll()
        queue.ready.removeAll()
    }

    func cancelAll() {
        for id in Array(queues.keys) { cancel(connectionId: id) }
    }

    private func queue(for connectionId: UUID, outbox: RemoteOutbox) -> ConnectionQueue {
        if let existing = queues[connectionId], existing.outbox === outbox { return existing }
        cancel(connectionId: connectionId)
        let created = ConnectionQueue(outbox: outbox)
        queues[connectionId] = created
        return created
    }

    private func appendReady(_ message: Message, to queue: ConnectionQueue) {
        if queue.ready.count < Self.maxReady {
            queue.ready.append(message)
        } else {
            // Bounded backpressure: escalate stalled overflow to RemoteOutbox instead of dropping.
            queue.outbox?.enqueue(message)
        }
    }

    private func pump(_ connectionId: UUID) {
        guard let queue = queues[connectionId], !queue.cancelled, let outbox = queue.outbox else {
            return
        }
        while !queue.ready.isEmpty, outbox.pendingCount < Self.outboxHighWater {
            outbox.enqueue(queue.ready.removeFirst())
        }
        while queue.inFlight.count < Self.maxConcurrent,
            queue.ready.count < Self.outboxHighWater,
            !queue.pending.isEmpty
        {
            let item = queue.pending.removeFirst()
            let taskId = UUID()
            let service = service
            queue.inFlight[taskId] = Task { [weak self, weak queue] in
                let data = await service.jpeg(forKey: item.artworkKey, maxPixel: item.maxPixel)
                guard let self, let queue, self.queues[connectionId] === queue, !queue.cancelled,
                    !Task.isCancelled
                else { return }
                queue.inFlight[taskId] = nil
                self.appendReady(
                    .artwork(.init(), .init(replyTo: item.replyTo, id: item.id, jpeg: data)),
                    to: queue)
                self.pump(connectionId)
            }
        }
    }
}
