import Foundation

/// Spotify uses true to mark a disallowed action. Accept the documented flat
/// shape and the nested disallows shape returned by existing Connect clients.
public struct SpotifyActions: Decodable, Sendable {
    public let disallowed: Set<String>
    private enum CodingKeys: String, CodingKey { case disallows }
    public init(from decoder: any Decoder) throws {
        let nested = try decoder.container(keyedBy: CodingKeys.self)
        let values: [String: Bool]
        if nested.contains(.disallows) {
            values = try nested.decode([String: Bool].self, forKey: .disallows)
        } else {
            values = try decoder.singleValueContainer().decode([String: Bool].self)
        }
        disallowed = Set(values.filter { $0.value }.keys)
    }
}
