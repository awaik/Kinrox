# Source: direct-mcp .agents/tests/test_agent_monitor.py, 2026-11-21 update: stream interruption, agent-monitor (logic unchanged; text translated to English).
"""Tests of the unconditional agent silence check (.agents/lib/agent_monitor.py, .agents/bin/agent-monitor).

Run: PYTHONDONTWRITEBYTECODE=1 python3 .agents/tests/test_agent_monitor.py
"""

import datetime
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_agent_watchdog import SOURCE, make_script, open_agy_log_snippet  # noqa: E402

import agent_monitor  # noqa: E402

MONITOR_BIN = SOURCE / ".agents/bin/agent-monitor"


def glog(moment, text):
    return f"I{moment:%m%d} {moment:%H:%M:%S}.000000    1 http_helpers.go:771] {text}\n"


class AgentMonitorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix=f"agent-monitor-{self._testMethodName}-")).resolve()
        if os.environ.get("KINROX_KEEP_TEST_TEMP") != "1":
            self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.log = self.tmp / "stage.log"
        self.log.write_text("Waiting for `task-52`...\n", encoding="utf-8")
        old = time.time() - 3600
        os.utime(self.log, (old, old))
        self.cli_log = self.tmp / "antigravity-cli" / "log" / "cli-test.log"

    def test_last_activity_epoch_reads_glog_time_of_activity_lines_only(self):
        now = datetime.datetime.now().replace(microsecond=0)
        active = now - datetime.timedelta(minutes=44)
        self.cli_log.parent.mkdir(parents=True)
        self.cli_log.write_text(
            glog(active, "URL: https://x/v1internal:streamGenerateContent?alt=sse")
            + glog(now - datetime.timedelta(minutes=5), "URL: https://x/v1internal:loadCodeAssist"),
            encoding="utf-8")
        self.assertEqual(agent_monitor.last_activity_epoch([self.cli_log], now), active.timestamp())
        self.assertIsNone(agent_monitor.last_activity_epoch([self.tmp / "missing.log"], now))

    def start_fake(self, body):
        fake = make_script(self.tmp / "fake-agy.py", open_agy_log_snippet(self.cli_log) + body)
        proc = subprocess.Popen([sys.executable, str(fake)])
        self.addCleanup(lambda: proc.poll() is None and proc.kill())
        time.sleep(0.5)
        return proc

    def run_monitor(self, pid, timeout, quiet_minutes="0.02"):
        return subprocess.run(
            [sys.executable, str(MONITOR_BIN), "--log", str(self.log), "--pid", str(pid),
             "--quiet-minutes", quiet_minutes, "--interval", "0.2"],
            env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"),
            capture_output=True, text=True, timeout=timeout,
        )

    def test_reports_silence_regardless_of_log_text_then_finish(self):
        old = datetime.datetime.now() - datetime.timedelta(hours=1)
        proc = self.start_fake(f"""
import time
_agy_log.write({glog(old, "URL: https://x/v1internal:streamGenerateContent?alt=sse")!r})
_agy_log.flush()
time.sleep(3.0)
""")
        res = self.run_monitor(proc.pid, timeout=20)
        self.assertEqual(res.returncode, 0, res.stderr)
        lines = res.stdout.splitlines()
        self.assertTrue(lines and lines[0].startswith("QUIET "), res.stdout)
        self.assertIn("last_line: Waiting for `task-52`...", lines[0])
        self.assertTrue(lines[-1].startswith(f"FINISHED pid={proc.pid}"), res.stdout)
        # Repeats at most once per --quiet-minutes (here 1.2 s while the agent lives ~3 s).
        self.assertLessEqual(sum(line.startswith("QUIET") for line in lines), 3, res.stdout)

    def test_active_agent_is_not_reported(self):
        proc = self.start_fake("""
import datetime, time
for _ in range(12):
    now = datetime.datetime.now()
    _agy_log.write(f"I{now:%m%d} {now:%H:%M:%S}.000000 1 x.go:1] URL: v1internal:streamGenerateContent\\n")
    _agy_log.flush()
    time.sleep(0.25)
""")
        res = self.run_monitor(proc.pid, timeout=20, quiet_minutes="0.05")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertNotIn("QUIET", res.stdout)
        self.assertIn("FINISHED", res.stdout)

    def test_snapshot_preserves_last_active_after_worker_exits_and_refreshes_rotated_logs(self):
        state = {}
        orig_find = agent_monitor.find_agy_logs
        orig_workers = agent_monitor.working_descendants
        log_v1 = self.tmp / "antigravity-cli" / "log" / "cli-v1.log"
        log_v2 = self.tmp / "antigravity-cli" / "log" / "cli-v2.log"
        log_v1.parent.mkdir(parents=True, exist_ok=True)
        old = datetime.datetime.now() - datetime.timedelta(hours=1)
        log_v1.write_text(glog(old, "streamGenerateContent"), encoding="utf-8")
        current_logs = [str(log_v1)]
        current_workers = [999]
        try:
            agent_monitor.find_agy_logs = lambda _pid: list(current_logs)
            agent_monitor.working_descendants = lambda _pid, _grace: list(current_workers)

            first_last, _ = agent_monitor.snapshot(self.log, None, 123, None, state)
            self.assertAlmostEqual(first_last, time.time(), delta=5)

            # Worker finishes: silence must not jump back by 3600 s to the old log mtime.
            current_workers = []
            second_last, _ = agent_monitor.snapshot(self.log, None, 123, None, state)
            self.assertGreaterEqual(second_last, first_last)

            # Log rotates while old file still exists on disk: refresh picks up log_v2.
            recent = datetime.datetime.now().replace(microsecond=0)
            log_v2.write_text(glog(recent, "streamGenerateContent"), encoding="utf-8")
            current_logs = [str(log_v2)]
            state["cli_logs_checked_at"] = 0.0
            state["last_active"] = old.timestamp()
            third_last, _ = agent_monitor.snapshot(self.log, None, 123, None, state)
            self.assertEqual(state["cli_logs"], [str(log_v2)])
            self.assertAlmostEqual(third_last, recent.timestamp(), delta=2)
        finally:
            agent_monitor.find_agy_logs = orig_find
            agent_monitor.working_descendants = orig_workers


if __name__ == "__main__":
    unittest.main(verbosity=2)
