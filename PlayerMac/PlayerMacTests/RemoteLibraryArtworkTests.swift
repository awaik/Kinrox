import AppKit
import Foundation
import MetaBrainzAPI
import RemoteProtocol
import RemoteTransport
import Testing

@testable import Kinrox

@Suite(
    "Remote library artwork bursts, ad-hoc audio cover, and disconnect cancellation", .serialized)
@MainActor
struct RemoteLibraryArtworkTests {
    @Test("55 pipelined warm and cold artwork bursts, ad-hoc audio cover, and disconnect cancel")
    func artworkBurstAdHocAndCancel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KinroxRemoteArt-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: "app.kinrox.tests.art.\(UUID())"))
        let recents = RecentFilesStore(fileURL: root.appendingPathComponent("recents.json"))
        let store = MediaLibraryStore(
            limiter: MusicBrainzRateLimiter(), defaults: defaults, storage: (root, root))
        let audio = LocalAudioViewModel(artwork: store.artwork, initialVolume: 0) { _ in
            FakeArtworkAudioEngine()
        }
        let server = RemoteServer(
            defaults: defaults, store: MemoryPairedDevices(), recents: recents,
            pairing: PairingCenter(), serverName: "Kinrox-Art-\(UUID().uuidString.prefix(6))")

        let noisyKey = try #require(try await store.artwork.store(makeNoisyPNG(size: 480)))
        let adHocKey = try #require(try await store.artwork.store(makeNoisyPNG(size: 120)))
        let now = Date()
        var files: [MediaLibraryFile] = []
        var meta: [String: MediaEnrichment] = [:]
        for i in 0..<55 {
            let file = MediaLibraryFile(
                path: root.appendingPathComponent("M\(i).mkv").path, size: 1, modified: now,
                added: now, video: VideoTitle(title: "M\(i)"))
            files.append(file)
            if i < 50 {
                meta[file.metadataKey!] = MediaEnrichment(title: "M\(i)", posterPath: noisyKey)
            }
        }
        store.snapshot = MediaLibraryDatabase.Snapshot(files: files, metadata: meta)
        server.connectLocalAudio(audio) { true }
        server.connectLibrary(store)

        // Ad-hoc audio file outside watched folders resolves its cached artwork via opaque track ID
        let adHocTrack = LocalAudioTrack(
            file: MediaLibraryFile(
                path: root.appendingPathComponent("Outside.flac").path, size: 100, modified: now,
                added: now,
                audio: LocalAudioTags(
                    title: "Outside", artist: "Solo", duration: 90, artworkPath: adHocKey)),
            metadata: nil, isOffline: false)
        #expect(audio.play([adHocTrack]))
        try await waitForRemote { audio.currentTrack?.title == "Outside" }
        let ids = try #require(server.libraryBridge?.ids)
        let adHocId = ids.id(kind: .track, key: adHocTrack.id)
        #expect(server.libraryBridge?.artworkKey(for: adHocId) == adHocKey)

        let browser = BonjourBrowser()
        var received: [UUID: ArtworkResponse] = [:]
        var clients: [TransportClient] = []
        defer {
            for client in clients { client.close() }
            browser.stop()
            server.stop()
        }
        server.start(monitorSystem: false)
        browser.start()
        try await waitForRemote {
            server.isOnline
                && browser.servers.contains { $0.id == server.serverId && $0.isAvailable }
        }
        let discovered = try #require(
            browser.servers.first { $0.id == server.serverId && $0.isAvailable })
        let client = try TransportClient(
            server: discovered, deviceId: UUID(), deviceName: "iPhone", appVersion: "1.0",
            mode: .pair, saveToken: { _ in })
        clients.append(client)
        client.onEvent = {
            if case .message(.artwork(_, let resp)) = $0 { received[resp.replyTo] = resp }
        }
        client.start()
        try await waitForRemote { client.state == .awaitingPIN && server.pairing.prompt != nil }
        try await client.submitPIN(#require(server.pairing.prompt?.code))
        try await waitForRemote { client.state == .connected }

        var sentIds: [(UUID, Bool)] = []
        for i in 0..<55 {
            let header = Message.Header()
            let itemId = ids.id(kind: .movie, key: files[i].path)
            sentIds.append((header.id, i < 50))
            try await client.send(.requestArtwork(header, .init(id: itemId, maxPixel: 360)))
        }
        let adHocHeader = Message.Header()
        sentIds.append((adHocHeader.id, true))
        try await client.send(.requestArtwork(adHocHeader, .init(id: adHocId, maxPixel: 200)))

        try await waitForRemote { received.count == 56 }
        #expect(client.state == .connected)
        for (reqId, hasArt) in sentIds {
            let reply = try #require(received[reqId])
            if hasArt {
                let jpeg = try #require(reply.jpeg)
                #expect(!jpeg.isEmpty && jpeg.count <= 40_000)
            } else {
                #expect(reply.jpeg == nil)
            }
        }

        // Disconnect mid-burst cancels cleanly without crashing or leaving stray connections
        for i in 0..<20 {
            let itemId = ids.id(kind: .movie, key: files[i].path)
            try await client.send(.requestArtwork(.init(), .init(id: itemId, maxPixel: 180)))
        }
        client.close()
        try await waitForRemote { server.connectedDevices.isEmpty }
        await audio.shutdownPlayback()
    }

    @Test(
        "Artwork scheduler handles >128 nil replies without drops and duplicate client replyTo IDs")
    func schedulerOverflowAndDuplicateReplyTo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KinroxRemoteArtSched-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ArtworkCache(directory: root)
        let png = makeNoisyPNG(size: 160)
        let key = try #require(try await cache.store(png))
        // Non-caching remote read succeeds and returns the stored JPEG bytes
        let remoteBytes = try #require(await cache.thumbnailForRemote(key))
        #expect(!remoteBytes.isEmpty)

        let service = RemoteArtworkService(artwork: cache)
        let scheduler = RemoteArtworkScheduler(service: service)
        let connId = UUID()
        var sent: [Message] = []
        var failed = false
        let outbox = RemoteOutbox(
            send: { message in
                await Task.yield()
                sent.append(message)
            },
            failed: { failed = true })
        outbox.onDrained = { scheduler.notifyDrained(connectionId: connId) }

        // Pipeline 160 artworkKey==nil requests: none should be silently dropped
        for i in 0..<160 {
            scheduler.enqueue(
                connectionId: connId, replyTo: UUID(), id: "m_\(i)", artworkKey: nil,
                maxPixel: 200, outbox: outbox)
        }
        try await waitForRemote { sent.count == 160 }
        #expect(!failed)

        // Duplicate client replyTo IDs do not overwrite inFlight tasks or fail cancellation
        sent.removeAll()
        let duplicateReplyTo = UUID()
        for i in 0..<4 {
            scheduler.enqueue(
                connectionId: connId, replyTo: duplicateReplyTo, id: "dup_\(i)", artworkKey: key,
                maxPixel: 200, outbox: outbox)
        }
        try await waitForRemote { sent.count == 4 }
        #expect(!failed)
        scheduler.cancel(connectionId: connId)
        outbox.close()
    }

    private func makeNoisyPNG(size: Int) -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        if let ptr = bitmap.bitmapData {
            var state: UInt64 = 0x1234_5678_9ABC_DEF0
            for i in 0..<(bitmap.bytesPerRow * size) {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                ptr[i] = UInt8(truncatingIfNeeded: state >> 56)
            }
        }
        return bitmap.representation(using: .png, properties: [:])!
    }
}

@MainActor
private final class FakeArtworkAudioEngine: LocalAudioEngine {
    let events: AsyncStream<LocalAudioEvent>
    let continuation: AsyncStream<LocalAudioEvent>.Continuation
    init() { (events, continuation) = AsyncStream.makeStream() }
    func load(_ url: URL, id: UUID, position: Double) throws { continuation.yield(.loaded(id)) }
    func setPaused(_ paused: Bool) throws {}
    func seek(_ position: Double) throws {}
    func setVolume(_ volume: Double) throws {}
    func shutdown() async { continuation.finish() }
}
