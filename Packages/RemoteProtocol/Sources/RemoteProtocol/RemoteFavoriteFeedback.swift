import Foundation

public struct RemoteFavoriteFeedback: Codable, Sendable, Equatable {
    public let id: UUID
    public let liked: Bool
    public init(id: UUID, liked: Bool) {
        self.id = id
        self.liked = liked
    }
}
