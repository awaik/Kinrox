import Foundation

struct SpotifyDocuments: Decodable {
    struct Section: Decodable, Identifiable {
        let id: String
        let title: String
        let body: String
    }
    let version: String
    let locale: String
    let language: String
    let terms: [Section]
    let privacy: [Section]
    static let currentVersion = "2026-11-01"
    static let bundled = load()

    var isRightToLeft: Bool { ["ar", "fa", "he", "ur"].contains(locale) }

    /// Keep identifiers and URLs readable inside right-to-left prose without changing source text.
    func displayText(_ text: String) -> String {
        guard isRightToLeft else { return text }
        return text.replacingOccurrences(
            of: #"https://[A-Za-z0-9/._?=&%#:+-]+|\b[0-9]{4}-[0-9]{2}-[0-9]{2}\b"#,
            with: "\u{2066}$0\u{2069}", options: .regularExpression)
    }

    static func load(bundle: Bundle = .main, preferredLanguages: [String]? = nil) -> Self? {
        let locale =
            Bundle.preferredLocalizations(
                from: bundle.localizations.filter { $0 != "Base" },
                forPreferences: (preferredLanguages ?? bundle.preferredLocalizations) + ["en"]
            ).first ?? "en"
        // A missing or invalid supported translation must not enable consent silently.
        guard
            let url = bundle.url(forResource: "SpotifyConnection.\(locale)", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return decode(data, locale: locale)
    }

    static func decode(_ data: Data, locale: String) -> Self? {
        guard let documents = try? JSONDecoder().decode(Self.self, from: data),
            documents.version == currentVersion, documents.locale == locale,
            !documents.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            documents.terms.map(\.id) == [
                "connection", "account", "library", "queue", "rights", "responsibility",
                "enforcement", "changes",
            ],
            documents.privacy.map(\.id) == [
                "overview", "access", "storage", "iphone", "retention", "cookies",
            ],
            (documents.terms + documents.privacy).allSatisfy({
                !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        else { return nil }
        return documents
    }
}
