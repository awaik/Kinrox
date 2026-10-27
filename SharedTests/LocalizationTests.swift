import Foundation
import Testing

#if os(macOS)
    @testable import Kinrox
#else
    @testable import RemoteiOS
#endif

@Suite("App localization resources")
struct LocalizationTests {
    static let languages: Set<String> = [
        "en", "ru", "es", "fr", "de", "pt", "it", "zh-Hans", "zh-Hant", "ja", "ko",
        "ar", "hi", "bn", "ur", "id", "ms", "vi", "th", "tr", "fa", "pl", "uk",
        "nl", "ro", "el", "cs", "sv", "hu", "he",
    ]

    private func localizedBundle(_ language: String) throws -> Bundle {
        let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
        return try #require(Bundle(url: url))
    }

    private func strings(_ language: String, table: String = "Localizable") throws -> [String:
        String]
    {
        let bundle = try localizedBundle(language)
        let url = try #require(bundle.url(forResource: table, withExtension: "strings"))
        let value = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil)
        return try #require(value as? [String: String])
    }

    @Test("Both shipped apps contain every translation and localized permission prompt")
    func completeResources() throws {
        #expect(Set(Bundle.main.localizations).subtracting(["Base"]) == Self.languages)
        let source = try strings("en")
        #expect(source.count >= 180)
        for language in Self.languages {
            let translated = try strings(language)
            #expect(Set(translated.keys) == Set(source.keys))
            for (key, value) in translated {
                #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(
                    value.components(separatedBy: "%@").count
                        == key.components(separatedBy: "%@").count)
            }
            let info = try strings(language, table: "InfoPlist")
            #expect(info["NSLocalNetworkUsageDescription"]?.isEmpty == false)
        }
    }

    @Test("Bundle lookup returns translated values and unknown keys fall back safely")
    func lookupAndFallback() throws {
        let french = try localizedBundle("fr")
        #expect(L10n.text("Open File", bundle: french) == "Ouvrir un fichier")
        #expect(
            L10n.text("Unregistered localization key", bundle: french)
                == "Unregistered localization key")
        #expect(
            Bundle.preferredLocalizations(from: Array(Self.languages), forPreferences: ["fr-CA"])
                .first == "fr")
        #expect(Bundle.main.developmentLocalization == "en")
    }

    @Test("Formatted translations preserve filenames and device names as literal data")
    func formattedValues() throws {
        let french = try localizedBundle("fr")
        let name = "Mac % @ 100%"
        #expect(
            L10n.format("Forget %@", name, bundle: french, locale: Locale(identifier: "fr"))
                == "Oublier Mac % @ 100%")
        #expect(
            L10n.format("%@ of %@ · %@", "2", "12", name, bundle: french)
                == "2 sur 12 · Mac % @ 100%")
    }
}
