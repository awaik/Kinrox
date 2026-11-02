"""Publication checks for full, shared app/website Spotify documents."""
from copy import deepcopy
from html import unescape
import re
import unittest

from test_site_localization import ROOT, builder, Document


class SpotifyDocumentTests(unittest.TestCase):
    def test_complete_locale_set_and_current_consent_version(self):
        files = list((ROOT / "Resources/Spotify").glob("SpotifyConnection.*.json"))
        self.assertEqual({p.name[len("SpotifyConnection."):-len(".json")] for p in files}, set(builder.LANGUAGES))
        source = builder.spotify_document("en")
        swift = (ROOT / "PlayerMac/PlayerMac/Music/Spotify/SpotifyDocuments.swift").read_text()
        self.assertEqual(re.search(r'currentVersion = "([^"]+)"', swift)[1], source["version"])
        for locale in builder.LANGUAGES:
            with self.subTest(locale=locale):
                document = builder.spotify_document(locale)
                self.assertEqual(len(document["terms"]), 8)
                self.assertEqual(len(document["privacy"]), 6)

    def test_metadata_cache_disclosure_in_every_locale(self):
        for locale in builder.LANGUAGES:
            with self.subTest(locale=locale):
                privacy = {part["id"]: part["body"] for part in builder.spotify_document(locale)["privacy"]}
                self.assertIn("SQLite", privacy["storage"])
                self.assertIn("Caches", privacy["storage"])
                self.assertIn("SQLite", privacy["retention"])
                self.assertIn("7", privacy["retention"])

    def test_all_sections_render_in_their_own_language_without_losing_text(self):
        for locale in builder.LANGUAGES:
            source = builder.spotify_document(locale)
            with self.subTest(locale=locale):
                for groups in (("terms", "privacy"), ("privacy",)):
                    document = Document(builder.spotify_documents(locale, groups))
                    self.assertEqual(document.errors, [])
                    section = document.select("section")[0]["attrs"]
                    self.assertEqual(section["lang"], locale)
                    self.assertEqual(section["dir"], "rtl" if locale in builder.RTL else "ltr")
                    sections = [s for group in groups for s in source[group]]
                    self.assertEqual([p["text"] for p in document.select("p")][1:], [s["body"] for s in sections])
                    self.assertEqual([h["text"] for h in document.select("h2")], [s["title"] for s in sections])
                    for link in document.select("a"):
                        self.assertEqual(link["attrs"]["href"], link["text"])

    def test_incomplete_untranslated_stale_and_changed_link_documents_are_rejected(self):
        source = builder.spotify_document("en")
        for kind in ("missing", "untranslated", "version", "locale", "link", "blank"):
            document = deepcopy(builder.spotify_document("ru"))
            if kind == "missing":
                document["privacy"].pop()
            elif kind == "untranslated":
                document["terms"][0]["body"] = source["terms"][0]["body"]
            elif kind == "version":
                document["version"] = "old"
            elif kind == "locale":
                document["locale"] = "en"
            elif kind == "link":
                document["terms"][0]["body"] += " https://example.com/"
            else:
                document["terms"][0]["body"] = " "
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                builder.validate_spotify_document(document, "ru", source)

    def test_full_privacy_supplement_is_present_on_every_privacy_page(self):
        for locale in builder.LANGUAGES:
            page = ROOT / "site" / builder.page_path(locale, "privacy") / "index.html"
            text = unescape(page.read_text())
            for section in builder.spotify_document(locale)["privacy"]:
                self.assertIn(f'id="spotify-privacy-{section["id"]}"', text)
                self.assertIn(section["title"], text)

    def test_url_punctuation_rtl_isolation_and_html_escaping(self):
        body = '<script> & https://example.com/path/. ثم https://example.com/end/。'
        rendered = builder.document_body(body)
        self.assertNotIn("<script>", rendered)
        self.assertIn('<bdi dir="ltr">https://example.com/path/</bdi></a>.', rendered)
        self.assertIn('<bdi dir="ltr">https://example.com/end/</bdi></a>。', rendered)
        document = Document("<p>" + rendered + "</p>")
        self.assertEqual(document.select("p")[0]["text"], body)


if __name__ == "__main__":
    unittest.main()
