import AppKit
import Testing

@testable import Kinrox

@Suite("About panel links")
@MainActor
struct AboutPanelTests {
    @Test("Native credits retain clickable destinations and localized labels")
    func clickableCredits() {
        let credits = AboutPanel.credits()
        var destinations: [URL] = []
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) {
            value, range, _ in
            guard let url = value as? URL else { return }
            destinations.append(url)
            #expect(url.scheme == "https")
            #expect(!credits.attributedSubstring(from: range).string.isEmpty)
        }
        #expect(destinations == ProjectLink.allCases.map(\.url))
        for link in ProjectLink.allCases {
            let range = (credits.string as NSString).range(of: link.title)
            #expect(range.location != NSNotFound)
            if range.location != NSNotFound {
                #expect(
                    credits.attribute(.link, at: range.location, effectiveRange: nil) as? URL
                        == link.url)
            }
        }
        #expect(credits.string.hasPrefix(ProjectLink.openSourceDescription))
        #expect(credits.attribute(.link, at: 0, effectiveRange: nil) == nil)
    }
}
