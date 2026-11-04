import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("soloist_bundle", ROOT / "Scripts/check-soloist-bundle.py")
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class SoloistBundleTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="bundle-test-", dir=ROOT / "build/soloist-probe"))
        self.helper = self.root / "Contents/Helpers/KinroxSoloistHost"
        self.helper.parent.mkdir(parents=True)
        self.helper.write_bytes(b"owned fixture")
        self.signatures = patch.object(bundle.subprocess, "run", side_effect=self.signature)
        self.signatures.start()
        self.addCleanup(self.signatures.stop)

    def signature(self, command, **kwargs):
        identifier = "app.kinrox.player" if command[-1] == str(self.root) else "app.kinrox.soloist-host"
        return subprocess.CompletedProcess(command, 0, "", f"Identifier={identifier}\nTeamIdentifier=HV66937AWS\n")

    def test_own_helper_is_allowed(self):
        bundle.verify(self.root)

    def test_stale_embedded_helper_identifier_is_rejected(self):
        with patch.object(bundle.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, "", "Identifier=KinroxSoloistHost\nTeamIdentifier=HV66937AWS\n")):
            with self.assertRaises(ValueError): bundle.verify(self.root)

    def test_adhoc_signature_is_rejected(self):
        with patch.object(bundle.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, "", "Identifier=app.kinrox.soloist-host\nTeamIdentifier=not set\n")):
            with self.assertRaises(ValueError): bundle.verify(self.root)

    def test_distribution_identity_is_rejected_after_rename(self):
        payload = b"fixture distribution"
        (self.root / "renamed-resource").write_bytes(payload)
        with patch.object(bundle, "SPOTIFY_IDENTITIES", {hashlib.sha256(payload).hexdigest()}):
            with self.assertRaises(ValueError): bundle.verify(self.root)

    def test_new_archive_version_is_rejected(self):
        with tarfile.open(self.root / "unexpected-resource", "w:gz") as archive:
            member = tarfile.TarInfo("soloist")
            member.size = 4
            archive.addfile(member, io.BytesIO(b"test"))
        with self.assertRaises(ValueError): bundle.verify(self.root)


if __name__ == "__main__":
    unittest.main()
