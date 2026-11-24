# Source: direct-mcp .agents/lib/agent_activity.py, 2026-11-21 update: stream interruption, agent-monitor (logic unchanged; text translated to English).
"""Stage log reading and agy activity tracking through its open cli-*.log files.

On Linux a process's open files are read through /proc/<pid>/fd,
on macOS (and wherever /proc is unavailable) through `lsof -a -p <pid> -Fn`.
The search matches `*/antigravity-cli/log/cli-*.log` without depending on $HOME.
"""

import fnmatch
import os
import re
import subprocess
from pathlib import Path

ACTIVITY_LINE_RE = re.compile(r"streamGenerateContent|Monitor \S+ FINISHED")
_SKIP_LSOF_FDS = frozenset({"cwd", "rtd", "txt", "mem"})
_MAX_INCOMPLETE_BYTES = 65536


class ActivityLogError(Exception):
    """The agy process's open cli-*.log files could not be found or read."""


def log_signature(log_path):
    """Returns the log's (size, mtime_ns), or None when the file is unavailable."""
    try:
        st = os.stat(log_path)
        return (st.st_size, st.st_mtime_ns)
    except OSError:
        return None


def last_nonempty_line(log_path, chunk_size=65536, skip_prefixes=()):
    """Reads the last non-empty log line from the end of the file without loading it whole."""
    try:
        with open(log_path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            pos = handle.tell()
            if pos == 0:
                return None
            carry = b""
            while pos > 0:
                read_size = min(chunk_size, pos)
                pos -= read_size
                handle.seek(pos)
                data = handle.read(read_size) + carry
                lines = data.splitlines()
                if pos > 0 and lines:
                    carry = lines[0]
                    candidates = lines[1:]
                else:
                    carry = b""
                    candidates = lines
                for raw in reversed(candidates):
                    text = raw.decode("utf-8", errors="replace").strip()
                    if text and not any(text.startswith(prefix) for prefix in skip_prefixes):
                        return text
            if carry:
                text = carry.decode("utf-8", errors="replace").strip()
                if text and not any(text.startswith(prefix) for prefix in skip_prefixes):
                    return text
    except OSError:
        return None
    return None


DONE_MARKER = "РЕЗУЛЬТАТ:"
DONE_MARKERS = ("РЕЗУЛЬТАТ:", "RESULT:")


def report_done_marker(done_file):
    """Returns the matched done marker when the last non-empty report line signals completion."""
    if done_file is None:
        return None
    line = last_nonempty_line(done_file)
    if not line:
        return None
    cleaned = line.lstrip("`* ")
    for marker in DONE_MARKERS:
        if cleaned.startswith(marker):
            return marker
    return None


def report_done(done_file):
    """The agent is done: the last non-empty report line starts with a done marker."""
    return report_done_marker(done_file) is not None


def append_log_line(log_path, line):
    """Appends a line to the end of the log, keeping line breaks intact."""
    try:
        needs_newline = False
        try:
            with open(log_path, "rb") as reader:
                reader.seek(0, os.SEEK_END)
                if reader.tell() > 0:
                    reader.seek(-1, os.SEEK_END)
                    needs_newline = reader.read(1) != b"\n"
        except OSError:
            pass
        prefix = "\n" if needs_newline else ""
        with open(log_path, "ab") as writer:
            writer.write((prefix + line + "\n").encode("utf-8"))
            writer.flush()
    except OSError:
        pass


def is_agy_log_path(path_str):
    """Matches the path pattern */antigravity-cli/log/cli-*.log without depending on $HOME."""
    if not path_str:
        return False
    parts = Path(path_str).parts
    return (
        len(parts) >= 3
        and parts[-3] == "antigravity-cli"
        and parts[-2] == "log"
        and fnmatch.fnmatchcase(parts[-1], "cli-*.log")
    )


def parse_lsof_paths(output):
    """Extracts writable cli-*.log paths from `lsof -a -p <pid> -Fan` (or `-Fn`) output."""
    found = set()
    current_fd = None
    current_access = None
    for line in output.splitlines():
        if not line:
            continue
        tag, value = line[0], line[1:]
        if tag == "f":
            current_fd = value
            current_access = None
        elif tag == "a":
            current_access = value
        elif tag == "n" and current_fd not in _SKIP_LSOF_FDS:
            if current_access is not None and current_access not in ("w", "u"):
                continue
            if is_agy_log_path(value):
                found.add(value)
    return sorted(found)


def _proc_fd_is_writable(pid, fd_name):
    try:
        text = Path(f"/proc/{pid}/fdinfo/{fd_name}").read_text(encoding="utf-8")
    except OSError:
        return True
    for line in text.splitlines():
        if line.startswith("flags:"):
            try:
                flags = int(line.split(":", 1)[1].strip(), 8)
                return (flags & 3) != 0
            except ValueError:
                return True
    return True


def _find_agy_logs_proc(pid):
    proc_fd = Path(f"/proc/{pid}/fd")
    if not proc_fd.is_dir():
        return None
    found = set()
    try:
        with os.scandir(proc_fd) as entries:
            for entry in entries:
                try:
                    target = os.readlink(entry.path)
                except OSError:
                    continue
                if is_agy_log_path(target) and _proc_fd_is_writable(pid, entry.name):
                    found.add(target)
    except OSError:
        return None
    return sorted(found)


def find_agy_logs(pid):
    """Returns the paths of the cli-*.log files that process pid has open for writing."""
    proc_paths = _find_agy_logs_proc(pid)
    if proc_paths is not None:
        if not proc_paths:
            raise ActivityLogError(
                f"no open cli-*.log files of process {pid} found in /proc"
            )
        return proc_paths

    try:
        result = subprocess.run(
            ["lsof", "-a", "-p", str(pid), "-Fan"],
            capture_output=True, text=True, timeout=5, check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise ActivityLogError(f"lsof: {exc}") from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or f"exit code {result.returncode}").strip()
        raise ActivityLogError(f"lsof: {detail}")

    paths = parse_lsof_paths(result.stdout)
    if not paths:
        raise ActivityLogError(f"no open cli-*.log files of process {pid} found")
    return paths


class AgyActivityTracker:
    """Reads what was appended to the open cli-*.log files from saved offsets and looks for activity lines."""

    def __init__(self, pid, finder=None):
        self.pid = pid
        self._finder = finder or find_agy_logs
        self._offsets = {}

    def poll(self):
        """Checks for new activity lines; returns True the first time a file is seen."""
        paths = self._finder(self.pid)
        if not paths:
            raise ActivityLogError(
                f"no open cli-*.log files of process {self.pid} found"
            )

        active = False
        readable = 0
        last_err = None
        for path in paths:
            if path not in self._offsets:
                try:
                    size = os.path.getsize(path)
                except OSError as exc:
                    last_err = exc
                    continue
                self._offsets[path] = size
                readable += 1
                active = True
                continue

            try:
                with open(path, "rb") as handle:
                    handle.seek(0, os.SEEK_END)
                    size = handle.tell()
                    readable += 1
                    offset = self._offsets[path]
                    if size < offset:
                        offset = 0
                    if size > offset:
                        handle.seek(offset)
                        chunk = handle.read(size - offset)
                        last_nl = chunk.rfind(b"\n")
                        if last_nl != -1:
                            complete = chunk[:last_nl + 1]
                            self._offsets[path] = offset + last_nl + 1
                        elif len(chunk) > _MAX_INCOMPLETE_BYTES:
                            complete = chunk
                            self._offsets[path] = offset + len(chunk)
                        else:
                            complete = b""
                            self._offsets[path] = offset
                        if complete and not active:
                            for raw_line in complete.splitlines():
                                text = raw_line.decode("utf-8", errors="replace")
                                if ACTIVITY_LINE_RE.search(text):
                                    active = True
                                    break
            except OSError as exc:
                last_err = exc

        if readable == 0:
            raise ActivityLogError(f"could not read the agy log: {last_err}")

        open_set = set(paths)
        for stale in list(self._offsets):
            if stale not in open_set:
                del self._offsets[stale]
        return active
