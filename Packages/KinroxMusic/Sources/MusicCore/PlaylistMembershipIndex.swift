import Foundation

/// Reuses complete ordered membership only while Spotify's playlist snapshot is unchanged.
/// A successful mutation must invalidate the entry or install the returned snapshot and membership.
public struct PlaylistMembershipIndex: Sendable {
    private struct Entry: Sendable {
        let snapshotID: String
        let trackIDs: [String]
    }
    private var entries: [String: Entry] = [:]

    public init() {}

    public func trackIDs(playlistID: String, snapshotID: String?) -> [String]? {
        guard let snapshotID, !snapshotID.isEmpty,
            let entry = entries[playlistID], entry.snapshotID == snapshotID
        else { return nil }
        return entry.trackIDs
    }

    public mutating func update(playlistID: String, snapshotID: String, trackIDs: [String]) {
        guard !snapshotID.isEmpty else {
            entries.removeValue(forKey: playlistID)
            return
        }
        entries[playlistID] = Entry(snapshotID: snapshotID, trackIDs: trackIDs)
    }

    public mutating func invalidate(_ playlistID: String) {
        entries.removeValue(forKey: playlistID)
    }
    public mutating func retain(_ playlistIDs: Set<String>) {
        entries = entries.filter { playlistIDs.contains($0.key) }
    }
}
