"""Offline coverage, routing, accessibility and artifact checks for the public site."""
import importlib.util
from html.parser import HTMLParser
from pathlib import Path
import re
import unittest
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("site_builder", ROOT / "Scripts/build-site.py")
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class Document(HTMLParser):
    VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}

    def __init__(self, source):
        super().__init__()
        self.elements = []
        self.stack = []
        self.errors = []
        self.feed(source)
        if self.stack:
            self.errors.append(f"Unclosed tags: {self.stack}")

    def handle_starttag(self, tag, attrs):
        element = {"tag": tag, "attrs": dict(attrs), "text": ""}
        self.elements.append(element)
        if tag not in self.VOID:
            self.stack.append(element)

    def handle_endtag(self, tag):
        if not self.stack or self.stack[-1]["tag"] != tag:
            self.errors.append(f"Unexpected closing tag: {tag}")
        else:
            self.stack.pop()

    def handle_data(self, text):
        for element in self.stack:
            element["text"] += text

    def select(self, tag):
        return [el for el in self.elements if el["tag"] == tag]


class SiteLocalizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.generated = dict(builder.outputs())
        cls.documents = {
            name: Document(text) for name, text in cls.generated.items() if name.endswith(".html")
        }

    def test_language_set_matches_both_apps(self):
        app = {p.stem for p in (ROOT / "Resources/Localization").glob("*.lproj")}
        self.assertEqual(set(builder.LANGUAGES), app)
        self.assertEqual(len(self.documents), len(app) * 3)

    def test_committed_output_is_current(self):
        for name, source in self.generated.items():
            with self.subTest(path=name):
                self.assertEqual((ROOT / "site" / name).read_text(), source)

    def test_document_structure_and_translated_metadata(self):
        for locale in builder.LANGUAGES:
            strings = builder.read_json(ROOT / "Website/locales" / f"{locale}.json")
            for page in builder.PAGES:
                name = builder.page_path(locale, page) + "index.html"
                with self.subTest(path=name):
                    doc = self.documents[name]
                    self.assertEqual(doc.errors, [])
                    self.assertEqual(doc.select("html")[0]["attrs"]["lang"], locale)
                    self.assertEqual(doc.select("html")[0]["attrs"]["dir"], "rtl" if locale in builder.RTL else "ltr")
                    self.assertEqual(doc.select("title")[0]["text"], strings[f"{page}-title"])
                    self.assertEqual(len(doc.select("h1")), 1)
                    self.assertTrue(doc.select("h1")[0]["text"].strip())
                    self.assertNotIn('id="ru"', self.generated[name])
                    self.assertNotRegex(self.generated[name], r"\{\{|ZXQ\d|QXZ|\[\[\[")
                    ids = [el["attrs"]["id"] for el in doc.elements if "id" in el["attrs"]]
                    self.assertEqual(len(ids), len(set(ids)))
                    for anchor in doc.select("a"):
                        # No empty links after restoring inline translation markup.
                        self.assertTrue(anchor["text"].strip(), anchor)
                    for img in doc.select("img"):
                        self.assertIn("alt", img["attrs"])

    def test_language_switcher_keeps_page_and_canonical_alternates(self):
        for locale in builder.LANGUAGES:
            for page in builder.PAGES:
                directory = builder.page_path(locale, page)
                name = directory + "index.html"
                doc = self.documents[name]
                with self.subTest(path=name):
                    links = [el["attrs"] for el in doc.select("a") if "data-language" in el["attrs"]]
                    self.assertEqual(len(links), len(builder.LANGUAGES))
                    self.assertEqual([a["data-language"] for a in links if "aria-current" in a], [locale])
                    for a in links:
                        target = (ROOT / "site" / directory / a["href"] / "index.html").resolve()
                        expected = ROOT / "site" / builder.page_path(a["data-language"], page) / "index.html"
                        self.assertEqual(target, expected.resolve())
                    alternates = {el["attrs"]["hreflang"]: el["attrs"]["href"] for el in doc.select("link") if el["attrs"].get("rel") == "alternate"}
                    self.assertEqual(set(alternates), set(builder.LANGUAGES) | {"x-default"})
                    for code in builder.LANGUAGES:
                        self.assertEqual(alternates[code], f"{builder.ORIGIN}/{builder.page_path(code, page)}")
                    canonical = [el["attrs"]["href"] for el in doc.select("link") if el["attrs"].get("rel") == "canonical"]
                    self.assertEqual(canonical, [f"{builder.ORIGIN}/{directory}"])

    def test_all_local_links_assets_and_fragments_exist(self):
        site = ROOT / "site"
        for name, doc in self.documents.items():
            for el in doc.elements:
                for attr in ("src", "href"):
                    value = el["attrs"].get(attr)
                    if not value:
                        continue
                    url = urlsplit(value)
                    if url.scheme or url.netloc:
                        continue
                    with self.subTest(page=name, target=value):
                        target = (site / name).parent / unquote(url.path)
                        target = target.resolve()
                        self.assertTrue(target.is_relative_to(site.resolve()))
                        if target.is_dir():
                            target /= "index.html"
                        self.assertTrue(target.is_file(), target)
                        if url.fragment and target.suffix == ".html":
                            target_doc = self.documents[str(target.relative_to(site))]
                            self.assertIn(unquote(url.fragment), [e["attrs"].get("id") for e in target_doc.elements])

    def test_all_homepages_use_their_own_screenshots(self):
        for locale in builder.LANGUAGES:
            doc = self.documents[builder.page_path(locale, "home") + "index.html"]
            sources = [el["attrs"]["src"] for el in doc.select("img") if "/remote/" in el["attrs"].get("src", "")]
            self.assertEqual(len(sources), 5)
            self.assertTrue(all(f"/remote/{locale}/" in src for src in sources))

    def test_sitemap_covers_every_page(self):
        root = ET.fromstring(self.generated["sitemap.xml"])
        urls = {node.text for node in root.findall("{*}url/{*}loc")}
        expected = {f"{builder.ORIGIN}/{builder.page_path(locale, page)}" for locale in builder.LANGUAGES for page in builder.PAGES}
        self.assertEqual(urls, expected)

    def test_translations_escape_html_and_preserve_trusted_markup(self):
        text = builder.localized_text("example", {"example": '{0}A & "B"{1}'}, {"example": ["<strong>", "</strong>"]}, "./")
        self.assertEqual(text, "<strong>A &amp; &quot;B&quot;</strong>")
        with self.assertRaises(ValueError):
            builder.localized_text("example", {"example": "{0}"}, {}, "./", attribute=True)


if __name__ == "__main__":
    unittest.main()
