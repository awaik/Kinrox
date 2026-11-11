import Foundation
import RemoteProtocol
import Testing

@Suite("Similar capability compatibility")
struct SimilarProtocolTests {
    @Test("Music state from an older Mac has no Similar capability and keeps its bytes")
    func legacyState() throws {
        let data = try FixtureSamples.data("state-music")
        guard case .state(_, let state) = try Codec.decode(data) else {
            Issue.record("Expected player state")
            return
        }
        #expect(state.music?.similar == nil)
        #expect(try Codec.encode(.state(FixtureSamples.header, state)) == data)
    }

    @Test("Similar commands round trip", arguments: RemoteNotInterestedScope.allCases)
    func roundTrip(_ scope: RemoteNotInterestedScope) throws {
        for command in [
            Command.setSimilar(active: false),
            .setNotInterested(trackId: "track_1-a", scope: scope, excluded: false),
        ] {
            let message = Message.command(FixtureSamples.header, command)
            #expect(try Codec.decode(Codec.encode(message)) == message)
        }
    }

    @Test("Invalid Not interested payloads are rejected")
    func invalidPayloads() throws {
        #expect(throws: (any Error).self) {
            try Codec.encode(
                .command(
                    FixtureSamples.header,
                    .setNotInterested(trackId: "../x", scope: .track, excluded: true)))
        }
        let unknownScope = Data(
            """
            {"v":1,"id":"\(FixtureSamples.id)","type":"command","body":
              {"kind":"setNotInterested","trackId":"track1","scope":"album","excluded":true}}
            """.utf8)
        #expect(throws: (any Error).self) { try Codec.decode(unknownScope) }
        let missingFlag = Data(
            """
            {"v":1,"id":"\(FixtureSamples.id)","type":"command","body":{"kind":"setSimilar"}}
            """.utf8)
        #expect(throws: (any Error).self) { try Codec.decode(missingFlag) }
    }
}
