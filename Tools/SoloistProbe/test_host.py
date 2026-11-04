"""Exercise the production reaper with owned non-audio fixture processes."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


@unittest.skipUnless(os.uname().sysname == "Darwin", "macOS process identity APIs")
class HostTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        project = Path(__file__).resolve().parents[2]
        cls.root = Path(tempfile.mkdtemp(prefix="host-tests-", dir=project / "build/soloist-probe"))
        cls.host, cls.child, cls.identity = [cls.root / name for name in ("host", "child", "identity")]
        (cls.root / "child.c").write_text(
            '#include <signal.h>\n#include <stdio.h>\n#include <unistd.h>\n'
            'int main(int argc, char **argv) { (void)argv; if(argc>1) signal(SIGTERM,SIG_IGN);'
            'puts("READY");fflush(stdout);for(;;)pause();}\n')
        (cls.root / "identity.c").write_text(
            '#include <libproc.h>\n#include <stdio.h>\n#include <stdlib.h>\n'
            'int main(int argc, char **argv) { if(argc!=2)return 2;struct proc_bsdinfo i;'
            'if(proc_pidinfo(atoi(argv[1]),PROC_PIDTBSDINFO,0,&i,sizeof(i))!=sizeof(i))return 3;'
            'printf("%llu %llu\\n",i.pbi_start_tvsec,i.pbi_start_tvusec);}\n')
        for source, target in [(project / "PlayerMac/SoloistHost/main.c", cls.host),
                               (cls.root / "child.c", cls.child), (cls.root / "identity.c", cls.identity)]:
            subprocess.run(["xcrun", "clang", "-O2", "-Wall", "-Wextra", "-Werror", str(source), "-o", str(target)], check=True)

    def run_fixture(self, ignore_term=False, mismatch=False):
        child = subprocess.Popen([str(self.child)] + (["ignore"] if ignore_term else []), stdout=subprocess.PIPE)
        self.assertEqual(child.stdout.readline(), b"READY\n")
        identity = subprocess.check_output([str(self.identity), str(child.pid)], text=True).split()
        if mismatch:
            identity[1] = str((int(identity[1]) + 1) % 1_000_000)
        host = subprocess.Popen([str(self.host), str(child.pid), str(self.child), *identity],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        try:
            if mismatch:
                host.communicate(timeout=2)
                self.assertEqual(host.returncode, 3)
                self.assertIsNone(child.poll())
            else:
                self.assertEqual(host.stdout.readline(), b"READY\n")
                began = time.monotonic()
                host.stdin.close()
                child.wait(timeout=2)
                host.wait(timeout=2)
                self.assertLess(time.monotonic() - began, 2)
                self.assertEqual(child.returncode, -9 if ignore_term else -15)
        finally:
            if child.poll() is None: child.kill()
            child.wait(timeout=2)
            if host.poll() is None: host.kill()
            host.wait(timeout=2)
            child.stdout.close()
            host.stdout.close()
            if not host.stdin.closed: host.stdin.close()

    def test_lifetime_eof(self): self.run_fixture()
    def test_escalation_is_bounded(self): self.run_fixture(ignore_term=True)
    def test_reused_pid_identity_is_rejected(self): self.run_fixture(mismatch=True)


if __name__ == "__main__":
    unittest.main()
