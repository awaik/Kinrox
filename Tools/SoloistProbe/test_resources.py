"""Check CPU units against getrusage, independently of the resource reader."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = r'''
#include <stdio.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
static double cpu(void) {
    struct timespec t;
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
int main(void) {
    double start = cpu();
    while (cpu() - start < 0.3) {}
    struct rusage r;
    getrusage(RUSAGE_SELF, &r);
    printf("%.0f\n", (r.ru_utime.tv_sec + r.ru_stime.tv_sec) * 1e9
           + (r.ru_utime.tv_usec + r.ru_stime.tv_usec) * 1e3);
    fflush(stdout);
    sleep(10);
}
'''


class ResourceUnitsTests(unittest.TestCase):
    def test_cpu_nanoseconds_match_getrusage(self):
        root = Path(tempfile.mkdtemp(prefix="resource-test-", dir=ROOT / "build"))
        fixture = root / "fixture.c"
        fixture.write_text(SOURCE)
        for source, output in [(fixture, root / "fixture"),
                               (ROOT / "Tools/SoloistProbe/resources.c", root / "resources")]:
            subprocess.run(["xcrun", "clang", "-O2", "-Wall", "-Wextra", "-Werror",
                            str(source), "-o", str(output)], check=True, capture_output=True)
        child = subprocess.Popen([str(root / "fixture")], stdout=subprocess.PIPE, text=True)
        try:
            expected = float(child.stdout.readline())
            sample = json.loads(subprocess.check_output([str(root / "resources"), str(child.pid)]))
            observed = sample["user_ns"] + sample["system_ns"]
            self.assertAlmostEqual(observed / expected, 1, delta=0.1)
        finally:
            child.terminate()
            child.wait(timeout=2)
            child.stdout.close()


if __name__ == "__main__":
    unittest.main()
