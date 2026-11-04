import Foundation

/// Error descriptions deliberately contain no server payloads, URIs, paths or credentials.
enum SoloistFailure: Error, Equatable {
    case invalidFrame, invalidCommand, unavailable, rejected, dispatchTimeout, observationTimeout
    case closed, emptyQueue, signature, installation, profileBusy, process, endpoint,
        accountMismatch
}

struct SoloistCommand: Encodable, Sendable {
    enum Kind: String, Codable, Sendable {
        case play, pause, seek
        case volume = "set_volume"
        case state = "get_state"
    }
    let type = "command"
    let command: Kind
    var positionMS: Double?
    var volume: Double?
    enum CodingKeys: String, CodingKey {
        case type, command, volume
        case positionMS = "position_ms"
    }
    func encoded() throws -> Data {
        guard positionMS.map({ $0.isFinite && (0...86_400_000).contains($0) }) != false,
            volume.map({ $0.isFinite && (0...100).contains($0) }) != false
        else { throw SoloistFailure.invalidCommand }
        return try JSONEncoder().encode(self)
    }
}

/// Only fields required for control are decoded. User metadata and error payloads are discarded.
struct SoloistFrame: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        struct Decorations: Decodable, Sendable {
            struct Playback: Decodable, Sendable {
                let durationMS: Double?
                enum CodingKeys: String, CodingKey { case durationMS = "duration_ms" }
            }
            let playback: Playback?
        }
        let uri: String?
        let decorations: Decorations?
        var duration: Double? { decorations?.playback?.durationMS.map { $0 / 1000 } }
    }
    struct Position: Decodable, Sendable {
        let positionMS: Double
        let timestampMS: Double?
        let speed: Double
        enum CodingKeys: String, CodingKey {
            case positionMS = "position_ms"
            case timestampMS = "timestamp_ms"
            case speed
        }
    }
    let type: String
    let status: String?
    let loggedIn: Bool?
    let isActive: Bool?
    let item: Item?
    let position: Position?
    let volume: Double?
    let command: String?
    enum CodingKeys: String, CodingKey {
        case type, status, item, position, volume, command
        case loggedIn = "logged_in"
        case isActive = "is_active"
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw SoloistFailure.invalidFrame }
        let frame: Self
        do { frame = try JSONDecoder().decode(Self.self, from: data) } catch {
            throw SoloistFailure.invalidFrame
        }
        guard frame.type.utf8.count <= 64, (frame.item?.uri?.utf8.count ?? 0) <= 1024,
            (frame.command?.utf8.count ?? 0) <= 64,
            frame.status.map({ ["playing", "paused", "idle", "buffering"].contains($0) }) != false,
            frame.volume.map({ $0.isFinite && (0...100).contains($0) }) != false,
            frame.item?.duration.map({ $0.isFinite && (0...86_400).contains($0) }) != false
        else { throw SoloistFailure.invalidFrame }
        if let position = frame.position {
            guard position.positionMS.isFinite, (0...86_400_000).contains(position.positionMS),
                position.speed == 0 || position.speed == 1,
                position.timestampMS.map(\.isFinite) != false
            else { throw SoloistFailure.invalidFrame }
        }
        return frame
    }
}
