import Foundation

/// Similar mode on the Mac: it keeps adding tracks like the current one to the queue.
/// Its presence in `MusicState` tells the remote that the Mac accepts the Similar commands.
public struct RemoteSimilarState: Codable, Sendable, Equatable {
    /// The Mac keeps adding similar tracks as the queue runs low.
    public var active: Bool
    /// A remote-initiated start is still looking for its first tracks.
    public var finding: Bool
    /// The Mac can start Similar from the current track now.
    public var available: Bool
    public init(active: Bool, finding: Bool = false, available: Bool) {
        self.active = active
        self.finding = finding
        self.available = available
    }
}

/// What a Not interested choice hides from suggestions: the track or its primary artist.
public enum RemoteNotInterestedScope: String, Codable, Sendable, CaseIterable {
    case track, artist
}
