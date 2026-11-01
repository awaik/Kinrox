import Foundation
import Testing

#if os(macOS)
    @testable import Kinrox
#else
    @testable import RemoteiOS
#endif

@Suite("Component licensing")
struct ProjectLicensingTests {
    @Test("About identifies the license of the running app")
    func appLicense() {
        #if os(iOS)
            #expect(ProjectLink.licenseName == L10n.text("Personal use only"))
            #expect(ProjectLink.license.url.path == "/awaik/Kinrox/blob/main/RemoteiOS/LICENSE.txt")
            #expect(
                ProjectLink.licenseDescription
                    == L10n.text(
                        "Kinrox Remote is free for personal, noncommercial use. Business use, sales, and paid subscriptions are prohibited."
                    ))
        #else
            #expect(ProjectLink.licenseName == "GPL-3.0-only")
            #expect(ProjectLink.license.url.path == "/awaik/Kinrox/blob/main/LICENSING.md")
            #expect(
                ProjectLink.licenseDescription
                    == L10n.text(
                        "Kinrox for Mac is open-source software licensed under the GNU GPL v3."))
        #endif
    }

    @Test("Distributed app bundles contain their license and required shared notices")
    func bundledDocuments() throws {
        let gpl = try document("LICENSE", extension: nil)
        #expect(gpl.contains("GNU GENERAL PUBLIC LICENSE"))
        #expect(gpl.contains("Version 3, 29 June 2007"))
        for name in ["LICENSING", "TRADEMARKS", "SHARED-LICENSE-EXCEPTION"] {
            #expect(try !document(name, extension: "md").isEmpty)
        }
        #expect(try document("NOTICE", extension: nil).contains("Copyright (c) 2026 awaik"))
        #if os(iOS)
            let remote = try document("LICENSE", extension: "txt")
            #expect(remote.hasPrefix("Kinrox Remote Personal Use License 1.0"))
            #expect(remote.contains("Paid subscriptions"))
        #endif
    }

    @Test("MusicCore linked by the remote is covered by its bundled shared-code permission")
    func sharedMusicPermission() throws {
        let path = "`Packages/KinroxMusic/Sources/MusicCore/`"
        #expect(try document("SHARED-LICENSE-EXCEPTION", extension: "md").contains(path))
        #expect(try document("LICENSING", extension: "md").contains(path))
    }

    private func document(_ name: String, extension suffix: String?) throws -> String {
        let url = try #require(Bundle.main.url(forResource: name, withExtension: suffix))
        return try String(contentsOf: url, encoding: .utf8)
    }
}
