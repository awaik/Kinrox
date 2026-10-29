"""Appcast entries are signed, ordered, and refuse stale or mismatched releases."""

import importlib.util
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("appcast", ROOT / "Scripts/update-appcast.py")
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
SIGNATURE = "A" * 86 + "=="
DATE = datetime(2026, 10, 29, 12, tzinfo=timezone.utc)
NOTES = """# Kinrox 0.3.0

Update reminders for the **Mac** player.

## New

- Banner with `Sparkle` and a
  wrapped line.
- See [notes](https://example.com/a?b=1&c=2) <now>.
"""


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.feed = self.root / "appcast.xml"
        self.feed.write_text('<rss version="2.0"><channel><title>Kinrox</title></channel></rss>')
        self.dmg = self.root / "Kinrox-0.3.0-arm64.dmg"
        self.dmg.write_bytes(b"x" * 1234)
        self.signer = self.root / "sign_update"
        self.signer.write_text(f'#!/bin/sh\nprintf \'sparkle:edSignature="{SIGNATURE}" length="1234"\\n\'\n')
        self.signer.chmod(0o755)

    def release(self, version="0.3.0", build="5", dmg=None):
        dmg = dmg or self.dmg
        edsig, length = appcast.signature(self.signer, dmg)
        tree = appcast.add_release(self.feed, version, build, dmg, edsig, length,
                                   NOTES, DATE)
        tree.write(self.feed, encoding="utf-8", xml_declaration=True)
        return ET.parse(self.feed).getroot().find("channel")

    def test_entry_matches_published_release_assets(self):
        item = self.release().find("item")
        self.assertEqual(item.findtext(S + "version"), "5")
        self.assertEqual(item.findtext(S + "shortVersionString"), "0.3.0")
        self.assertEqual(item.findtext(S + "minimumSystemVersion"), "14.0")
        self.assertEqual(item.findtext(S + "hardwareRequirements"), "arm64")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), "https://github.com/awaik/Kinrox/releases/download/"
                         "v0.3.0/Kinrox-0.3.0-arm64.dmg")
        self.assertEqual(enclosure.get(S + "edSignature"), SIGNATURE)
        self.assertEqual(enclosure.get("length"), "1234")
        self.assertEqual(item.findtext("description"), "\n".join([
            "<p>Update reminders for the <b>Mac</b> player.</p>", "<h3>New</h3>",
            "<ul><li>Banner with <code>Sparkle</code> and a wrapped line.</li>"
            '<li>See <a href="https://example.com/a?b=1&amp;c=2">notes</a> &lt;now&gt;.</li></ul>']))

    def test_newest_release_comes_first_and_stale_builds_are_rejected(self):
        self.release()
        newer = self.root / "Kinrox-0.4.0-arm64.dmg"
        newer.write_bytes(b"x" * 1234)
        items = self.release("0.4.0", "6", newer).findall("item")
        self.assertEqual([i.findtext(S + "shortVersionString") for i in items], ["0.4.0", "0.3.0"])
        with self.assertRaisesRegex(ValueError, "must be newer"):
            self.release("0.4.1", "6", newer)

    def test_unexpected_signer_output_and_size_are_rejected(self):
        self.dmg.write_bytes(b"x" * 99)
        with self.assertRaisesRegex(ValueError, "length differs"):
            appcast.signature(self.signer, self.dmg)
        self.signer.write_text("#!/bin/sh\necho oops\n")
        with self.assertRaisesRegex(ValueError, "Unexpected sign_update output"):
            appcast.signature(self.signer, self.dmg)

    def test_relative_notes_links_use_the_matching_release_tag(self):
        notes = (ROOT / "docs/releases/0.2.0.md").read_text()
        tree = appcast.add_release(self.feed, "0.2.0", "4", Path("Kinrox-0.2.0-arm64.dmg"),
                                   SIGNATURE, "1234", notes, DATE)
        description = tree.getroot().findtext("channel/item/description")
        self.assertIn('<a href="https://github.com/awaik/Kinrox/blob/v0.2.0/docs/runbooks/'
                      '0.2.0-VERIFICATION.md">verification report</a>', description)
        self.assertNotIn("[verification report]", description)

    def test_code_remains_literal_and_link_attributes_are_escaped(self):
        notes = '`**literal** [link](https://example.com) <tag>`\n\n' \
                '[quoted](https://example.com/?q="x"&b=1)'
        tree = appcast.add_release(self.feed, "0.3.0", "5", self.dmg,
                                   SIGNATURE, "1234", notes, DATE)
        self.assertEqual(tree.getroot().findtext("channel/item/description"),
                         '<p><code>**literal** [link](https://example.com) &lt;tag&gt;</code></p>\n'
                         '<p><a href="https://example.com/?q=&quot;x&quot;&amp;b=1">quoted</a></p>')

    def test_code_delimiters_do_not_end_surrounding_markdown(self):
        notes = '**Use `**literal**`** and [`[literal]`](../runbooks/README.md).'
        self.assertEqual(appcast.notes_html(notes, "0.3.0"),
                         '<p><b>Use <code>**literal**</code></b> and '
                         '<a href="https://github.com/awaik/Kinrox/blob/v0.3.0/docs/runbooks/README.md">'
                         '<code>[literal]</code></a>.</p>')

    def test_non_web_link_is_rejected_but_remains_literal_in_code(self):
        with self.assertRaisesRegex(ValueError, "Unsupported release notes link"):
            appcast.notes_html('[link](javascript:alert)', "0.3.0")
        self.assertEqual(appcast.notes_html('`[link](javascript:alert)`', "0.3.0"),
                         '<p><code>[link](javascript:alert)</code></p>')

    def test_empty_feed_still_rejects_invalid_version_and_build(self):
        for version, build in [("0.3", "5"), ("v0.3.0", "5"), ("0.3.0-beta", "5"),
                               ("0.3.0", "0"), ("0.3.0", "-1"), ("0.3.0", "abc"),
                               ("0.3.0", "1.5"), ("0.3.0", "01")]:
            with self.subTest(version=version, build=build), self.assertRaises(ValueError):
                appcast.add_release(self.feed, version, build, Path(f"Kinrox-{version}-arm64.dmg"),
                                    SIGNATURE, "1234", NOTES, DATE)

    def test_older_or_equal_marketing_version_is_rejected_even_with_higher_build(self):
        self.release()
        for version in ["0.2.1", "0.3.0"]:
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, "must be newer"):
                appcast.add_release(self.feed, version, "6", Path(f"Kinrox-{version}-arm64.dmg"),
                                    SIGNATURE, "1234", NOTES, DATE)

    def test_version_comparison_is_numeric(self):
        self.release()
        tree = appcast.add_release(self.feed, "0.10.0", "6", Path("Kinrox-0.10.0-arm64.dmg"),
                                   SIGNATURE, "1234", NOTES, DATE)
        self.assertEqual(tree.getroot().findtext("channel/item/" + S + "shortVersionString"), "0.10.0")

    def test_check_requires_no_signer_or_output_and_never_changes_feed(self):
        self.release()
        before = self.feed.read_bytes()
        command = [sys.executable, str(ROOT / "Scripts/update-appcast.py"), "--check",
                   "--appcast", str(self.feed), "--version", "0.4.0", "--build"]
        valid = subprocess.run([*command, "6"], capture_output=True, text=True)
        self.assertEqual(valid.returncode, 0, valid.stderr)
        invalid = subprocess.run([*command, "5"], capture_output=True, text=True)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn("must be newer", invalid.stderr)
        self.assertEqual(self.feed.read_bytes(), before)

    def test_command_refuses_to_overwrite_output(self):
        notes = self.root / "0.3.0.md"
        notes.write_text("# Kinrox 0.3.0\n")
        command = [sys.executable, str(ROOT / "Scripts/update-appcast.py"), "--appcast", str(self.feed),
                   "--output", str(self.root / "out.xml"), "--version", "0.3.0", "--build", "5",
                   "--dmg", str(self.dmg), "--sign-update", str(self.signer), "--notes", str(notes)]
        subprocess.run(command, check=True, capture_output=True)
        ET.parse(self.root / "out.xml")
        second = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("Refusing to overwrite", second.stderr)


if __name__ == "__main__":
    unittest.main()
