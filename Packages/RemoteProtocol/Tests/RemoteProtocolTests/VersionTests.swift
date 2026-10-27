import RemoteProtocol
import Testing

@Test("Initial protocol version is 1")
func initialProtocolVersion() {
    #expect(Version.current == 1)
    #expect(Version.supported == 1...1)
}

@Test(
    "Highest common version is selected",
    arguments: [
        (1, 1, 1...1, 1), (1, 3, 1...2, 2), (2, 5, 1...3, 3),
        (1, 2, 2...4, 2), (1, Int(UInt32.max), 1...1, 1),
        (Int(UInt32.max), Int(UInt32.max), Int(UInt32.max)...Int(UInt32.max), Int(UInt32.max)),
    ])
func highestCommonVersion(minimum: Int, maximum: Int, server: ClosedRange<Int>, expected: Int)
    throws
{
    #expect(
        try Version.negotiate(minVersion: minimum, maxVersion: maximum, supported: server)
            == expected)
}

@Test("Implemented versions are used by default")
func defaultServerVersions() throws {
    #expect(try Version.negotiate(minVersion: 1, maxVersion: 5) == 1)
}

@Test("Non-intersecting ranges are incompatible", arguments: [(1, 2, 3...4), (3, 4, 1...2)])
func disjointVersions(minimum: Int, maximum: Int, server: ClosedRange<Int>) throws {
    let error = try #require(throws: ProtocolError.self) {
        try Version.negotiate(minVersion: minimum, maxVersion: maximum, supported: server)
    }
    #expect(error.code == .incompatibleVersion)
}

@Test(
    "Invalid range does not trap",
    arguments: [
        (2, 1), (0, 1), (-1, 2), (Int.min, Int.max), (1, Int.max), (1, Int(UInt32.max) + 1),
    ])
func invalidVersions(minimum: Int, maximum: Int) throws {
    let error = try #require(throws: ProtocolError.self) {
        try Version.negotiate(minVersion: minimum, maxVersion: maximum)
    }
    #expect(error.code == .invalidPayload)
}

@Test("Server range is also bounded by U32")
func invalidServerVersions() throws {
    for range in [0...1, 1...Int.max] {
        let error = try #require(throws: ProtocolError.self) {
            try Version.negotiate(minVersion: 1, maxVersion: 1, supported: range)
        }
        #expect(error.code == .invalidPayload)
    }
}
