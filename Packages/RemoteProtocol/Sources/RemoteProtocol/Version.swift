/// Message format version shared between player and remote.
public enum Version {
    public static let current = 1
    public static let supported = 1...current

    /// Server range can be passed explicitly, e.g. when testing future versions.
    public static func negotiate(
        minVersion: Int, maxVersion: Int, supported serverVersions: ClosedRange<Int> = supported
    ) throws -> Int {
        guard minVersion > 0, maxVersion >= minVersion, maxVersion <= Int(UInt32.max),
            serverVersions.lowerBound > 0, serverVersions.upperBound <= Int(UInt32.max)
        else {
            throw ProtocolError(code: .invalidPayload, message: "Invalid version range.")
        }
        let lower = max(minVersion, serverVersions.lowerBound)
        let upper = min(maxVersion, serverVersions.upperBound)
        guard lower <= upper else {
            throw ProtocolError(code: .incompatibleVersion, message: "No common protocol version.")
        }
        return upper
    }
}
