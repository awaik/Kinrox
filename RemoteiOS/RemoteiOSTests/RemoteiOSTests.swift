import Foundation
import RemoteProtocol
import Testing

@Test("Remote imports shared protocol and declares Bonjour in Info.plist")
func remoteConfiguration() {
    #expect(Version.current == 1)
    #expect(Bundle.main.bundleIdentifier?.hasSuffix(".remote") == true)
    let deviceFamily = Bundle.main.object(forInfoDictionaryKey: "UIDeviceFamily") as? [Int]
    #expect(deviceFamily == [1])
    let services = Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String]
    #expect(services == ["_kinrox._tcp"])
    let description =
        Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription")
        as? String
    #expect(description?.isEmpty == false)
}
