# Source: direct-mcp .agents/tests/test_agent_watchdog.py, 2026-11-21 (paths kept; text translated to English).
"""Tests of the agy idle watchdog (.agents/lib/agent_watchdog.py, agent_activity.py, agent-watchdog).

Run: PYTHONDONTWRITEBYTECODE=1 python3 .agents/tests/test_agent_watchdog.py
"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(SOURCE / ".agents/lib"))

import agent_activity  # noqa: E402
import agent_watchdog  # noqa: E402

WATCHDOG_BIN = SOURCE / ".agents/bin/agent-watchdog"
MARKER = "root agent idle; waiting for 1 background task(s) to finish"


def make_script(path, body):
    path.write_text("#!/usr/bin/env python3\n" + body, encoding="utf-8")
    path.chmod(0o755)
    return path


def open_agy_log_snippet(log_file):
    return (
        f"import pathlib as _p\n"
        f"_agy_log_path = _p.Path({str(log_file)!r})\n"
        f"_agy_log_path.parent.mkdir(parents=True, exist_ok=True)\n"
        f"_agy_log = open(_agy_log_path, 'a', encoding='utf-8')\n"
        f"_agy_log.write('INFO started\\n')\n"
        f"_agy_log.flush()\n"
    )


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


class WatchdogUnitTests(unittest.TestCase):
    def test_parse_etime_formats(self):
        self.assertEqual(agent_watchdog.parse_etime("00:05"), 5)
        self.assertEqual(agent_watchdog.parse_etime("03:29"), 209)
        self.assertEqual(agent_watchdog.parse_etime("01:03:29"), 3809)
        self.assertEqual(agent_watchdog.parse_etime("04-01:03:29"), 4 * 86400 + 3809)
        for bad in ("", "15", "1:2:3:4", "-1:00", "01:-02:03"):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    agent_watchdog.parse_etime(bad)

    def test_last_nonempty_line_and_marker(self):
        with tempfile.TemporaryDirectory(prefix="watchdog-lines-") as tmp:
            path = Path(tmp) / "stage.log"
            self.assertIsNone(agent_watchdog.last_nonempty_line(path))
            path.write_bytes(b"")
            self.assertIsNone(agent_watchdog.last_nonempty_line(path))
            path.write_text(f"first\n{MARKER}\n   \n\r\n", encoding="utf-8")
            for chunk in (4, 17, 65536):
                with self.subTest(chunk=chunk):
                    line = agent_watchdog.last_nonempty_line(path, chunk_size=chunk)
                    self.assertEqual(line, MARKER)
                    self.assertIsNotNone(agent_watchdog.IDLE_MARKER_RE.match(line))
            self.assertIsNone(agent_watchdog.IDLE_MARKER_RE.match("prefix " + MARKER))

    def test_parse_ps_output_handles_spaces_and_skips_foreign_bad_lines(self):
        output = "\n".join([
            "  100     1 S+   03:20 /Applications/Antigravity App/agy",
            "  101   100 S    00:05 /bin/zsh",
            "  999     1 S    -00:05 /usr/sbin/ntp-skew",
            "  998   bad_line",
            "  notpid 1 S 00:01 /bin/foo",
        ])
        parsed = agent_watchdog.parse_ps_output(output, root_pid=100)
        self.assertEqual(parsed[100], (1, "S+", 200, "/Applications/Antigravity App/agy"))
        self.assertEqual(parsed[101], (100, "S", 5, "/bin/zsh"))
        self.assertNotIn(999, parsed)
        self.assertNotIn(998, parsed)

        with self.assertRaises(agent_watchdog.ProcessListError):
            agent_watchdog.parse_ps_output("100 1 S -00:01 /bin/agy\n", root_pid=100)
        with self.assertRaises(agent_watchdog.ProcessListError):
            agent_watchdog.parse_ps_output("100 broken\n", root_pid=100)
        with self.assertRaises(agent_watchdog.ProcessListError):
            agent_watchdog.parse_ps_output("   \n", root_pid=100)

    def test_working_descendants_distinguishes_startup_shells_and_zombies(self):
        processes = {
            100: (1, "S+", 200, "/usr/local/bin/agy"),       # agy
            101: (100, "S", 195, "/usr/local/bin/node"),     # MCP started after 5 s <= 60
            102: (101, "S", 20, "/usr/local/bin/node"),      # late MCP grandchild - not traversed
            103: (100, "S", 140, "/usr/local/bin/agy"),      # boundary of exactly 60 s <= 60
            104: (100, "S", 139, "/usr/bin/python3"),        # working process after 61 s > 60
            105: (104, "S", 120, "/usr/bin/python3"),        # live grandchild of a worker
            106: (104, "Z+", 0, "/usr/bin/python3"),         # zombie grandchild - skipped
            107: (100, "Z+", 0, "/bin/zsh"),                 # zombie child - skipped
            108: (100, "S", 199, "/bin/zsh"),                # early shell (after 1 s <= 60) - working
            109: (108, "S", 199, "/bin/sleep"),              # live grandchild of an early shell - working
            110: (100, "S", 198, "-bash"),                   # early login shell - working
            111: (100, "S", 198, "sh"),                      # early sh - working
            200: (1, "S", 10, "/bin/sh"),                    # unrelated process
        }
        self.assertEqual(
            set(agent_watchdog.working_descendants(100, 60, processes)),
            {104, 105, 108, 109, 110, 111},
        )
        only_startup_and_zombies = {
            k: v for k, v in processes.items() if k not in (104, 105, 106, 108, 109, 110, 111)
        }
        self.assertEqual(agent_watchdog.working_descendants(100, 60, only_startup_and_zombies), [])
        with self.assertRaises(agent_watchdog.ProcessListError):
            agent_watchdog.working_descendants(999, 60, processes)

    def test_agy_activity_path_matching_and_lsof_parsing(self):
        self.assertTrue(agent_activity.is_agy_log_path(
            "/Users/someone/.gemini/antigravity-cli/log/cli-20261121_090000.log"
        ))
        self.assertTrue(agent_activity.is_agy_log_path(
            "/tmp/test-dir/antigravity-cli/log/cli-fake.log"
        ))
        self.assertFalse(agent_activity.is_agy_log_path(
            "/tmp/test-dir/other/log/cli-fake.log"
        ))
        self.assertFalse(agent_activity.is_agy_log_path(
            "/tmp/test-dir/antigravity-cli/log/other.log"
        ))

        lsof_out = "\n".join([
            "p1234",
            "fcwd",
            "n/tmp/antigravity-cli/log/cli-cwd.log",
            "f3",
            "aw",
            "n/tmp/a/antigravity-cli/log/cli-2.log",
            "f4",
            "au",
            "n/tmp/a/antigravity-cli/log/cli-1.log",
            "f6",
            "ar",
            "n/tmp/a/antigravity-cli/log/cli-readonly-peer.log",
            "f5",
            "aw",
            "n/tmp/a/antigravity-cli/log/not-cli.log",
        ])
        self.assertEqual(
            agent_activity.parse_lsof_paths(lsof_out),
            ["/tmp/a/antigravity-cli/log/cli-1.log", "/tmp/a/antigravity-cli/log/cli-2.log"],
        )

    def test_agy_activity_tracker_offset_noise_and_partial_lines(self):
        with tempfile.TemporaryDirectory(prefix="watchdog-act-") as tmp:
            log_dir = Path(tmp) / "antigravity-cli" / "log"
            log_dir.mkdir(parents=True)
            log1 = log_dir / "cli-1.log"
            log2 = log_dir / "cli-2.log"
            log1.write_text("INFO old streamGenerateContent\n", encoding="utf-8")

            open_files = [str(log1)]
            tracker = agent_activity.AgyActivityTracker(123, finder=lambda _pid: list(open_files))

            # The first sighting of a file counts as activity "now".
            self.assertTrue(tracker.poll())
            # No new lines - no activity.
            self.assertFalse(tracker.poll())

            # Background noise without activity lines.
            with open(log1, "a", encoding="utf-8") as fh:
                fh.write("INFO loadCodeAssist ok\nINFO fetchAvailableModels ok\nINFO token refreshed\n")
            self.assertFalse(tracker.poll())

            # An incomplete line without \n does not split the token.
            with open(log1, "a", encoding="utf-8") as fh:
                fh.write("INFO calling streamGenerate")
            self.assertFalse(tracker.poll())
            with open(log1, "a", encoding="utf-8") as fh:
                fh.write("Content now\n")
            self.assertTrue(tracker.poll())
            self.assertFalse(tracker.poll())

            # A Monitor <name> FINISHED line.
            with open(log1, "a", encoding="utf-8") as fh:
                fh.write("INFO Monitor run_command FINISHED (200ms)\n")
            self.assertTrue(tracker.poll())
            self.assertFalse(tracker.poll())

            # A second open file also counts as activity when first seen.
            log2.write_text("INFO second\n", encoding="utf-8")
            open_files.append(str(log2))
            self.assertTrue(tracker.poll())
            self.assertFalse(tracker.poll())

    def test_wait_with_watchdog_zero_idle_and_zero_timeout_waits_normally(self):
        with tempfile.TemporaryDirectory(prefix="watchdog-zero-") as tmp:
            log = Path(tmp) / "stage.log"
            log.write_text("", encoding="utf-8")
            child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(0.15)"])
            rc, idle_stopped = agent_watchdog.wait_with_watchdog(
                child, log, idle_seconds=0, timeout_seconds=0,
            )
            self.assertEqual(rc, 0)
            self.assertFalse(idle_stopped)


if __name__ == "__main__":
    unittest.main(verbosity=2)
