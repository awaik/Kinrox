import AppKit

/// Keep AppKit's standard app identity/version panel and enrich its credits with links.
@MainActor
enum AboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
    }

    static func credits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 8
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString(
            string: ProjectLink.openSourceDescription + "\n\n", attributes: attributes)
        for link in ProjectLink.allCases {
            var linkAttributes = attributes
            linkAttributes[.link] = link.url
            text.append(NSAttributedString(string: link.title, attributes: linkAttributes))
            text.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        return text
    }
}
