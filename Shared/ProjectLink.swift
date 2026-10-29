import Foundation

/// Public project destinations, opened only when the user activates a link.
enum ProjectLink: String, CaseIterable, Identifiable {
    case website, sourceCode, license, support, issues, privacy

    var id: Self { self }

    var title: String {
        switch self {
        case .website: L10n.text("Kinrox Website")
        case .sourceCode: L10n.text("Source Code (GitHub)")
        case .license: L10n.format("License: %@", "GPL-3.0-only")
        case .support: L10n.text("Support")
        case .issues: L10n.text("Report an Issue")
        case .privacy: L10n.text("Privacy Policy")
        }
    }

    var url: URL {
        switch self {
        case .website: URL(string: "https://awaik.github.io/Kinrox/")!
        case .sourceCode: URL(string: "https://github.com/awaik/Kinrox")!
        case .license: URL(string: "https://github.com/awaik/Kinrox/blob/main/LICENSE")!
        case .support: URL(string: "https://awaik.github.io/Kinrox/support/")!
        case .issues: URL(string: "https://github.com/awaik/Kinrox/issues")!
        case .privacy: URL(string: "https://awaik.github.io/Kinrox/privacy/")!
        }
    }

    static var openSourceDescription: String {
        L10n.text("Kinrox is open-source software licensed under the GNU GPL v3.")
    }
}
