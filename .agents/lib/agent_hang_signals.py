# Source: direct-mcp .agents/lib/agent_hang_signals.py, 2026-11-21 update: stream interruption, agent-monitor (logic unchanged; text translated to English).
"""Signals that agy has finished its work or hung, for the idle watchdog.

Three signals, each with its own quiet threshold (the evidence of work itself - stage log,
working descendants, agy activity lines - is checked by agent_watchdog):

* the "root agent idle; waiting for" marker as the last stage-log line - idle_seconds;
* the done_file report ends with a "РЕЗУЛЬТАТ:" line - confirmed_idle_seconds;
* the agy conversation database (`*/antigravity-cli/conversations/<id>.db`, table `steps`) has
  a step in the "running" status (status = 1) followed by a recorded stream interruption
  ("The stream was interrupted") - confirmed_idle_seconds. agy never closes such a step and at
  the end waits for it as a background task (analysis 2026-11-21: 8 of 8 conversations with
  such a step hung for 27-596 min, ~190 without one exited within 0-3 min). Steps that were
  already hanging before the watchdog started (a conversation resumed via --conversation) are
  not counted.

Errors reading the database or the file list mean "unknown" and never stop agy.
"""

import os
import re
import sqlite3
import subprocess
from pathlib import Path

from agent_activity import last_nonempty_line, report_done_marker

IDLE_MARKER_RE = re.compile(r"^root agent idle; waiting for")
ERROR_STEP_TYPE = 17
STREAM_INTERRUPTED = b"The stream was interrupted"
_UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
_SKIP_LSOF_FDS = frozenset({"cwd", "rtd", "txt", "mem"})


def conversation_dbs_from_paths(paths):
    """Open file paths -> conversation databases `<base>/antigravity-cli/conversations/<id>.db`."""
    found = set()
    for raw in paths:
        parts = Path(raw).parts
        for i in range(len(parts) - 2):
            if parts[i] != "antigravity-cli" or parts[i + 1] not in ("conversations", "brain"):
                continue
            name = parts[i + 2]
            if parts[i + 1] == "conversations":
                name = name.split(".db", 1)[0]
            if _UUID_RE.match(name):
                found.add(str(Path(*parts[:i + 1], "conversations", f"{name}.db")))
            break
    return sorted(found)


def open_paths(pid):
    """Files and directories open by the process: /proc/<pid>/fd, otherwise lsof; None - failed."""
    proc_fd = Path(f"/proc/{pid}/fd")
    if proc_fd.is_dir():
        targets = []
        try:
            with os.scandir(proc_fd) as entries:
                for entry in entries:
                    try:
                        targets.append(os.readlink(entry.path))
                    except OSError:
                        continue
        except OSError:
            return None
        return targets
    try:
        result = subprocess.run(["lsof", "-a", "-p", str(pid), "-Fn"], capture_output=True,
                                text=True, timeout=5, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    paths, fd = [], None
    for line in result.stdout.splitlines():
        if line[:1] == "f":
            fd = line[1:]
        elif line[:1] == "n" and fd not in _SKIP_LSOF_FDS:
            paths.append(line[1:])
    return paths


def orphaned_steps(db_path):
    """Indexes of status = 1 steps followed by a stream-interruption error step; None if unreadable."""
    if not Path(db_path).is_file():
        return None
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2)
        try:
            rows = conn.execute(
                "select p.idx from steps p where p.status = 1 and exists ("
                " select 1 from steps s where s.idx > p.idx"
                " and s.step_type = ? and instr(s.step_payload, ?) > 0)",
                (ERROR_STEP_TYPE, STREAM_INTERRUPTED),
            ).fetchall()
        finally:
            conn.close()
    except sqlite3.Error:
        return None
    return {int(idx) for (idx,) in rows}


class OrphanStepProbe:
    """Finds the agy process conversation database and reports new unclosed steps after an interruption."""

    def __init__(self, pid, path_lister=None, baseline=None, db_path=None):
        self.pid = pid
        self._lister = path_lister or open_paths
        self.db_path = str(db_path) if db_path is not None else None
        self._baseline = None if baseline is None else set(baseline)

    def poll(self):
        if self.db_path is None:
            paths = self._lister(self.pid)
            dbs = conversation_dbs_from_paths(paths or [])
            if len(dbs) != 1:
                return False
            self.db_path = dbs[0]
        steps = orphaned_steps(self.db_path)
        if steps is None:
            return False
        if self._baseline is None:
            self._baseline = steps
            return False
        return bool(steps - self._baseline)


class HangSignals:
    """Decides which signal fired and which quiet threshold applies to it."""

    def __init__(self, pid, log_path, idle_seconds, *, done_file=None,
                 confirmed_idle_seconds=None, orphan_probe=None, orphan_baseline=None):
        self.log_path = Path(log_path)
        self.idle_seconds = idle_seconds
        self.confirmed_idle_seconds = (idle_seconds if confirmed_idle_seconds is None
                                       else confirmed_idle_seconds)
        enabled = self.confirmed_idle_seconds > 0
        self.done_file = Path(done_file) if done_file is not None and enabled else None
        self.orphan_probe = (
            orphan_probe or OrphanStepProbe(pid, baseline=orphan_baseline)
        ) if enabled else None

    def check(self):
        """(threshold, reason) of the fired signal with the smallest threshold, or None.

        Polls the conversation database on every call: when no baseline was captured before
        launch, the first successful poll remembers pre-existing hung steps.
        """
        found = []
        orphan = self.orphan_probe.poll() if self.orphan_probe is not None else False
        line = last_nonempty_line(self.log_path, skip_prefixes=("[watchdog]",))
        if line and IDLE_MARKER_RE.match(line):
            found.append((self.idle_seconds, '"root agent idle"'))
        marker = report_done_marker(self.done_file) if self.done_file is not None else None
        if marker is not None:
            found.append((self.confirmed_idle_seconds, f'the report was submitted ("{marker}")'))
        if orphan:
            found.append((self.confirmed_idle_seconds,
                          "a stream interruption with an unclosed conversation step"))
        return min(found, key=lambda item: item[0]) if found else None
