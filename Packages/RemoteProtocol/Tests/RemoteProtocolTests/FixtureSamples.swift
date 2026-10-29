import Foundation
import RemoteProtocol
import Testing

struct FixtureSample: Sendable, CustomTestStringConvertible {
    let name: String
    let message: Message
    var testDescription: String { name }
}

enum FixtureSamples {
    static let id = UUID(uuidString: "6F1C0000-0000-4000-8000-000000000001")!
    static let deviceId = UUID(uuidString: "A1111111-1111-4111-8111-111111111111")!
    static let serverId = UUID(uuidString: "B2222222-2222-4222-8222-222222222222")!
    static let itemId = UUID(uuidString: "C3333333-3333-4333-8333-333333333333")!
    static let replyId = UUID(uuidString: "D4444444-4444-4444-8444-444444444444")!
    static let header = Message.Header(id: id)
    // Public synthetic bytes; not real device keys or tokens.
    static let bytes = Data(0..<32)

    static let state = PlayerState(
        title: "Movie.mkv", position: 1234.5, duration: 5400, paused: false, volume: 70,
        fullscreen: true, hasMedia: true, canNext: true, canPrevious: false)

    static let commands: [Command] = [
        .togglePause, .setPaused(paused: true), .seekRelative(seconds: -30),
        .seekAbsolute(seconds: 1234.5), .setVolume(volume: 40), .next, .previous,
        .openRecent(itemId: itemId), .toggleFullscreen, .setFullscreen(fullscreen: false),
        .setScreensaver(screensaver: .matrix),
    ]

    static let all: [FixtureSample] =
        [
            FixtureSample(
                name: "hello",
                message: .hello(
                    header,
                    .init(
                        minVersion: 1, maxVersion: 1, deviceId: deviceId,
                        deviceName: "iPhone Remote",
                        appVersion: "1.0"))),
            FixtureSample(
                name: "helloAck",
                message: .helloAck(
                    header,
                    .init(
                        version: 1, serverId: serverId, serverName: "Mac mini", needsPairing: true,
                        serverPublicKey: bytes, nonce: bytes))),
            FixtureSample(
                name: "pairRequest", message: .pairRequest(header, .init(clientPublicKey: bytes))),
            FixtureSample(name: "pairProof", message: .pairProof(header, .init(proof: bytes))),
            FixtureSample(
                name: "auth",
                message: .auth(
                    header, .init(deviceId: deviceId, clientPublicKey: bytes, proof: bytes))),
            FixtureSample(name: "pairChallenge", message: .pairChallenge(header)),
            FixtureSample(
                name: "paired", message: .paired(header, .init(token: bytes, serverProof: bytes))),
            FixtureSample(name: "authOk", message: .authOk(header, .init(serverProof: bytes))),
            FixtureSample(name: "requestState", message: .requestState(header)),
            FixtureSample(name: "bye", message: .bye(header)),
            FixtureSample(name: "state", message: .state(header, state)),
            FixtureSample(
                name: "state-idle",
                message: .state(
                    header,
                    .init(
                        title: "", position: 0, duration: 0, paused: true, volume: 0,
                        fullscreen: false,
                        hasMedia: false, canNext: false, canPrevious: false))),
            FixtureSample(
                name: "recent",
                message: .recent(
                    header,
                    [
                        RecentItem(
                            id: itemId, title: "Ember Dusk.mkv", duration: 7083, available: true),
                        RecentItem(id: replyId, title: "Unavailable.mkv", available: false),
                    ])),
            FixtureSample(name: "recent-empty", message: .recent(header, [])),
            FixtureSample(name: "ack", message: .ack(header, .init(replyTo: replyId))),
            FixtureSample(
                name: "error",
                message: .error(
                    header, .init(replyTo: replyId, code: .noMedia, message: "Nothing is playing."))
            ),
            FixtureSample(
                name: "error-unrelated",
                message: .error(header, .init(code: .notPaired, message: "Pairing required."))),
        ]
        + commands.map {
            FixtureSample(name: "command-\($0.kind.rawValue)", message: .command(header, $0))
        }

    static var directory: URL {
        Bundle.module.resourceURL!.appending(path: "Fixtures/v1")
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: "\(name).json"))
    }
}
