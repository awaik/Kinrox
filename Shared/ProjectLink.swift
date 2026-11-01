import Foundation

/// Public project destinations, opened only when the user activates a link.
enum ProjectLink: String, CaseIterable, Identifiable {
    case website, sourceCode, license, support, issues, privacy

    var id: Self { self }

    var title: String {
        switch self {
        case .website: L10n.text("Kinrox Website")
        case .sourceCode: L10n.text("Source Code (GitHub)")
        case .license: L10n.format("License: %@", Self.licenseName)
        case .support: L10n.text("Support")
        case .issues: L10n.text("Report an Issue")
        case .privacy: L10n.text("Privacy Policy")
        }
    }

    var url: URL {
        switch self {
        case .website: URL(string: "https://awaik.github.io/Kinrox/")!
        case .sourceCode: URL(string: "https://github.com/awaik/Kinrox")!
        case .license: Self.licenseURL
        case .support: URL(string: "https://awaik.github.io/Kinrox/support/")!
        case .issues: URL(string: "https://github.com/awaik/Kinrox/issues")!
        case .privacy: URL(string: "https://awaik.github.io/Kinrox/privacy/")!
        }
    }

    static var licenseName: String {
        #if os(iOS)
            L10n.text("Personal use only")
        #else
            "GPL-3.0-only"
        #endif
    }

    private static var licenseURL: URL {
        #if os(iOS)
            URL(string: "https://github.com/awaik/Kinrox/blob/main/RemoteiOS/LICENSE.txt")!
        #else
            URL(string: "https://github.com/awaik/Kinrox/blob/main/LICENSING.md")!
        #endif
    }

    static var licenseDescription: String {
        #if os(iOS)
            L10n.text(
                "Kinrox Remote is free for personal, noncommercial use. Business use, sales, and paid subscriptions are prohibited."
            )
        #else
            L10n.text("Kinrox for Mac is open-source software licensed under the GNU GPL v3.")
        #endif
    }
}
