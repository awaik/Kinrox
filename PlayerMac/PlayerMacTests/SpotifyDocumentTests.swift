import Foundation
import Testing

@testable import Kinrox

struct SpotifyDocumentTests {
    @Test func rightToLeftDocumentsIsolateURLsAndVersionWithoutChangingProse() throws {
        let text = "العربية · 2026-11-01 (https://github.com/awaik/Kinrox)"
        let expected =
            "العربية · \u{2066}2026-11-01\u{2069} (\u{2066}https://github.com/awaik/Kinrox\u{2069})"
        for locale in ["ar", "fa", "he", "ur"] {
            let document = try #require(SpotifyDocuments.load(preferredLanguages: [locale]))
            #expect(document.displayText(text) == expected)
        }
        let english = try #require(SpotifyDocuments.load(preferredLanguages: ["en"]))
        #expect(english.displayText(text) == text)
    }

    @Test func everyAppLanguageHasCompleteBundledDocuments() throws {
        let english = try #require(SpotifyDocuments.load(preferredLanguages: ["en"]))
        for locale in LocalizationTests.languages {
            let document = try #require(SpotifyDocuments.load(preferredLanguages: [locale]))
            #expect(document.locale == locale)
            #expect(document.version == SpotifyDocuments.currentVersion)
            #expect(document.terms.count == 8 && document.privacy.count == 6)
            #expect(document.isRightToLeft == ["ar", "fa", "he", "ur"].contains(locale))
            if locale != "en" {
                for (translated, source) in zip(
                    document.terms + document.privacy, english.terms + english.privacy)
                {
                    #expect(translated.body != source.body)
                }
            }
        }
    }

    @Test func regionalLanguagesAndUnsupportedFallbackMatchAppLocalization() throws {
        for (preferences, expected) in [
            (["ru-RU"], "ru"), (["fr-CA"], "fr"), (["pt-BR"], "pt"),
            (["zh-CN"], "zh-Hans"), (["zh-TW"], "zh-Hant"),
            (["ar-SA"], "ar"), (["zz-ZZ", "de-DE"], "de"), (["zz-ZZ"], "en"),
        ] {
            let document = try #require(SpotifyDocuments.load(preferredLanguages: preferences))
            #expect(document.locale == expected)
        }
        #expect(SpotifyDocuments.bundled?.locale == Bundle.main.preferredLocalizations.first)
    }

    @Test func invalidVersionLanguageOrIncompleteDocumentsCannotEnableConsent() throws {
        let url = try #require(
            Bundle.main.url(forResource: "SpotifyConnection.en", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let source = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(SpotifyDocuments.decode(data, locale: "ru") == nil)
        #expect(SpotifyDocuments.decode(Data("invalid".utf8), locale: "en") == nil)
        for key in ["version", "language", "terms", "privacy"] {
            var invalid = source
            invalid[key] = key == "terms" || key == "privacy" ? [] : ""
            let encoded = try JSONSerialization.data(withJSONObject: invalid)
            #expect(SpotifyDocuments.decode(encoded, locale: "en") == nil)
        }
        var invalid = source
        var sections = try #require(source["terms"] as? [[String: String]])
        sections[0]["body"] = " \n "
        invalid["terms"] = sections
        #expect(
            SpotifyDocuments.decode(
                try JSONSerialization.data(withJSONObject: invalid), locale: "en") == nil)
        sections[0]["body"] = "Text"
        sections[0]["id"] = sections[1]["id"]
        invalid["terms"] = sections
        #expect(
            SpotifyDocuments.decode(
                try JSONSerialization.data(withJSONObject: invalid), locale: "en") == nil)
    }

    @Test func missingSupportedTranslationDoesNotFallBackSilently() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KinroxDocumentTests-\(UUID()).bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "app.kinrox.document-tests.\(UUID())",
            "CFBundleLocalizations": ["en", "ru"], "CFBundleDevelopmentRegion": "en",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Info.plist"))
        let source = try #require(
            Bundle.main.url(forResource: "SpotifyConnection.en", withExtension: "json"))
        try Data(contentsOf: source).write(
            to: directory.appendingPathComponent("SpotifyConnection.en.json"))
        let bundle = try #require(Bundle(url: directory))
        #expect(SpotifyDocuments.load(bundle: bundle, preferredLanguages: ["en"]) != nil)
        #expect(SpotifyDocuments.load(bundle: bundle, preferredLanguages: ["ru"]) == nil)
    }
}
