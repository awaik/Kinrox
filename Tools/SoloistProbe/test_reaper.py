import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


@unittest.skipUnless(os.uname().sysname == "Darwin", "macOS process identity APIs")
class ReaperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Retain this task's generated artifacts instead of deleting unknown files.
        build = Path(__file__).resolve().parents[2] / "build" / "soloist-probe"
        build.mkdir(parents=True, exist_ok=True)
        cls.root = Path(tempfile.mkdtemp(prefix="reaper-tests-", dir=build))
        cls.helper = cls.root / "reaper"
        cls.child_binary = cls.root / "child"
        (cls.root / "child.c").write_text("#include <unistd.h>\nint main(void) { for (;;) pause(); }\n")
        subprocess.run(["xcrun", "clang", "-O2", str(Path(__file__).with_name("reaper.c")),
                        "-o", str(cls.helper)], check=True)
        subprocess.run(["xcrun", "clang", str(cls.root / "child.c"), "-o", str(cls.child_binary)], check=True)

    def test_lifetime_eof_terminates_exact_child(self):
        child = subprocess.Popen([str(self.child_binary)])
        host = subprocess.Popen([str(self.helper), str(child.pid), str(self.child_binary)],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        try:
            self.assertEqual(host.stdout.readline(), b"READY\n")
            start = time.monotonic()
            host.stdin.close()
            child.wait(timeout=1)
            host.wait(timeout=1)
            self.assertLess(time.monotonic() - start, 1)
        finally:
            if child.poll() is None: child.terminate()
            child.wait(timeout=2)
            if host.poll() is None: host.terminate()
            host.wait(timeout=2)
            host.stdout.close()

    def test_wrong_path_does_not_signal_child(self):
        child = subprocess.Popen([str(self.child_binary)])
        try:
            result = subprocess.run([str(self.helper), str(child.pid), "/not/the/owned/binary"],
                                    input=b"", capture_output=True, timeout=2)
            self.assertEqual(result.returncode, 3)
            self.assertIsNone(child.poll())
        finally:
            child.terminate()
            child.wait(timeout=2)

    def test_non_pid_never_signals_process_group(self):
        for pid in ["0", "-1", "1", "invalid", "99999999999999999"]:
            result = subprocess.run([str(self.helper), pid, str(self.child_binary)],
                                    input=b"", capture_output=True, timeout=2)
            self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
