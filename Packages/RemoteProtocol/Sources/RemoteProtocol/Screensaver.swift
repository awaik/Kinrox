/// Optional v1 capability: a missing state field means the peer predates screensavers.
public enum Screensaver: String, Codable, Sendable, Equatable, CaseIterable {
    case off
    case matrix
}
