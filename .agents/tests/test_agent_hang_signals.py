# Source: direct-mcp .agents/tests/test_agent_hang_signals.py, 2026-11-21 update: stream interruption, agent-monitor (logic unchanged; text translated to English).
"""Tests of the agy hang signals (.agents/lib/agent_hang_signals.py) and their use in the watchdog.

Analysis 2026-11-21: a stream interruption to the model during a tool call leaves the conversation
step in status = 1 forever, and at the end agy waits for it as a background task.

Run: PYTHONDONTWRITEBYTECODE=1 python3 .agents/tests/test_agent_hang_signals.py
"""

import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_agent_watchdog import WATCHDOG_BIN, make_script, open_agy_log_snippet  # noqa: E402

import agent_hang_signals  # noqa: E402

CONV_ID = "bade3dad-3fc3-468a-8bc8-2d2c991038ea"
INTERRUPT = b"The stream was interrupted. Please continue the task you were working on."


def create_db(path, steps):
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.execute("create table steps (idx integer primary key, step_type integer, "
                 "status integer, step_payload blob)")
    conn.executemany("insert into steps values (?, ?, ?, ?)", steps)
    conn.commit()
    conn.close()


class HangSignalUnitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="hang-signals-")).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.base = self.tmp / ".gemini" / "antigravity-cli"
        self.db = self.base / "conversations" / f"{CONV_ID}.db"

    def test_conversation_db_found_from_open_paths(self):
        paths = [
            str(self.base / "conversations" / f"{CONV_ID}.db-wal"),
            str(self.base / "brain" / CONV_ID / "scratch"),
            str(self.base / "log" / "cli-20261121_104303.log"),
            str(self.base / "conversations" / "not-a-uuid.db"),
            "/usr/lib/libc.dylib",
        ]
        self.assertEqual(agent_hang_signals.conversation_dbs_from_paths(paths), [str(self.db)])

    def test_orphaned_steps_only_before_interrupt(self):
        create_db(self.db, [
            (0, 14, 3, b"task"),
            (1, 132, 1, b"grep ..."),            # hung: interruption after it
            (2, 17, 3, INTERRUPT),
            (3, 132, 3, b"grep ... again"),
            (4, 132, 1, b"npm test"),            # running now: no interruption after it
        ])
        self.assertEqual(agent_hang_signals.orphaned_steps(self.db), {1})
        self.assertIsNone(agent_hang_signals.orphaned_steps(self.tmp / "missing.db"))
        broken = self.tmp / "broken.db"
        broken.write_bytes(b"not a database")
        self.assertIsNone(agent_hang_signals.orphaned_steps(broken))

    def test_probe_ignores_orphans_existing_before_start(self):
        create_db(self.db, [(0, 132, 1, b"old"), (1, 17, 3, INTERRUPT)])
        probe = agent_hang_signals.OrphanStepProbe(123, path_lister=lambda _pid: [str(self.db)])
        self.assertFalse(probe.poll())   # baseline: step 0 hung before the start
        self.assertFalse(probe.poll())
        conn = sqlite3.connect(self.db)
        conn.executemany("insert into steps values (?, ?, ?, ?)",
                         [(2, 132, 1, b"new"), (3, 17, 3, INTERRUPT)])
        conn.commit()
        conn.close()
        self.assertTrue(probe.poll())

    def test_probe_without_single_conversation_never_fires(self):
        for paths in (None, [], [str(self.base / "conversations" / f"{CONV_ID}.db"),
                                 str(self.base / "brain" / "00000000-0000-4000-8000-000000000000")]):
            with self.subTest(paths=paths):
                probe = agent_hang_signals.OrphanStepProbe(1, path_lister=lambda _pid, p=paths: p)
                self.assertFalse(probe.poll())
                self.assertFalse(probe.poll())

    def test_orphaned_steps_ignores_non_error_steps_mentioning_interrupt_text(self):
        create_db(self.db, [
            (0, 14, 3, b"prompt mentioning The stream was interrupted"),
            (1, 132, 1, b"running command"),
            (2, 132, 3, b"read AGENTS.md: The stream was interrupted"),
            (3, 15, 3, b"model reply: The stream was interrupted"),
        ])
        self.assertEqual(agent_hang_signals.orphaned_steps(self.db), set())

    def test_probe_with_empty_baseline_catches_early_interrupt(self):
        create_db(self.db, [(0, 132, 1, b"early"), (1, 17, 3, INTERRUPT)])
        probe = agent_hang_signals.OrphanStepProbe(
            123, path_lister=lambda _pid: [str(self.db)], baseline=frozenset())
        self.assertTrue(probe.poll())

    def test_hang_signals_ignores_watchdog_lines_and_accepts_english_result_marker(self):
        log = self.tmp / "stage.log"
        log.write_text(
            "root agent idle; waiting for 1 background task(s) to finish\n"
            "[watchdog] could not list processes (ps): transient - the idle watchdog will not stop agy\n",
            encoding="utf-8",
        )
        signals = agent_hang_signals.HangSignals(1, log, 1800, confirmed_idle_seconds=0)
        self.assertEqual(signals.check(), (1800, '"root agent idle"'))

        report = self.tmp / "investigate-report.md"
        report.write_text("Summary\n`RESULT: cause found - fixed`\n", encoding="utf-8")
        log.write_text("working\n", encoding="utf-8")
        with_report = agent_hang_signals.HangSignals(
            1, log, 1800, done_file=report, confirmed_idle_seconds=600,
            orphan_probe=type("NoOrphan", (), {"poll": lambda self: False})(),
        )
        self.assertEqual(with_report.check(), (600, 'the report was submitted ("RESULT:")'))

    def test_confirmed_threshold_zero_disables_report_and_orphan_signals(self):
        log = self.tmp / "stage.log"
        log.write_text("working\n", encoding="utf-8")
        report = self.tmp / "report.md"
        report.write_text("РЕЗУЛЬТАТ: done\n", encoding="utf-8")

        class AlwaysOrphan:
            def poll(self):
                return True

        off = agent_hang_signals.HangSignals(1, log, 1800, done_file=report,
                                             confirmed_idle_seconds=0, orphan_probe=AlwaysOrphan())
        self.assertIsNone(off.check())
        on = agent_hang_signals.HangSignals(1, log, 1800, done_file=report,
                                            confirmed_idle_seconds=600, orphan_probe=AlwaysOrphan())
        self.assertEqual(on.check(), (600, 'the report was submitted ("РЕЗУЛЬТАТ:")'))
        report.write_text("draft\n", encoding="utf-8")
        self.assertEqual(on.check(), (600, "a stream interruption with an unclosed conversation step"))


class OrphanStepWatchdogCliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix=f"hang-cli-{self._testMethodName}-")).resolve()
        if os.environ.get("KINROX_KEEP_TEST_TEMP") != "1":
            self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.log = self.tmp / "stage.log"
        self.db = self.tmp / "antigravity-cli" / "conversations" / f"{CONV_ID}.db"

    def fake_agent(self, name, interrupt):
        # The fake agy keeps its cli-*.log and conversation database open, like the real one.
        tail = (
            "conn.executemany('insert into steps values (?, ?, ?, ?)', "
            f"[(2, 132, 1, b'grep'), (3, 17, 3, {INTERRUPT!r})])\nconn.commit()\n"
            if interrupt else "conn.execute('insert into steps values (2, 132, 1, ?)', (b'grep',))\nconn.commit()\n"
        )
        return make_script(self.tmp / name, open_agy_log_snippet(
            self.tmp / "antigravity-cli" / "log" / "cli-test.log") + f"""
import signal, sqlite3, sys, time
signal.signal(signal.SIGTERM, lambda *_: sys.exit(45))
conn = sqlite3.connect({str(self.db)!r})
conn.execute("create table steps (idx integer primary key, step_type integer, status integer, step_payload blob)")
conn.executemany("insert into steps values (?, ?, ?, ?)", [(0, 14, 3, b'task'), (1, 15, 3, b'model')])
conn.commit()
print("Running checks...", file=sys.stderr, flush=True)
time.sleep(1.0)
{tail}time.sleep(3.0)
print("finished-itself", file=sys.stderr, flush=True)
""")

    def run_watchdog(self, fake):
        self.db.parent.mkdir(parents=True, exist_ok=True)
        with open(self.log, "ab") as handle:
            return subprocess.run(
                [sys.executable, str(WATCHDOG_BIN), "--log", str(self.log), "--idle-seconds", "30",
                 "--confirmed-idle-seconds", "1", "--poll-interval", "0.15",
                 "--startup-grace", "60", "--", sys.executable, str(fake)],
                cwd=self.tmp, env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"),
                stdout=handle, stderr=handle, timeout=20,
            )

    def test_stops_agent_waiting_for_step_orphaned_by_stream_interrupt(self):
        res = self.run_watchdog(self.fake_agent("fake-orphan.py", interrupt=True))
        log_text = self.log.read_text(encoding="utf-8")
        self.assertEqual(res.returncode, 45, log_text)
        self.assertNotIn("finished-itself", log_text)
        self.assertIn("after a stream interruption with an unclosed conversation step", log_text)

    def test_running_step_without_interrupt_is_not_a_hang(self):
        res = self.run_watchdog(self.fake_agent("fake-running.py", interrupt=False))
        log_text = self.log.read_text(encoding="utf-8")
        self.assertEqual(res.returncode, 0, log_text)
        self.assertIn("finished-itself", log_text)
        self.assertNotIn("[watchdog]", log_text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
