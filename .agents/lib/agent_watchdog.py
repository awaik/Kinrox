# Source: direct-mcp .agents/lib/agent_watchdog.py, 2026-11-21 update: stream interruption, agent-monitor (logic unchanged; text translated to English).
"""agy idle watchdog (not a timeout).

Stops the agy process only when all of these hold at once:
1. a signal from agent_hang_signals fired: the "root agent idle" marker in the stage log
   (threshold idle_seconds), a done_file report ending with "РЕЗУЛЬТАТ:", or an unclosed agy
   conversation step after a stream interruption (threshold confirmed_idle_seconds, defaults to
   idle_seconds, 0 disables);
2. agy has no "working" descendants (live zsh/bash/sh shells, or descendants that
   started more than DEFAULT_STARTUP_GRACE_SECONDS after agy);
3. the agy process's open `cli-*.log` files gained no new activity lines
   (`streamGenerateContent` or `Monitor <name> FINISHED`), and at least the threshold of the
   fired signal has passed since the latest evidence (agy activity, a live working descendant,
   a stage log or report file change).
"""

import argparse
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

from agent_activity import (
    ActivityLogError,
    AgyActivityTracker,
    append_log_line,
    last_nonempty_line,  # noqa: F401 - for tests
    log_signature,
)
from agent_hang_signals import (  # noqa: F401 - IDLE_MARKER_RE for tests
    IDLE_MARKER_RE,
    HangSignals,
    orphaned_steps,
)

SHELL_BASENAMES = frozenset({"zsh", "bash", "sh"})
DEFAULT_POLL_INTERVAL = 20.0
DEFAULT_STARTUP_GRACE_SECONDS = 60.0
DEFAULT_KILL_GRACE_SECONDS = 30.0
FORWARD_KILL_GRACE_SECONDS = 3.0
GROUP_CLEANUP_GRACE_SECONDS = 0.5


class ProcessListError(Exception):
    """The process list could not be obtained or parsed through ps."""


class WatchdogInterrupted(Exception):
    """An external SIGINT/SIGTERM delivered to the watchdog itself."""


def parse_etime(text):
    """Parses the ps etime format [[dd-]hh:]mm:ss into whole seconds."""
    value = text.strip()
    days = 0
    if "-" in value:
        day_part, value = value.split("-", 1)
        days = int(day_part)
    parts = [int(part) for part in value.split(":")]
    if len(parts) == 2:
        hours, minutes, seconds = 0, parts[0], parts[1]
    elif len(parts) == 3:
        hours, minutes, seconds = parts
    else:
        raise ValueError(f"unknown etime format: {text!r}")
    if days < 0 or hours < 0 or minutes < 0 or seconds < 0:
        raise ValueError(f"negative etime: {text!r}")
    return days * 86400 + hours * 3600 + minutes * 60 + seconds


def parse_ps_output(output, root_pid=None):
    """Parses `ps -A -o pid=,ppid=,stat=,etime=,comm=` output into pid -> (ppid, stat, etime, comm)."""
    processes = {}
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        parts = line.split(None, 4)
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        if len(parts) != 5:
            if root_pid is not None and pid == root_pid:
                raise ProcessListError(f"unexpected ps line for {root_pid}: {line!r}")
            continue
        try:
            ppid = int(parts[1])
            stat = parts[2]
            etime = parse_etime(parts[3])
            comm = parts[4].strip()
        except ValueError as exc:
            if root_pid is not None and pid == root_pid:
                raise ProcessListError(f"could not parse the ps line for {root_pid}: {exc}") from exc
            continue
        processes[pid] = (ppid, stat, etime, comm)
    if not processes:
        raise ProcessListError("empty ps output")
    return processes


def list_processes(root_pid=None):
    """Returns pid -> (ppid, stat, etime_seconds, comm) through ps (macOS and Linux)."""
    try:
        result = subprocess.run(
            ["ps", "-A", "-o", "pid=,ppid=,stat=,etime=,comm="],
            capture_output=True, text=True, timeout=5, check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise ProcessListError(str(exc)) from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or f"exit code {result.returncode}").strip()
        raise ProcessListError(detail)
    return parse_ps_output(result.stdout, root_pid=root_pid)


def _is_zombie(stat):
    return stat.startswith("Z")


def _is_shell_comm(comm):
    return os.path.basename(comm.strip()).lstrip("-") in SHELL_BASENAMES


def working_descendants(root_pid, startup_grace_seconds, processes=None):
    """PIDs of root_pid's working descendants (excluding zombies and startup services with their subtrees)."""
    if processes is None:
        processes = list_processes(root_pid=root_pid)
    if root_pid not in processes:
        raise ProcessListError(f"process {root_pid} not found in ps output")
    _root_ppid, _root_stat, root_etime, _root_comm = processes[root_pid]
    children_by_ppid = {}
    for pid, entry in processes.items():
        ppid = entry[0]
        if pid != ppid:
            children_by_ppid.setdefault(ppid, []).append(pid)

    working = []
    visited = {root_pid}

    def collect_live_subtree(start_pid):
        stack = [start_pid]
        while stack:
            pid = stack.pop()
            if pid in visited:
                continue
            visited.add(pid)
            _ppid, stat, _etime, _comm = processes[pid]
            if _is_zombie(stat):
                continue
            working.append(pid)
            stack.extend(children_by_ppid.get(pid, ()))

    for child_pid in children_by_ppid.get(root_pid, ()):
        if child_pid in visited:
            continue
        _ppid, stat, etime, comm = processes[child_pid]
        if _is_zombie(stat):
            visited.add(child_pid)
            continue
        if _is_shell_comm(comm) or (root_etime - etime) > startup_grace_seconds:
            collect_live_subtree(child_pid)
        else:
            visited.add(child_pid)
    return working


def _kill_process_group(child, signum):
    if hasattr(os, "killpg"):
        try:
            os.killpg(child.pid, signum)
            return
        except ProcessLookupError:
            return
        except OSError:
            pass
    try:
        child.send_signal(signum)
    except OSError:
        pass


def _process_group_alive(pgid):
    if not hasattr(os, "killpg"):
        return False
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False


def cleanup_process_group(child, grace_seconds=GROUP_CLEANUP_GRACE_SECONDS):
    """After the session leader exits, cleans up survivors in its group: SIGTERM, 0.5 s, SIGKILL."""
    if child is None or not hasattr(os, "killpg"):
        return
    pgid = child.pid
    try:
        os.killpg(pgid, signal.SIGTERM)
    except OSError:
        return
    deadline = time.monotonic() + grace_seconds
    while time.monotonic() < deadline:
        if not _process_group_alive(pgid):
            return
        time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
    if _process_group_alive(pgid):
        try:
            os.killpg(pgid, signal.SIGKILL)
        except OSError:
            pass


def _signal_and_wait(child, signum, grace_seconds, *, fallback_group=False):
    if child is None:
        return
    if child.poll() is None:
        sent = True
        try:
            os.kill(child.pid, signum)
        except ProcessLookupError:
            sent = False
        except OSError:
            if fallback_group:
                _kill_process_group(child, signum)
            else:
                try:
                    child.terminate()
                except OSError:
                    sent = False
        if sent:
            try:
                child.wait(timeout=grace_seconds)
            except subprocess.TimeoutExpired:
                _kill_process_group(child, signal.SIGKILL)
                child.wait()
        elif child.poll() is None:
            child.wait()
    cleanup_process_group(child)


def stop_idle_child(child, kill_grace_seconds=None):
    """SIGTERM to the agy PID only (so it writes its JSON), then cleanup of the remaining group."""
    grace = DEFAULT_KILL_GRACE_SECONDS if kill_grace_seconds is None else kill_grace_seconds
    _signal_and_wait(child, signal.SIGTERM, grace, fallback_group=False)


def _forward_and_wait(child, signum):
    _signal_and_wait(child, signum, FORWARD_KILL_GRACE_SECONDS, fallback_group=True)


def wait_with_watchdog(child, log_path, idle_seconds, *, timeout_seconds=None,
                       poll_interval=None, startup_grace_seconds=None,
                       kill_grace_seconds=None, done_file=None, confirmed_idle_seconds=None,
                       hang_signals=None, orphan_baseline=None):
    """Waits for child to exit while checking the idle watchdog and the overall timeout_seconds.

    Returns (returncode, idle_stopped). Raises subprocess.TimeoutExpired when
    timeout_seconds expires.
    """
    log_path = Path(log_path)
    timeout_seconds = timeout_seconds or None
    if idle_seconds <= 0:
        child.wait(timeout=timeout_seconds)
        return child.returncode, False

    if startup_grace_seconds is None:
        startup_grace_seconds = DEFAULT_STARTUP_GRACE_SECONDS
    if kill_grace_seconds is None:
        kill_grace_seconds = DEFAULT_KILL_GRACE_SECONDS
    if poll_interval is None:
        poll_interval = min(DEFAULT_POLL_INTERVAL, max(0.1, idle_seconds / 4.0))

    started = time.monotonic()
    deadline = (started + timeout_seconds) if timeout_seconds else None
    last_sig = log_signature(log_path)
    last_stage_change_at = started if last_sig is not None else None
    signals = hang_signals or HangSignals(child.pid, log_path, idle_seconds, done_file=done_file,
                                          confirmed_idle_seconds=confirmed_idle_seconds,
                                          orphan_baseline=orphan_baseline)
    done_file = signals.done_file
    last_done_sig = log_signature(done_file) if done_file is not None else None
    last_working_at = None
    last_activity_at = None
    activity_tracker = AgyActivityTracker(child.pid)
    ps_warned = False
    activity_warned = False

    while True:
        wait_for = poll_interval
        if deadline is not None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(child.args, timeout_seconds)
            wait_for = min(wait_for, remaining)
        try:
            rc = child.wait(timeout=wait_for)
            return rc, False
        except subprocess.TimeoutExpired:
            pass

        now_mono = time.monotonic()
        if deadline is not None and now_mono >= deadline:
            raise subprocess.TimeoutExpired(child.args, timeout_seconds)

        sig = log_signature(log_path)
        if sig is None:
            last_sig = None
            last_stage_change_at = None
            continue
        if sig != last_sig:
            last_sig = sig
            last_stage_change_at = now_mono
        elif last_stage_change_at is None:
            last_stage_change_at = now_mono

        if done_file is not None:
            done_sig = log_signature(done_file)
            if done_sig != last_done_sig:
                last_done_sig = done_sig
                last_stage_change_at = now_mono

        signal_hit = signals.check()
        if signal_hit is None:
            continue
        threshold, reason = signal_hit

        try:
            working = working_descendants(child.pid, startup_grace_seconds)
        except ProcessListError as exc:
            if child.poll() is not None:
                return child.returncode, False
            if not ps_warned:
                append_log_line(
                    log_path,
                    f"[watchdog] could not list processes (ps): {exc} - "
                    "the idle watchdog will not stop agy",
                )
                last_sig = log_signature(log_path)
                ps_warned = True
            continue

        if working:
            last_working_at = now_mono

        try:
            had_activity = activity_tracker.poll()
        except ActivityLogError as exc:
            if child.poll() is not None:
                return child.returncode, False
            if not activity_warned:
                append_log_line(
                    log_path,
                    f"[watchdog] could not find the agy activity log: {exc} - "
                    "the idle watchdog will not stop agy",
                )
                last_sig = log_signature(log_path)
                activity_warned = True
            continue

        if had_activity:
            last_activity_at = now_mono

        if working:
            continue

        last_evidence = max(
            t for t in (last_stage_change_at, last_working_at, last_activity_at)
            if t is not None
        )
        idle_elapsed = now_mono - last_evidence
        if idle_elapsed < threshold:
            continue

        if child.poll() is not None:
            return child.returncode, False

        idle_int = int(round(idle_elapsed))
        append_log_line(
            log_path,
            f"[watchdog] agy idle for {idle_int} s after {reason}, "
            "no working background processes - stopped (SIGTERM)",
        )
        stop_idle_child(child, kill_grace_seconds=kill_grace_seconds)
        return child.returncode, True


def _nonnegative(conv):
    def parse(value):
        number = conv(value)
        if number < 0:
            raise argparse.ArgumentTypeError("The value must be >= 0")
        return number
    return parse


def parse_args(argv):
    if "--" not in argv:
        raise ValueError("Usage: agent-watchdog --log <log> --idle-seconds <N> -- <command...>")
    sep = argv.index("--")
    options, cmd = argv[:sep], argv[sep + 1:]
    if not cmd:
        raise ValueError("The agent command must follow --")
    parser = argparse.ArgumentParser(prog="agent-watchdog", description=__doc__)
    parser.add_argument("--log", required=True, help="Path to the stage log")
    parser.add_argument("--idle-seconds", required=True, type=_nonnegative(int),
                        help="Idle threshold in seconds (0 disables the watchdog)")
    parser.add_argument("--done-file", default=None,
                        help="Report file: a last line starting with \"РЕЗУЛЬТАТ:\" means the agent is done")
    parser.add_argument("--confirmed-idle-seconds", type=_nonnegative(int), default=None,
                        help="Threshold after a submitted report or an unclosed conversation step "
                             "(defaults to --idle-seconds, 0 disables)")
    parser.add_argument("--poll-interval", type=_nonnegative(float), default=None,
                        help=argparse.SUPPRESS)
    parser.add_argument("--startup-grace", type=_nonnegative(float), default=None,
                        help=argparse.SUPPRESS)
    parser.add_argument("--kill-grace", type=_nonnegative(float), default=None,
                        help=argparse.SUPPRESS)
    parsed = parser.parse_args(options)
    return parsed, cmd


def _conversation_id_from_cmd(cmd):
    """Extracts the conversation ID from `--conversation <id>` or `--conversation=<id>`."""
    for idx, arg in enumerate(cmd):
        if arg == "--conversation" and idx + 1 < len(cmd):
            return cmd[idx + 1]
        if arg.startswith("--conversation="):
            return arg.split("=", 1)[1]
    return None


def _initial_orphan_baseline(cmd):
    """Empty baseline for fresh sessions; pre-launch snapshot for resumed conversations."""
    conv_id = _conversation_id_from_cmd(cmd)
    if not conv_id:
        return frozenset()
    db_path = Path.home() / ".gemini" / "antigravity-cli" / "conversations" / f"{conv_id}.db"
    pre_existing = orphaned_steps(db_path)
    return None if pre_existing is None else frozenset(pre_existing)


def run_command_watched(cmd, log_path, idle_seconds, *, poll_interval=None,
                        startup_grace_seconds=None, kill_grace_seconds=None,
                        done_file=None, confirmed_idle_seconds=None):
    """Runs the command in a new session, inheriting stdin/stdout/stderr, and watches for idleness."""
    resolved = shutil.which(cmd[0])
    launch_cmd = [resolved, *cmd[1:]] if resolved else list(cmd)
    orphan_baseline = _initial_orphan_baseline(cmd)

    child = None
    old_handlers = {}

    def handle_signal(signum, _frame):
        raise WatchdogInterrupted(signum)

    handled_signals = [signal.SIGINT, signal.SIGTERM]
    if hasattr(signal, "SIGHUP"):
        handled_signals.append(signal.SIGHUP)
    for sig in handled_signals:
        old_handlers[sig] = signal.signal(sig, handle_signal)

    try:
        try:
            child = subprocess.Popen(launch_cmd, start_new_session=True)
        except OSError as exc:
            print(f"Could not start {cmd[0]}: {exc}", file=sys.stderr, flush=True)
            return 127 if isinstance(exc, FileNotFoundError) else 1

        rc, _idle_stopped = wait_with_watchdog(
            child,
            log_path,
            idle_seconds=idle_seconds,
            poll_interval=poll_interval,
            startup_grace_seconds=startup_grace_seconds,
            kill_grace_seconds=kill_grace_seconds,
            done_file=done_file,
            confirmed_idle_seconds=confirmed_idle_seconds,
            orphan_baseline=orphan_baseline,
        )
        return rc if rc >= 0 else 128 - rc
    except WatchdogInterrupted as exc:
        signum = exc.args[0]
        for sig in old_handlers:
            signal.signal(sig, signal.SIG_IGN)
        if child is not None:
            _forward_and_wait(child, signum)
            rc = child.returncode
            if rc is not None:
                return rc if rc >= 0 else 128 - rc
        return 128 + signum
    except BaseException:
        for sig in old_handlers:
            signal.signal(sig, signal.SIG_IGN)
        if child is not None:
            _forward_and_wait(child, signal.SIGTERM)
        raise
    finally:
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)


def main(argv=None):
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    sys.stderr.reconfigure(encoding="utf-8", newline="\n")
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    try:
        args, cmd = parse_args(raw_argv)
    except ValueError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2
    return run_command_watched(
        cmd,
        args.log,
        args.idle_seconds,
        poll_interval=args.poll_interval,
        startup_grace_seconds=args.startup_grace,
        kill_grace_seconds=args.kill_grace,
        done_file=args.done_file,
        confirmed_idle_seconds=args.confirmed_idle_seconds,
    )
