import Foundation
import RemoteProtocol
import Testing

@Test("Player links shared protocol and uses its Bundle ID")
func playerConfiguration() {
    #expect(Version.current == 1)
    #expect(Bundle.main.bundleIdentifier?.hasSuffix(".player") == true)
}
