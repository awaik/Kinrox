import Foundation
import RemoteProtocol
import Testing

@Suite("Screensaver capability compatibility")
struct ScreensaverProtocolTests {
    @Test("Legacy state has no screensaver capability and retains its exact bytes")
    func legacyState() throws {
        let data = try FixtureSamples.data("state")
        guard case .state(_, let state) = try Codec.decode(data) else {
            Issue.record("Expected player state")
            return
        }
        #expect(state.screensaver == nil)
        #expect(try Codec.encode(.state(FixtureSamples.header, state)) == data)
    }

    @Test("Off and active states and commands round trip", arguments: Screensaver.allCases)
    func roundTrip(_ value: Screensaver) throws {
        var state = FixtureSamples.state
        state.screensaver = value
        let message = Message.state(FixtureSamples.header, state)
        #expect(try Codec.decode(Codec.encode(message)) == message)
        let command = Message.command(FixtureSamples.header, .setScreensaver(screensaver: value))
        #expect(try Codec.decode(Codec.encode(command)) == command)
    }
}
