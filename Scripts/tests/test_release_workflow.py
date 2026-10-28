"""Guard cached source integrity and real player startup readiness."""

import hashlib
import importlib.util
import io
import json
import os
import plistlib
import shlex
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


dependencies = load("prepare-release-dependencies")
launch = load("check-release-launch")


class ArchiveSigningTests(unittest.TestCase):
    def test_archive_uses_requested_team_and_automatic_development_signing(self):
        # Execute the real entry point up to archive, without contacting Apple,
        # generating a project, signing, or notarizing anything.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Scripts").mkdir()
            script = root / "Scripts/build-release.sh"
            script.write_bytes((ROOT / "Scripts/build-release.sh").read_bytes())
            commands = {
                "Scripts/generate.sh": "#!/bin/sh\nexit 0\n",
                "bin/xcrun": "#!/bin/sh\nexit 0\n",
                "bin/python3": '#!/bin/sh\nif [ "$1" = Scripts/prepare-release-dependencies.py ]; then exit 0; fi\n'
                               + "exec " + shlex.quote(sys.executable) + ' "$@"\n',
                "bin/xcodebuild": '#!' + sys.executable + '\nimport json, sys\nfrom pathlib import Path\n'
                                 'Path("archive-args.json").write_text(json.dumps(sys.argv[1:]))\nsys.exit(73)\n',
            }
            for name, contents in commands.items():
                path = root / name
                path.parent.mkdir(exist_ok=True)
                path.write_text(contents)
                path.chmod(0o755)
            result = subprocess.run(["bash", str(script), "0.1.0", "99"], capture_output=True,
                                    env={**os.environ, "PATH": str(root / "bin") + os.pathsep + os.environ["PATH"],
                                         "APPLE_TEAM_ID": "RELEASETEAM", "APPLE_SIGNING_IDENTITY": "fixture",
                                         "NOTARYTOOL_PROFILE": "fixture"})
            self.assertEqual(result.returncode, 73, result.stderr)
            arguments = json.loads((root / "archive-args.json").read_text())
            for required in ["archive", "DEVELOPMENT_TEAM=RELEASETEAM", "CODE_SIGN_STYLE=Automatic",
                             "CODE_SIGN_IDENTITY=Apple Development", "PROVISIONING_PROFILE_SPECIFIER=",
                             "PROVISIONING_PROFILE="]:
                self.assertIn(required, arguments)


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.sources = Path(self.temporary.name)
        self.commit = "a" * 40
        self.archive = self.sources / f"libjxl-{self.commit}.tar.gz"
        with tarfile.open(self.archive, "w:gz") as archive:
            entry = tarfile.TarInfo("source/README")
            entry.size = 4
            archive.addfile(entry, io.BytesIO(b"test"))
        self.record = {"name": "libjxl", "revision": self.commit,
                       "url": f"https://codeload.github.com/libjxl/libjxl/tar.gz/{self.commit}",
                       "file": self.archive.name,
                       "sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()}
        self.lock = mock.patch.object(dependencies, "GITHUB_SOURCES", [self.record], create=True)
        self.lock.start()
        self.addCleanup(self.lock.stop)

    def test_verified_cache_does_not_require_github_or_network(self):
        records = []
        with mock.patch.object(dependencies.subprocess, "check_output", side_effect=AssertionError("Network")), \
                mock.patch.object(dependencies.subprocess, "run", side_effect=AssertionError("Network")):
            dependencies.github_sources("libjxl/libjxl", "v0.11.2", "libjxl", self.sources, records)
        self.assertEqual(records, [self.record])

    def test_corrupt_cached_source_is_rejected_before_packaging(self):
        with tarfile.open(self.archive, "w:gz") as archive:
            entry = tarfile.TarInfo("source/README")
            entry.size = 7
            archive.addfile(entry, io.BytesIO(b"changed"))
        corrupt = self.archive.read_bytes()
        # The former resolver accepts the same revision but never checks its bytes.
        with mock.patch.object(dependencies, "github_json", create=True,
                               return_value={"sha": self.commit, "tree": []}), \
                self.assertRaisesRegex(ValueError, "SHA256"):
            dependencies.github_sources("libjxl/libjxl", "v0.11.2", "libjxl", self.sources, [])
        self.assertEqual(self.archive.read_bytes(), corrupt)


class StartupTests(unittest.TestCase):
    def check_startup(self, diagnostic, entitlements=None):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Kinrox.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Kinrox"}))
            process = mock.Mock(pid=123, returncode=None)
            process.poll.return_value = None
            process.stderr = io.BytesIO(diagnostic)

            def start(*args, **kwargs):
                if hasattr(kwargs["stderr"], "write"):
                    kwargs["stderr"].write(diagnostic)
                    kwargs["stderr"].flush()
                return process

            def output(command, **kwargs):
                if command[0] == "codesign":
                    return plistlib.dumps({}) if entitlements is None else entitlements
                return str(app / "Contents/Frameworks/libmpv.2.dylib")

            with mock.patch.object(launch.subprocess, "run", return_value=mock.Mock(stderr="flags=runtime")), \
                    mock.patch.object(launch.subprocess, "check_output", side_effect=output), \
                    mock.patch.object(launch.subprocess, "Popen", side_effect=start), \
                    mock.patch.object(launch.time, "monotonic", side_effect=[0, 1, 6]), \
                    mock.patch.object(launch.time, "sleep"):
                launch.check(app)

    def test_alive_process_with_loaded_library_but_no_ready_signal_fails(self):
        with self.assertRaisesRegex(RuntimeError, "initialization"):
            self.check_startup(b"Failed to start player\n")

    def test_ready_player_passes(self):
        self.check_startup(b"KINROX_PLAYER_READY\n")

    def test_empty_entitlements_do_not_prevent_readiness_check(self):
        self.check_startup(b"KINROX_PLAYER_READY\n", entitlements=b"")


if __name__ == "__main__":
    unittest.main()
