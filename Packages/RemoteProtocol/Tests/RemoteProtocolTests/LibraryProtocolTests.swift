import Foundation
import Testing

@testable import RemoteProtocol

@Suite("Additive remote library protocol")
@MainActor struct LibraryProtocolTests {
    @Test("Legacy requestState keeps exact bytes and accepts optional features")
    func requestStateCompatibility() throws {
        let legacyBytes = try FixtureSamples.data("requestState")
        let decoded = try Codec.decode(legacyBytes)
        #expect(decoded == .requestState(FixtureSamples.header))
        #expect(try Codec.encode(.requestState(FixtureSamples.header)) == legacyBytes)

        let withFeatures = Message.requestState(
            FixtureSamples.header, .init(features: ["library.v1"]))
        let encoded = try Codec.encode(withFeatures)
        #expect(try Codec.decode(encoded) == withFeatures)

        struct OldEmptyBody: Decodable {}
        struct OldEnvelope: Decodable {
            let v: Int
            let type: String
            let body: OldEmptyBody
        }
        let old = try JSONDecoder().decode(OldEnvelope.self, from: encoded)
        #expect(old.v == 1 && old.type == "requestState")
    }

    @Test("Old 0.2.2 clients ignore additive library, sources, origin, and format fields")
    func backwardCompatibilityStateDecode() throws {
        let bytes = try FixtureSamples.data("state-library")
        struct OldTrack: Decodable {
            let id: String
            let title: String
        }
        struct OldMusic: Decodable {
            let track: OldTrack?
            let outputName: String
        }
        struct OldState: Decodable {
            let title: String
            let source: String?
            let music: OldMusic?
        }
        struct OldEnvelope: Decodable { let body: OldState }
        let old = try JSONDecoder().decode(OldEnvelope.self, from: bytes)
        #expect(old.body.title == "Evening Line")
        #expect(old.body.source == "music")
        #expect(old.body.music?.track?.title == "Evening Line")
        #expect(old.body.music?.outputName == "Mac mini")
    }

    @Test("Library request, item, details, artwork, and state validation rejects invalid payloads")
    func validationRejections() throws {
        let multiByteOver64 = String(repeating: "ж", count: 33)  // 66 UTF-8 bytes, 33 chars
        let multiByteOver200 = String(repeating: "ж", count: 101)  // 202 UTF-8 bytes
        let multiByteOver512 = String(repeating: "ж", count: 257)  // 514 UTF-8 bytes
        let multiByteOver2048 = String(repeating: "ж", count: 1025)  // 2050 UTF-8 bytes
        let multiByteOver4096 = String(repeating: "ж", count: 2049)  // 4098 UTF-8 bytes

        let invalidMessages: [Message] = [
            // StateRequest features bounds
            .requestState(.init(), .init(features: Array(repeating: "a", count: 17))),
            .requestState(.init(), .init(features: [""])),
            .requestState(.init(), .init(features: [multiByteOver64])),
            // RemoteLibraryState counts
            .state(
                .init(),
                .init(
                    title: "", position: 0, duration: 0, paused: true, volume: 0,
                    fullscreen: false, hasMedia: false, canNext: false, canPrevious: false,
                    library: .init(
                        revision: UUID(), progressRevision: UUID(), folders: -1, videos: 0,
                        series: 0, albums: 0, tracks: 0, scanning: false))),
            // RemoteSources invalid artwork id & long title
            .state(
                .init(),
                .init(
                    title: "", position: 0, duration: 0, paused: true, volume: 0,
                    fullscreen: false, hasMedia: false, canNext: false, canPrevious: false,
                    sources: .init(
                        video: .init(title: "Ok", paused: true, artwork: "../bad/id")))),
            .state(
                .init(),
                .init(
                    title: "", position: 0, duration: 0, paused: true, volume: 0,
                    fullscreen: false, hasMedia: false, canNext: false, canPrevious: false,
                    sources: .init(video: .init(title: multiByteOver2048, paused: true)))),
            // Track format over 64 UTF-8 bytes
            .state(
                .init(),
                .init(
                    title: "T", position: 0, duration: 10, paused: true, volume: 50,
                    fullscreen: false, hasMedia: true, canNext: false, canPrevious: false,
                    source: .music,
                    music: .init(
                        track: .init(
                            id: "t_1", title: "T", artists: [], album: "", year: "", duration: 10,
                            format: multiByteOver64),
                        nextTrack: nil, liked: false, shuffle: false, repeatMode: .off,
                        queueCount: 1, queueRevision: UUID(), libraryRevision: UUID(),
                        outputName: "Mac", origin: .local))),
            // LibraryRequest parentId mismatch & query cap & bad offset
            .requestLibrary(.init(), .init(section: .children, parentId: nil)),
            .requestLibrary(.init(), .init(section: .children, parentId: "/path/leak")),
            .requestLibrary(.init(), .init(section: .videos, parentId: "s_1")),
            .requestLibrary(.init(), .init(section: .videos, query: multiByteOver200)),
            .requestLibrary(.init(), .init(section: .videos, offset: -1)),
            // LibraryPage invalid pagination, duplicate ids, parentId mismatch
            .library(
                .init(),
                .init(
                    replyTo: UUID(), revision: UUID(), section: .videos, offset: 0, total: 2,
                    nextOffset: nil, items: [FixtureSamples.libraryItem])),
            .library(
                .init(),
                .init(
                    replyTo: UUID(), revision: UUID(), section: .videos, offset: 0, total: 2,
                    nextOffset: nil,
                    items: [FixtureSamples.libraryItem, FixtureSamples.libraryItem]
                )),
            .library(
                .init(),
                .init(
                    replyTo: UUID(), revision: UUID(), section: .children, parentId: nil,
                    offset: 0, total: 0, nextOffset: nil, items: [])),
            // RemoteLibraryItem caps
            .libraryItem(
                .init(),
                .init(
                    replyTo: UUID(), revision: UUID(),
                    item: .init(id: "bad/id", kind: .movie, title: "X"),
                    details: .init())),
            .libraryItem(
                .init(),
                .init(
                    replyTo: UUID(), revision: UUID(),
                    item: .init(
                        id: "m_1", kind: .movie, title: "X",
                        genres: ["1", "2", "3", "4", "5", "6"]),
                    details: .init())),
            .libraryItem(
                .init(),
                .init(
                    replyTo: UUID(), revision: UUID(),
                    item: .init(
                        id: "m_1", kind: .movie, title: "X", badges: ["1", "2", "3", "4", "5"]),
                    details: .init())),
            .libraryItem(
                .init(),
                .init(
                    replyTo: UUID(), revision: UUID(),
                    item: .init(id: "m_1", kind: .movie, title: "X", rating: 8.5, ratingScale: nil),
                    details: .init())),
            .libraryItem(
                .init(),
                .init(
                    replyTo: UUID(), revision: UUID(),
                    item: .init(id: "m_1", kind: .movie, title: "X", folderName: multiByteOver512),
                    details: .init())),
            .libraryItem(
                .init(),
                .init(
                    replyTo: UUID(), revision: UUID(),
                    item: .init(id: "m_1", kind: .movie, title: "X", duration: .nan),
                    details: .init())),
            // LibraryItemDetails caps & fileName slash
            .libraryItem(
                .init(),
                .init(
                    replyTo: UUID(), revision: UUID(),
                    item: .init(id: "m_1", kind: .movie, title: "X"),
                    details: .init(fileName: "dir/movie.mkv"))),
            .libraryItem(
                .init(),
                .init(
                    replyTo: UUID(), revision: UUID(),
                    item: .init(id: "m_1", kind: .movie, title: "X"),
                    details: .init(overview: multiByteOver4096))),
            .libraryItem(
                .init(),
                .init(
                    replyTo: UUID(), revision: UUID(),
                    item: .init(id: "m_1", kind: .movie, title: "X"),
                    details: .init(nextEpisodeId: "bad/id"))),
            // Artwork bounds
            .requestArtwork(.init(), .init(id: "m_1", maxPixel: 63)),
            .requestArtwork(.init(), .init(id: "m_1", maxPixel: 361)),
            .requestArtwork(.init(), .init(id: "bad/id", maxPixel: 200)),
            .artwork(
                .init(),
                .init(replyTo: UUID(), id: "m_1", jpeg: Data(repeating: 0xAB, count: 40_001))),
            // Commands
            .command(
                .init(), .playLibrary(itemId: "/Users/me/movie.mkv", from: .resume, shuffle: nil)),
            .requestLibraryItem(.init(), .init(id: "bad/id")),
        ]

        for message in invalidMessages {
            let failure = try #require(throws: Codec.Failure.self) {
                _ = try Codec.encode(message)
            }
            #expect(failure.error.code == .invalidPayload)
        }
    }

    @Test("40,000-byte JPEG artwork seals and opens inside SecureChannel frame budget")
    func maxArtworkFitsEncryptedChannel() throws {
        let keys = try CryptoVector.load().keys()
        let server = SecureChannel(keys: keys, role: .server)
        let client = SecureChannel(keys: keys, role: .client)
        server.activate()
        client.activate()

        let jpeg = Data((0..<40_000).map { UInt8($0 & 0xFF) })
        let message = Message.artwork(
            FixtureSamples.header,
            .init(
                replyTo: FixtureSamples.replyId,
                id: "m_0123456789abcdef0123456789abcdef",
                jpeg: jpeg))
        let plaintext = try Codec.encode(message)
        #expect(plaintext.count <= SecureChannel.maxPlaintextBytes)
        let sealed = try server.seal(message)
        #expect(sealed.count <= Codec.maxMessageBytes)
        #expect(try client.open(sealed) == message)
    }

    @Test(
        "Pre-auth library messages return recoverable notPaired without closing handshake",
        arguments: ["requestLibrary", "requestLibraryItem", "requestArtwork"])
    func preAuthLibraryReturnsNotPaired(_ type: String) throws {
        let h = try HandshakeHarness()
        let raw = Data(
            "{\"v\":1,\"id\":\"\(FixtureSamples.id)\",\"type\":\"\(type)\",\"body\":{}}".utf8)
        let failure = try #require(throws: SessionFailure.self) {
            try h.server.receive(raw)
        }
        #expect(failure.error.code == .notPaired)
        #expect(failure.error.replyTo == FixtureSamples.id)
        #expect(!failure.shouldCloseConnection)
        #expect(failure.canSendResponse)

        // Handshake still succeeds afterwards.
        try h.beginPairing()
        guard case .authenticated = try h.client.receive(h.finishFrame()) else {
            throw HandshakeHarness.HarnessError.event
        }
        _ = try h.server.finishSent()
    }
}
