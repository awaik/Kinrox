# Source: direct-mcp .agents/lib/agent_monitor.py, 2026-11-21 update: stream interruption, agent-monitor (logic unchanged; text translated to English).
"""Unconditional agent silence check for the orchestrator's Monitor (owner decision 2026-11-21).

`agent-monitor <run dir | --log stage log> [--pid PID] [--quiet-minutes 30]`

Every --interval seconds it looks at all evidence of work, independently of the log text:
stage log and report.md changes, agy working descendants, the last activity line
(`streamGenerateContent`, `Monitor ... FINISHED`) in agy's own `cli-*.log` with its time.
If nothing happened for --quiet-minutes, prints one `QUIET ...` line with a summary (last log
line, unclosed conversation steps, descendants) and repeats it after every further
--quiet-minutes of silence. When the agy process has exited - a `FINISHED ...` line and exit.
Silence is measured from file times, so restarting the Monitor (at most 30 min) does not reset
it. Stops nothing: the orchestrator decides.
"""

import argparse
import datetime
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from agent_activity import ACTIVITY_LINE_RE, ActivityLogError, find_agy_logs, last_nonempty_line
from agent_hang_signals import OrphanStepProbe, open_paths
from agent_watchdog import DEFAULT_STARTUP_GRACE_SECONDS, ProcessListError, working_descendants

_TAIL_BYTES = 262144
_LOG_REFRESH_SECONDS = 300.0


def pid_alive(pid):
    """The process is alive and not a zombie (a zombie has exited but is not reaped yet)."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    try:
        stat = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True,
                              text=True, check=False, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return True  # without ps a zombie cannot be told apart: it answers signal 0, so treat it as alive
    return bool(stat) and not stat.startswith("Z")


def find_agy_pid(log_path):
    """PID of the agy process that has the stage log open (agy stderr goes there)."""
    try:
        found = subprocess.run(["pgrep", "-x", "agy"], capture_output=True, text=True,
                               check=False, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    target = os.path.realpath(log_path)
    for raw in found.stdout.split():
        paths = open_paths(int(raw)) or []
        if any(os.path.realpath(p) == target for p in paths):
            return int(raw)
    return None


def last_activity_epoch(cli_logs, now):
    """Time of the last activity line in cli-*.log (glog format `I1121 12:17:07.149958`)."""
    best = None
    for path in cli_logs:
        try:
            with open(path, "rb") as handle:
                handle.seek(0, os.SEEK_END)
                size = handle.tell()
                handle.seek(max(0, size - _TAIL_BYTES))
                lines = handle.read().decode("utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in reversed(lines):
            if not ACTIVITY_LINE_RE.search(line) or len(line) < 21 or line[0] not in "IWE":
                continue
            try:
                stamp = datetime.datetime.strptime(f"{now.year}{line[1:5]} {line[6:14]}", "%Y%m%d %H:%M:%S")
            except ValueError:
                continue
            if stamp > now + datetime.timedelta(days=1):
                stamp = stamp.replace(year=now.year - 1)
            epoch = stamp.timestamp()
            best = epoch if best is None else max(best, epoch)
            break
    return best


def mtime(path):
    try:
        return os.path.getmtime(path) if path else None
    except OSError:
        return None


def snapshot(log_path, report, pid, probe, state):
    """Time of the latest evidence of work and the summary for the QUIET line.

    Found agy logs are cached and refreshed periodically so lsof timeouts under load do not cause
    false silence, while rotated logs are still picked up. Last observed activity is preserved
    across polls so an exiting worker descendant does not cause silence to jump abruptly.
    """
    now = time.time()
    evidence = [mtime(log_path), mtime(report), state.get("last_active")]
    cli_logs = [p for p in state.get("cli_logs", []) if os.path.exists(p)]
    checked_at = state.get("cli_logs_checked_at", 0.0)
    if not cli_logs or (now - checked_at) >= _LOG_REFRESH_SECONDS:
        try:
            refreshed = find_agy_logs(pid)
        except ActivityLogError:
            refreshed = []
        if refreshed:
            cli_logs = refreshed
        state["cli_logs"] = cli_logs
        state["cli_logs_checked_at"] = now
    evidence.append(last_activity_epoch(cli_logs, datetime.datetime.now()))
    try:
        workers = working_descendants(pid, DEFAULT_STARTUP_GRACE_SECONDS)
    except ProcessListError:
        workers = []
    if workers:
        evidence.append(now)
    orphan = probe.poll() if probe is not None else False
    last = max((e for e in evidence if e is not None), default=None)
    if last is not None:
        state["last_active"] = last
    line = (last_nonempty_line(log_path, skip_prefixes=("[watchdog]",)) or "")[:160]
    summary = (f"pid={pid} descendants={len(workers)} unclosed_steps_after_interrupt={'yes' if orphan else 'no'}"
               f" agy_log={'found' if cli_logs else 'not found'} last_line: {line}")
    return last, summary


def resolve(args):
    log, report, pid = (Path(args.log) if args.log else None), None, args.pid
    if args.run_dir:
        run_dir = Path(args.run_dir)
        log = log or run_dir / "agent.log"
        report = run_dir / "report.md"
        if pid is None:
            try:
                pid = json.loads((run_dir / "meta.json").read_text(encoding="utf-8")).get("child_pid")
            except (OSError, ValueError):
                pid = None
    if log is None:
        raise ValueError("Pass a run directory or --log")
    return log, report, pid


def main(argv=None):
    sys.stdout.reconfigure(encoding="utf-8", newline="\n", line_buffering=True)
    parser = argparse.ArgumentParser(prog="agent-monitor", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("run_dir", nargs="?", help="run-agent run directory (.tmp/agents/<run>)")
    parser.add_argument("--log", help="Stage log (for pipelines)")
    parser.add_argument("--pid", type=int, help="agy PID (default: from meta.json or by the log)")
    parser.add_argument("--quiet-minutes", type=float, default=30.0)
    parser.add_argument("--interval", type=float, default=60.0)
    args = parser.parse_args(argv)
    try:
        log, report, pid = resolve(args)
    except ValueError as exc:
        parser.error(str(exc))
    quiet = args.quiet_minutes * 60
    started = time.time()
    while pid is None:
        pid = find_agy_pid(log)
        if pid is None:
            if time.time() - started > quiet:
                print(f"NOT FOUND: no agy with the log {log} open within {args.quiet_minutes:g} min")
                return 1
            time.sleep(min(args.interval, 10))
    probe = OrphanStepProbe(pid, baseline=frozenset())
    state = {}
    reported_at = None
    while True:
        if not pid_alive(pid):
            print(f"FINISHED pid={pid}: last log line: {(last_nonempty_line(log) or '')[:160]}")
            return 0
        last, summary = snapshot(log, report, pid, probe, state)
        now = time.time()
        quiet_for = now - (last or started)
        if quiet_for >= quiet and (reported_at is None or now - reported_at >= quiet):
            print(f"QUIET {int(quiet_for // 60)} min: {summary}")
            reported_at = now
        elif quiet_for < quiet:
            reported_at = None
        time.sleep(args.interval)
