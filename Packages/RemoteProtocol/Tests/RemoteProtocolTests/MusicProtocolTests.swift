import Foundation
import RemoteProtocol
import Testing

@Suite("Additive music protocol")
struct MusicProtocolTests {
    @Test func volumeKnowledgeIsAnAdditiveV1Capability() throws {
        let bytes = try FixtureSamples.data("state-music")
        guard case .state(let header, var state) = try Codec.decode(bytes) else { return }
        #expect(header.v == 1)
        #expect(state.music?.volumeKnown == nil)
        #expect(try Codec.encode(.state(header, state)) == bytes)
        state.music?.volumeKnown = false
        state.music?.disallowedActions = ["volume"]
        let updated = Message.state(header, state)
        let encoded = try Codec.encode(updated)
        #expect(try Codec.decode(encoded) == updated)
        struct OldMusic: Decodable { let disallowedActions: [String]? }
        struct OldState: Decodable {
            let volume: Double
            let music: OldMusic
        }
        struct OldEnvelope: Decodable {
            let v: Int
            let body: OldState
        }
        let old = try JSONDecoder().decode(OldEnvelope.self, from: encoded)
        #expect(old.v == 1 && old.body.volume == 0)
        #expect(old.body.music.disallowedActions?.contains("volume") == true)
        state.music?.disallowedActions = []
        #expect(throws: Codec.Failure.self) { try Codec.encode(.state(header, state)) }
        state.music?.disallowedActions = ["volume"]
        state.volume = 35
        #expect(throws: Codec.Failure.self) { try Codec.encode(.state(header, state)) }
        state.music?.volumeKnown = true
        #expect(try Codec.decode(Codec.encode(.state(header, state))) == .state(header, state))
    }
    @Test func oldStateKeepsExactBytesAndHasNoMusicCapability() throws {
        let bytes = try FixtureSamples.data("state")
        guard case .state(let header, let state) = try Codec.decode(bytes) else {
            Issue.record("Expected state")
            return
        }
        #expect(state.source == nil && state.music == nil)
        #expect(try Codec.encode(.state(header, state)) == bytes)
    }
    @Test func oldClientIgnoresAdditionalMusicFields() throws {
        struct LegacyEnvelope: Decodable { let body: LegacyState }
        struct LegacyState: Decodable {
            let title: String
            let paused: Bool
            let volume: Double
        }
        let bytes = try FixtureSamples.data("state-music")
        let old = try JSONDecoder().decode(LegacyEnvelope.self, from: bytes)
        #expect(old.body.title == "Evening Line" && !old.body.paused && old.body.volume == 0)
    }
    @Test func optionalMetadataAndActionsRoundTripWithoutChangingOldFixtures() throws {
        let original = try FixtureSamples.data("state-music")
        guard case .state(let header, var state) = try Codec.decode(original) else { return }
        #expect(state.music?.track?.albumID == nil)
        #expect(state.music?.disallowedActions == nil)
        #expect(try Codec.encode(.state(header, state)) == original)
        state.music?.track?.albumID = "album"
        state.music?.track?.explicit = true
        state.music?.disallowedActions = ["seeking"]
        state.music?.favoriteFeedback = .init(id: UUID(), liked: false)
        let updated = Message.state(header, state)
        #expect(try Codec.decode(Codec.encode(updated)) == updated)
        state.music?.track?.albumID = "../me"
        #expect(throws: Codec.Failure.self) { try Codec.encode(.state(header, state)) }
    }

    @Test func invalidPagesAndUnsafeIdentifiersAreRejected() throws {
        #expect(throws: Codec.Failure.self) {
            try Codec.encode(.requestQueue(.init(), .init(offset: -1)))
        }
        #expect(throws: Codec.Failure.self) {
            try Codec.encode(.command(.init(), .setTrackLiked(trackId: "../me", liked: true)))
        }
        #expect(throws: Codec.Failure.self) {
            try Codec.encode(
                .queue(
                    .init(),
                    .init(
                        replyTo: UUID(), revision: UUID(), offset: 0, total: 5, nextOffset: nil,
                        items: [])))
        }
    }
    @Test func maximumPageRespectsEncryptedFrameBudget() throws {
        let track = RemoteMusicTrack(
            id: "id", title: String(repeating: "a", count: 300), artists: ["Artist"],
            album: "Album", year: "2025", duration: 100)
        let items = (0..<50).map { _ in RemoteQueueItem(id: UUID(), section: .source, track: track)
        }
        let message = Message.queue(
            .init(),
            .init(
                replyTo: UUID(), revision: UUID(), offset: 0, total: 51, nextOffset: 50,
                items: items))
        #expect(try Codec.encode(message).count < Codec.maxMessageBytes - 28)
        #expect(try Codec.decode(Codec.encode(message)) == message)
    }

    @Test func likeOptionValidationMatchesWireEncoding() throws {
        for (id, title, valid) in [
            ("playlist", "", true), ("invalid/id", "Playlist", false),
            ("playlist", String(repeating: "a", count: 2049), false),
        ] {
            let option = RemoteLikeOption(id: id, kind: .playlist, title: title, selected: false)
            #expect(option.isValid == valid)
            let message = Message.likeOptions(
                .init(),
                .init(
                    replyTo: UUID(), trackId: "track", revision: UUID(),
                    offset: 0, total: 1, nextOffset: nil, items: [option]))
            if valid {
                #expect(try Codec.decode(Codec.encode(message)) == message)
            } else {
                #expect(throws: Codec.Failure.self) { _ = try Codec.encode(message) }
            }
        }
    }
}
