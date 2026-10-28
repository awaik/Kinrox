"""Verify regional copy propagation and simulator restoration on capture failure."""

import importlib.util
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("capture", ROOT / "Scripts/capture-app-store.py")
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class RegionalCopyTests(unittest.TestCase):
    def test_regional_rules_reach_shared_render_copy_gallery_and_captions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "Scripts", root / "Scripts", ignore=shutil.ignore_patterns("__pycache__"))
            shutil.copytree(ROOT / "AppStore/copy", root / "AppStore/copy")
            for path in (ROOT / "Resources/Localization").glob("*.lproj"):
                (root / "Resources/Localization" / path.name).mkdir(parents=True)
            (root / "AppStore/preview").mkdir()
            # Exercise a regional rule in requirement as well as screenshot copy.
            source = root / "AppStore/copy/es.json"
            copy = json.loads(source.read_text())
            copy["requirement"] += " · mando"
            source.write_text(json.dumps(copy))
            for script in ["prepare-app-store.py", "build-app-store-gallery.py"]:
                subprocess.run([sys.executable, str(root / "Scripts" / script)], check=True,
                               capture_output=True)
            html = (root / "AppStore/index.html").read_text()
            gallery = json.loads(re.search(r'<script id="data" type="application/json">(.*?)</script>',
                                           html, re.S)[1])
            self.assertIn("película.", gallery["es-MX"]["screenshots"][3][0])
            self.assertIn("o ecrã inteiro", gallery["pt-PT"]["screenshots"][2][1])
            self.assertIn("ligado", gallery["pt-PT"]["screenshots"][4][0])
            self.assertTrue(gallery["es-MX"]["requirement"].endswith("control remoto"))
            prepared = json.loads((root / "AppStore/localized-copy.json").read_text())
            for locale in ["es-MX", "pt-PT"]:
                for field in ["screenshots", "requirement"]:
                    self.assertEqual(gallery[locale][field], prepared[locale][field])
                captions = (root / "AppStore/preview/captions" / f"{locale}.srt").read_text()
                for title, _ in prepared[locale]["screenshots"]:
                    self.assertIn(title, captions)
                self.assertIn(prepared[locale]["requirement"], captions)
            for locale, lang in [("es-ES", "es"), ("pt-BR", "pt")]:
                authored = json.loads((root / f"AppStore/copy/{lang}.json").read_text())
                self.assertEqual(prepared[locale]["screenshots"], authored["screenshots"])
            subprocess.run([sys.executable, str(root / "Scripts/prepare-app-store.py"), "--check"],
                           check=True, capture_output=True)


class CaptureTests(unittest.TestCase):
    def capture(self, fail=False, restore_fail=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Original.app"
            (app / "en.lproj").mkdir(parents=True)
            strings = plistlib.dumps({"Online": "Online", "Online · demo": "Online · demo", "Demo: code %@": "Demo: code %@"})
            (app / "en.lproj/Localizable.strings").write_bytes(strings)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "test.remote"}))
            output = root / "capture"
            calls = []

            def run(*args, **kwargs):
                calls.append(args)
                if args[0] == "plutil":
                    return mock.Mock(stdout=strings.decode())
                if fail and "screenshot" in args:
                    raise RuntimeError("Screenshot failure")
                if restore_fail and args == ("xcrun", "simctl", "install", "test-device", str(app)):
                    raise RuntimeError("Restore failure")
                return mock.Mock()

            with mock.patch.object(sys, "argv", ["capture", "--device", "test-device", "--output", str(output),
                                                  "--app", str(app), "--languages", "en"]), \
                    mock.patch.object(capture, "ROOT", root), mock.patch.object(capture, "run", side_effect=run), \
                    mock.patch.object(capture.time, "sleep"):
                if fail or restore_fail:
                    with self.assertRaisesRegex(RuntimeError, "failure"):
                        capture.main()
                else:
                    capture.main()
                    provenance = json.loads((output / "provenance.json").read_text())
                    self.assertFalse(Path(provenance["app"]).is_absolute())
            self.assertIn(("xcrun", "simctl", "install", "test-device", str(app)), calls)
            self.assertEqual(calls[-1], ("xcrun", "simctl", "status_bar", "test-device", "clear"))
            self.assertEqual((app / "en.lproj/Localizable.strings").read_bytes(), strings)

    def test_success_restores_original_and_records_portable_provenance(self):
        self.capture()

    def test_screenshot_failure_restores_original(self):
        self.capture(fail=True)

    def test_restore_failure_still_clears_status_bar(self):
        self.capture(restore_fail=True)


if __name__ == "__main__":
    unittest.main()
