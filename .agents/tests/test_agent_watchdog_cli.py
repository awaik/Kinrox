# Source: direct-mcp .agents/tests/test_agent_watchdog_cli.py, 2026-11-21 (paths kept; text translated to English).
"""Tests of the agy idle watchdog CLI wrapper (.agents/bin/agent-watchdog) with fake agents.

Run: PYTHONDONTWRITEBYTECODE=1 python3 .agents/tests/test_agent_watchdog_cli.py
"""

import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_agent_watchdog import MARKER, WATCHDOG_BIN, make_script, open_agy_log_snippet, pid_alive  # noqa: E402


class WatchdogCliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix=f"watchdog-cli-{self._testMethodName}-")).resolve()
        if os.environ.get("KINROX_KEEP_TEST_TEMP") != "1":
            self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.log = self.tmp / "stage.log"

    def agy_log(self, name="cli-test.log"):
        return self.tmp / "antigravity-cli" / "log" / name

    def run_watchdog(self, log, idle_seconds, cmd, extra_args=(), stdout=None, env=None):
        full_cmd = [
            sys.executable, str(WATCHDOG_BIN),
            "--log", str(log), "--idle-seconds", str(idle_seconds),
            *extra_args, "--", *cmd,
        ]
        run_env = dict(os.environ) if env is None else dict(env)
        run_env["PYTHONDONTWRITEBYTECODE"] = "1"
        with open(log, "ab") as log_handle:
            out_handle = open(stdout, "wb") if stdout is not None else log_handle
            try:
                return subprocess.run(
                    full_cmd, cwd=self.tmp, env=run_env,
                    stdout=out_handle, stderr=log_handle, timeout=20,
                )
            finally:
                if stdout is not None:
                    out_handle.close()

    def test_stops_idle_agent_with_sigterm_and_preserves_exit_code(self):
        # Starts a "startup MCP" right at t=0 and hangs on the marker;
        # SIGTERM reaches only the agent PID, which prints JSON and exits with its own code 42.
        fake = make_script(self.tmp / "fake-idle.py", open_agy_log_snippet(self.agy_log()) + f"""
import signal, subprocess, sys, time
startup = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(15)"])
def on_term(_sig, _frame):
    print('{{"status":"ERROR","error":"interrupted"}}', flush=True)
    startup.terminate()
    try:
        startup.wait(timeout=2)
    except Exception:
        startup.kill()
    sys.exit(42)
signal.signal(signal.SIGTERM, on_term)
print({MARKER!r}, file=sys.stderr, flush=True)
time.sleep(20)
""")
        out_json = self.tmp / "out.json"
        res = self.run_watchdog(
            self.log, 1, [sys.executable, str(fake)],
            extra_args=("--poll-interval", "0.15", "--startup-grace", "60"),
            stdout=out_json,
        )
        self.assertEqual(res.returncode, 42)
        self.assertIn('"interrupted"', out_json.read_text(encoding="utf-8"))
        log_text = self.log.read_text(encoding="utf-8")
        self.assertRegex(
            log_text,
            r"\[watchdog\] agy idle for \d+ s after \"root agent idle\", no working background processes - stopped \(SIGTERM\)",
        )

    def test_does_not_stop_while_working_descendant_is_alive(self):
        # Waits longer than startup_grace (1 s), then starts a 2.2 s child sleep (> idle_seconds=1).
        # The agy log is open and silent, so only last_working_at, refreshed every tick, protects it.
        fake = make_script(self.tmp / "fake-worker.py", open_agy_log_snippet(self.agy_log()) + f"""
import subprocess, sys, time
time.sleep(2.2)
worker = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(2.2)"])
print({MARKER!r}, file=sys.stderr, flush=True)
worker.wait()
print("finished-after-worker", file=sys.stderr, flush=True)
""")
        res = self.run_watchdog(
            self.log, 1, [sys.executable, str(fake)],
            extra_args=("--poll-interval", "0.15", "--startup-grace", "1"),
        )
        log_text = self.log.read_text(encoding="utf-8")
        self.assertEqual(res.returncode, 0, log_text)
        self.assertIn("finished-after-worker", log_text)
        self.assertNotIn("[watchdog]", log_text)

    def test_activity_log_prevents_stop_until_quiet(self):
        phase_file = self.tmp / "phase.txt"
        fake = make_script(self.tmp / "fake-active.py", open_agy_log_snippet(self.agy_log("cli-active.log")) + f"""
import pathlib, signal, sys, time
signal.signal(signal.SIGTERM, lambda *_: sys.exit(41))
print({MARKER!r}, file=sys.stderr, flush=True)
for idx in range(6):
    time.sleep(0.4)
    line = "INFO streamGenerateContent step\\n" if idx % 2 == 0 else "INFO Monitor edit_file FINISHED\\n"
    _agy_log.write(line)
    _agy_log.flush()
pathlib.Path({str(phase_file)!r}).write_text("active-phase-done", encoding="utf-8")
# After the activity ends only background lines follow, which are not activity.
for _ in range(30):
    time.sleep(0.3)
    _agy_log.write("INFO loadCodeAssist\\nINFO fetchAvailableModels\\nINFO token refreshed\\n")
    _agy_log.flush()
""")
        res = self.run_watchdog(
            self.log, 1, [sys.executable, str(fake)],
            extra_args=("--poll-interval", "0.15", "--startup-grace", "60"),
        )
        log_text = self.log.read_text(encoding="utf-8")
        self.assertEqual(res.returncode, 41, log_text)
        self.assertTrue(phase_file.is_file(), "the agent was stopped before its active phase ended")
        self.assertEqual(phase_file.read_text(encoding="utf-8"), "active-phase-done")
        self.assertIn("stopped (SIGTERM)", log_text)

    def test_missing_agy_log_warns_once_and_never_stops(self):
        fake = make_script(self.tmp / "fake-no-agy-log.py", f"""
import sys, time
print({MARKER!r}, file=sys.stderr, flush=True)
time.sleep(2.2)
print({MARKER!r}, file=sys.stderr, flush=True)
time.sleep(2.2)
""")
        res = self.run_watchdog(
            self.log, 1, [sys.executable, str(fake)],
            extra_args=("--poll-interval", "0.15"),
        )
        log_text = self.log.read_text(encoding="utf-8")
        self.assertEqual(res.returncode, 0, log_text)
        self.assertEqual(log_text.count("[watchdog] could not find the agy activity log:"), 1, log_text)
        self.assertNotIn("stopped (SIGTERM)", log_text)

    def test_zombie_child_does_not_block_stop(self):
        fake = make_script(self.tmp / "fake-zombie.py", open_agy_log_snippet(self.agy_log("cli-zombie.log")) + f"""
import signal, subprocess, sys, time
signal.signal(signal.SIGTERM, lambda *_: sys.exit(43))
zombie = subprocess.Popen([sys.executable, "-c", "pass"])
time.sleep(0.3)
print({MARKER!r}, file=sys.stderr, flush=True)
time.sleep(20)
""")
        res = self.run_watchdog(
            self.log, 1, [sys.executable, str(fake)],
            extra_args=("--poll-interval", "0.15", "--startup-grace", "0"),
        )
        log_text = self.log.read_text(encoding="utf-8")
        self.assertEqual(res.returncode, 43, log_text)
        self.assertIn("stopped (SIGTERM)", log_text)

    def test_early_shell_child_blocks_stop(self):
        # A direct sh child started at t=0 (inside startup_grace=60) protects agy.
        fake = make_script(self.tmp / "fake-shell.py", open_agy_log_snippet(self.agy_log("cli-shell.log")) + f"""
import subprocess, sys, time
shell = subprocess.Popen(["/bin/sh", "-c", "sleep 2.3; :"])
print({MARKER!r}, file=sys.stderr, flush=True)
shell.wait()
print("shell-finished", file=sys.stderr, flush=True)
""")
        res = self.run_watchdog(
            self.log, 1, [sys.executable, str(fake)],
            extra_args=("--poll-interval", "0.15", "--startup-grace", "60"),
        )
        log_text = self.log.read_text(encoding="utf-8")
        self.assertEqual(res.returncode, 0, log_text)
        self.assertIn("shell-finished", log_text)
        self.assertNotIn("[watchdog]", log_text)

    def test_cleans_up_orphan_grandchild_after_sigterm_exit(self):
        # The agent exits on SIGTERM at once without killing its grandchild (which also ignores SIGTERM);
        # the watchdog cleans up the remaining process group.
        gpid_file = self.tmp / "grandchild.pid"
        grandchild_code = (
            "import os, pathlib, signal, time; "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            f"pathlib.Path({str(gpid_file)!r}).write_text(str(os.getpid()), encoding='utf-8'); "
            "time.sleep(30)"
        )
        child_code = (
            "import subprocess, sys, time; "
            f"subprocess.Popen([sys.executable, '-c', {grandchild_code!r}]); "
            "time.sleep(30)"
        )
        fake = make_script(self.tmp / "fake-orphan.py", open_agy_log_snippet(self.agy_log("cli-orphan.log")) + f"""
import os, pathlib, signal, subprocess, sys, time
subprocess.Popen([sys.executable, "-c", {child_code!r}])
deadline = time.monotonic() + 5
while not pathlib.Path({str(gpid_file)!r}).is_file() and time.monotonic() < deadline:
    time.sleep(0.05)
signal.signal(signal.SIGTERM, lambda *_: os._exit(44))
print({MARKER!r}, file=sys.stderr, flush=True)
time.sleep(20)
""")
        def kill_leftover():
            if gpid_file.is_file():
                try:
                    os.kill(int(gpid_file.read_text(encoding="utf-8").strip()), signal.SIGKILL)
                except OSError:
                    pass
        self.addCleanup(kill_leftover)

        res = self.run_watchdog(
            self.log, 1, [sys.executable, str(fake)],
            extra_args=("--poll-interval", "0.15", "--startup-grace", "60"),
        )
        self.assertEqual(res.returncode, 44, self.log.read_text(encoding="utf-8"))
        self.assertTrue(gpid_file.is_file())
        gpid = int(gpid_file.read_text(encoding="utf-8").strip())
        deadline = time.monotonic() + 1.0
        while pid_alive(gpid) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(pid_alive(gpid), f"grandchild {gpid} survived the agy stop")

    def test_does_not_stop_when_marker_is_not_last_line(self):
        fake = make_script(self.tmp / "fake-continued.py", open_agy_log_snippet(self.agy_log()) + f"""
import sys, time
print({MARKER!r}, file=sys.stderr, flush=True)
print("continued work after marker", file=sys.stderr, flush=True)
time.sleep(1.6)
""")
        res = self.run_watchdog(
            self.log, 1, [sys.executable, str(fake)],
            extra_args=("--poll-interval", "0.15"),
        )
        log_text = self.log.read_text(encoding="utf-8")
        self.assertEqual(res.returncode, 0, log_text)
        self.assertNotIn("[watchdog]", log_text)

    def test_idle_seconds_zero_disables_watchdog(self):
        fake = make_script(self.tmp / "fake-zero.py", f"""
import sys, time
print({MARKER!r}, file=sys.stderr, flush=True)
time.sleep(1.4)
""")
        res = self.run_watchdog(
            self.log, 0, [sys.executable, str(fake)],
            extra_args=("--poll-interval", "0.15"),
        )
        log_text = self.log.read_text(encoding="utf-8")
        self.assertEqual(res.returncode, 0, log_text)
        self.assertNotIn("[watchdog]", log_text)

    def test_missing_ps_warns_once_and_never_stops_agent(self):
        empty_bin = self.tmp / "empty-bin"
        empty_bin.mkdir()
        fake = make_script(self.tmp / "fake-no-ps.py", f"""
import sys, time
print({MARKER!r}, file=sys.stderr, flush=True)
time.sleep(2.2)
print({MARKER!r}, file=sys.stderr, flush=True)
time.sleep(2.2)
""")
        env = dict(os.environ, PATH=str(empty_bin))
        res = self.run_watchdog(
            self.log, 1, [sys.executable, str(fake)],
            extra_args=("--poll-interval", "0.15"),
            env=env,
        )
        log_text = self.log.read_text(encoding="utf-8")
        self.assertEqual(res.returncode, 0, log_text)
        self.assertEqual(log_text.count("[watchdog] could not list processes (ps)"), 1, log_text)
        self.assertNotIn("stopped (SIGTERM)", log_text)

    def test_escalates_to_sigkill_when_sigterm_ignored(self):
        fake = make_script(self.tmp / "fake-ignore-term.py", open_agy_log_snippet(self.agy_log()) + f"""
import signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
print({MARKER!r}, file=sys.stderr, flush=True)
time.sleep(20)
""")
        res = self.run_watchdog(
            self.log, 1, [sys.executable, str(fake)],
            extra_args=("--poll-interval", "0.15", "--kill-grace", "0.4"),
        )
        self.assertEqual(res.returncode, 128 + signal.SIGKILL)
        self.assertIn("stopped (SIGTERM)", self.log.read_text(encoding="utf-8"))

    def test_forwards_sigterm_and_returns_child_code(self):
        ready = self.tmp / "ready"
        fake = make_script(self.tmp / "fake-forward.py", f"""
import pathlib, signal, sys, time
signal.signal(signal.SIGTERM, lambda *_: sys.exit(19))
pathlib.Path({str(ready)!r}).touch()
time.sleep(20)
""")
        with subprocess.Popen(
            [sys.executable, str(WATCHDOG_BIN), "--log", str(self.log),
             "--idle-seconds", "60", "--", sys.executable, str(fake)],
            cwd=self.tmp, env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ) as proc:
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(ready.exists())
                proc.send_signal(signal.SIGTERM)
                rc = proc.wait(timeout=5)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
        self.assertEqual(rc, 19)

    def test_sighup_terminates_child_process_group(self):
        ready = self.tmp / "ready"
        child_pid_file = self.tmp / "child.pid"
        fake = make_script(self.tmp / "fake-sighup.py", f"""
import os, pathlib, signal, time
signal.signal(signal.SIGHUP, signal.SIG_IGN)
pathlib.Path({str(child_pid_file)!r}).write_text(str(os.getpid()), encoding="utf-8")
pathlib.Path({str(ready)!r}).touch()
time.sleep(20)
""")
        with subprocess.Popen(
            [sys.executable, str(WATCHDOG_BIN), "--log", str(self.log),
             "--idle-seconds", "60", "--", sys.executable, str(fake)],
            cwd=self.tmp, env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ) as proc:
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(ready.exists())
                child_pid = int(child_pid_file.read_text(encoding="utf-8"))
                proc.send_signal(signal.SIGHUP)
                proc.wait(timeout=8)
                self.assertFalse(pid_alive(child_pid))
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()


    def test_stops_after_submitted_report_without_idle_marker(self):
        # 21.11: agy wrote its report and waited for its own background task - no "root agent idle" marker.
        report = self.tmp / "report.md"
        fake = make_script(self.tmp / "fake-done.py", open_agy_log_snippet(self.agy_log()) + f"""
import pathlib, signal, sys, time
signal.signal(signal.SIGTERM, lambda *_: sys.exit(43))
pathlib.Path({str(report)!r}).write_text("# Report\\n\\nРЕЗУЛЬТАТ: done\\n", encoding="utf-8")
print("Waiting for `task-52` (tsc + PG test suites)...", file=sys.stderr, flush=True)
time.sleep(20)
""")
        res = self.run_watchdog(
            self.log, 30, [sys.executable, str(fake)],
            extra_args=("--done-file", str(report), "--confirmed-idle-seconds", "1",
                        "--poll-interval", "0.15", "--startup-grace", "60"),
        )
        log_text = self.log.read_text(encoding="utf-8")
        self.assertEqual(res.returncode, 43, log_text)
        self.assertRegex(
            log_text,
            r"\[watchdog\] agy idle for \d+ s after the report was submitted \(\"РЕЗУЛЬТАТ:\"\), "
            r"no working background processes - stopped \(SIGTERM\)",
        )

    def test_report_without_result_line_or_disabled_threshold_does_not_stop(self):
        report = self.tmp / "report.md"
        for content, done_idle in (("# Report\ndraft\n", "1"), ("РЕЗУЛЬТАТ: done\n", "0")):
            with self.subTest(content=content, done_idle=done_idle):
                log = self.tmp / f"stage-{done_idle}.log"
                fake = make_script(self.tmp / f"fake-draft-{done_idle}.py", open_agy_log_snippet(self.agy_log()) + f"""
import pathlib, sys, time
pathlib.Path({str(report)!r}).write_text({content!r}, encoding="utf-8")
print("Waiting for checks...", file=sys.stderr, flush=True)
time.sleep(2.5)
print("finished-itself", file=sys.stderr, flush=True)
""")
                res = self.run_watchdog(
                    log, 30, [sys.executable, str(fake)],
                    extra_args=("--done-file", str(report), "--confirmed-idle-seconds", done_idle,
                                "--poll-interval", "0.15", "--startup-grace", "60"),
                )
                log_text = log.read_text(encoding="utf-8")
                self.assertEqual(res.returncode, 0, log_text)
                self.assertIn("finished-itself", log_text)
                self.assertNotIn("[watchdog]", log_text)

    def test_submitted_report_waits_while_agent_is_active(self):
        report = self.tmp / "report.md"
        phase_file = self.tmp / "phase.txt"
        fake = make_script(self.tmp / "fake-done-active.py", open_agy_log_snippet(self.agy_log("cli-done.log")) + f"""
import pathlib, signal, sys, time
signal.signal(signal.SIGTERM, lambda *_: sys.exit(44))
pathlib.Path({str(report)!r}).write_text("РЕЗУЛЬТАТ: done\\n", encoding="utf-8")
for _ in range(6):
    time.sleep(0.4)
    _agy_log.write("INFO streamGenerateContent step\\n")
    _agy_log.flush()
pathlib.Path({str(phase_file)!r}).write_text("active-phase-done", encoding="utf-8")
time.sleep(20)
""")
        res = self.run_watchdog(
            self.log, 30, [sys.executable, str(fake)],
            extra_args=("--done-file", str(report), "--confirmed-idle-seconds", "1",
                        "--poll-interval", "0.15", "--startup-grace", "60"),
        )
        log_text = self.log.read_text(encoding="utf-8")
        self.assertEqual(res.returncode, 44, log_text)
        self.assertTrue(phase_file.is_file(), "the agent was stopped while still working after the report")
        self.assertIn("after the report was submitted", log_text)

if __name__ == "__main__":
    unittest.main(verbosity=2)
