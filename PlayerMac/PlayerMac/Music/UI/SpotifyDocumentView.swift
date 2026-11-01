import SwiftUI

struct SpotifyDocumentView: View {
    let privacy: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SpotifyAttribution()
                Spacer()
                Button(L10n.text("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                if let documents = SpotifyDocuments.bundled {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(documents.displayText(documents.language + " · " + documents.version))
                            .font(.caption)
                        ForEach(privacy ? documents.privacy : documents.terms) { section in
                            Text(section.title).font(.headline)
                            Text(.init(documents.displayText(section.body))).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .environment(
                            \.layoutDirection, documents.isRightToLeft ? .rightToLeft : .leftToRight
                        )
                }
            }
        }.padding(24).frame(width: 620, height: 620)
    }
}
