"""Exercise LaunchServices cleanup with an isolated fake registry executable."""

import json
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LSREGISTER = (
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
    "LaunchServices.framework/Support/lsregister"
)


class UnregisterDevCopiesTests(unittest.TestCase):
    def test_kept_path_and_record_boundaries(self):
        for dry_run in [True, False]:
            for suffix in ["", "/", "///"]:
                with self.subTest(dry_run=dry_run, suffix=suffix):
                    self.check_cleanup(dry_run, suffix)

    def check_cleanup(self, dry_run, suffix):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            kept = "/Applications/Kinrox.app"
            staging = "/Volumes/Kinrox 0.5.10/Kinrox.app"
            records = [
                # A missing path must not result in an empty unregister argument.
                "identifier: app.kinrox.player",
                f"path: {kept}\nidentifier: app.kinrox.player",
                "path: /Applications/Other.app\nidentifier: org.example.other",
                # Nor may it inherit an unrelated bundle's path.
                "identifier: app.kinrox.player",
                f"path: {staging} (0x123abc)\nidentifier: app.kinrox.player",
                f"path: {staging}\nidentifier: app.kinrox.player",
                "path: /Applications/Remote.app\nidentifier: app.kinrox.player.remote",
            ]
            (root / "dump.txt").write_text(
                ("\n" + "-" * 80 + "\n").join(records) + "\n")
            fake = root / "lsregister"
            fake.write_text(
                f"#!{sys.executable}\n"
                "import json, sys\nfrom pathlib import Path\n"
                "root = Path(__file__).parent\n"
                "if sys.argv[1:] == ['-dump']:\n"
                "    print((root / 'dump.txt').read_text())\n"
                "else:\n"
                "    with (root / 'calls.jsonl').open('a') as stream:\n"
                "        stream.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            )
            fake.chmod(0o755)
            # Substitute only the external tool, preserving the real script's logic.
            script = root / "unregister.sh"
            source = (ROOT / "Scripts/unregister-dev-copies.sh").read_text()
            self.assertIn(f"LSREGISTER={LSREGISTER}\n", source)
            script.write_text(source.replace(
                f"LSREGISTER={LSREGISTER}\n", f"LSREGISTER={shlex.quote(str(fake))}\n"))
            args = ["sh", str(script)]
            if dry_run:
                args.append("--dry-run")
            result = subprocess.run(args + [kept + suffix], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [f"Unregistering {staging}"])
            calls = root / "calls.jsonl"
            if dry_run:
                self.assertFalse(calls.exists())
            else:
                self.assertEqual([json.loads(line) for line in calls.read_text().splitlines()],
                                 [["-u", staging]])


if __name__ == "__main__":
    unittest.main()
