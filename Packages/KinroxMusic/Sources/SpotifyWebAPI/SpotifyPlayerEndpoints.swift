import Foundation

extension SpotifyClient {
    public func devices() async throws -> [SpotifyDevice] {
        try await get(SpotifyDevices.self, "me/player/devices").devices
    }
    public func playback() async throws -> SpotifyPlayback? {
        let data = try await request("me/player")
        return data.isEmpty ? nil : try JSONDecoder().decode(SpotifyPlayback.self, from: data)
    }
    public func play(contextURI: String, offset: Int, position: Double, deviceID: String)
        async throws
    {
        guard contextURI.hasPrefix("spotify:playlist:") || contextURI.hasPrefix("spotify:album:"),
            position.isFinite, position >= 0, offset >= 0
        else { throw SpotifyError.invalidResponse }
        struct Offset: Encodable { let position: Int }
        struct Body: Encodable {
            private enum CodingKeys: String, CodingKey {
                case contextURI = "context_uri"
                case offset
                case positionMS = "position_ms"
            }

            let contextURI: String
            let offset: Offset
            let positionMS: Int
        }
        _ = try await request(
            "me/player/play", method: "PUT", query: ["device_id": deviceID],
            body: JSONEncoder().encode(
                Body(
                    contextURI: contextURI, offset: Offset(position: offset),
                    positionMS: Int(min(position, 2_147_483) * 1000))))
    }
    public func pause(_ paused: Bool, deviceID: String) async throws {
        _ = try await request(
            paused ? "me/player/pause" : "me/player/play", method: "PUT",
            query: ["device_id": deviceID])
    }
    public func seek(_ position: Double, deviceID: String) async throws {
        guard position.isFinite, position >= 0 else { throw SpotifyError.invalidResponse }
        _ = try await request(
            "me/player/seek", method: "PUT",
            query: [
                "device_id": deviceID, "position_ms": String(Int(min(position, 2_147_483) * 1000)),
            ])
    }
    public func volume(_ volume: Double, deviceID: String) async throws {
        guard volume.isFinite else { throw SpotifyError.invalidResponse }
        _ = try await request(
            "me/player/volume", method: "PUT",
            query: [
                "device_id": deviceID, "volume_percent": String(Int(min(100, max(0, volume)))),
            ])
    }
    public func shuffle(_ value: Bool, deviceID: String) async throws {
        _ = try await request(
            "me/player/shuffle", method: "PUT",
            query: ["device_id": deviceID, "state": String(value)])
    }
    public func repeatMode(_ value: String, deviceID: String) async throws {
        guard ["off", "track", "context"].contains(value) else {
            throw SpotifyError.invalidResponse
        }
        _ = try await request(
            "me/player/repeat", method: "PUT", query: ["device_id": deviceID, "state": value])
    }
}
