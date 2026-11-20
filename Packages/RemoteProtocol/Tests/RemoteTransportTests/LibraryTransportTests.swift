import Foundation
import RemoteProtocol
import Testing

@testable import RemoteTransport

@Suite("Remote library messages over real WebSocket transport", .serialized)
@MainActor struct LibraryTransportTests {
    @Test("Library requests, responses, 40 KB artwork, and commands round-trip over Transport")
    func libraryRoundTrip() async throws {
        let h = try TransportHarness()
        defer { h.stop() }
        try await h.start()
        let device = UUID()
        let client = try await h.pair(deviceId: device)
        let connectionId = try #require(h.deviceConnections[device])

        let stateReq = Message.requestState(.init(), .init(features: ["library.v1"]))
        let libReq = Message.requestLibrary(
            .init(), .init(section: .videos, videoKind: .all, sort: .rating, offset: 0))
        let itemReq = Message.requestLibraryItem(.init(), .init(id: "m_1"))
        let artReq = Message.requestArtwork(.init(), .init(id: "m_1", maxPixel: 240))
        let playCmd = Message.command(
            .init(), .playLibrary(itemId: "m_1", from: .resume, shuffle: nil))
        let resumeCmd = Message.command(.init(), .resumeSource(source: .video))

        for msg in [stateReq, libReq, itemReq, artReq, playCmd, resumeCmd] {
            try await client.send(msg)
        }
        try await eventually { h.incoming.count == 6 }
        #expect(h.incoming == [stateReq, libReq, itemReq, artReq, playCmd, resumeCmd])

        let item = RemoteLibraryItem(id: "m_1", kind: .movie, title: "Ember Dusk", artwork: true)
        let libReply = Message.library(
            .init(),
            .init(
                replyTo: libReq.header.id, revision: UUID(), section: .videos, offset: 0, total: 1,
                nextOffset: nil, items: [item]))
        let itemReply = Message.libraryItem(
            .init(),
            .init(
                replyTo: itemReq.header.id, revision: UUID(), item: item,
                details: .init(fileName: "Ember Dusk.mkv", folderName: "Movies")))
        let artReply = Message.artwork(
            .init(),
            .init(
                replyTo: artReq.header.id, id: "m_1",
                jpeg: Data((0..<40_000).map { UInt8($0 & 0xFF) })))

        for reply in [libReply, itemReply, artReply] {
            try await h.server.send(reply, to: connectionId)
        }
        try await eventually { h.outgoing.count == 3 }
        #expect(h.outgoing == [libReply, itemReply, artReply])
        #expect(client.state == .connected)
    }
}
