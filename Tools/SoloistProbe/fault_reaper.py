#!/usr/bin/env python3
"""Opt-in reaper-death acceptance; targets only a recorded app's exact owned children."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def output(*arguments):
    result = subprocess.run(arguments, capture_output=True, text=True, check=False)
    return result.stdout.strip() if result.returncode == 0 else None


def identity(pid, resources):
    counters = output(str(resources), str(pid))
    path = output("/bin/ps", "-p", str(pid), "-o", "comm=")
    parent = output("/bin/ps", "-p", str(pid), "-o", "ppid=")
    uid = output("/bin/ps", "-p", str(pid), "-o", "uid=")
    if not counters or not path or not parent or uid != str(os.getuid()):
        return None
    return (path, int(parent), json.loads(counters)["start_ticks"])


def measure(root, resources):
    record = json.loads((root / "app-process.json").read_text())
    parent = record["pid"]
    app = identity(parent, resources)
    if not app or Path(app[0]) != Path(record["binary"]).resolve():
        raise RuntimeError("Recorded app is not running")
    roles = {}
    for value in (output("/usr/bin/pgrep", "-P", str(parent)) or "").split():
        pid = int(value)
        current = identity(pid, resources)
        if current and current[1] == parent:
            name = Path(current[0]).name
            if name in ("soloist", "KinroxSoloistHost"):
                if name in roles:
                    raise RuntimeError("Ambiguous child ownership")
                roles[name] = (pid, current)
    if set(roles) != {"soloist", "KinroxSoloistHost"}:
        raise RuntimeError("Both owned children must be running")
    host, host_identity = roles["KinroxSoloistHost"]
    child, child_identity = roles["soloist"]
    expected_host = Path(record["binary"]).parent.parent / "Helpers/KinroxSoloistHost"
    if Path(host_identity[0]) != expected_host:
        raise RuntimeError("Unexpected helper executable")
    if identity(host, resources) != host_identity or identity(parent, resources) != app:
        raise RuntimeError("Process identity changed")
    began = time.monotonic()
    os.kill(host, signal.SIGKILL)
    retired = False
    while time.monotonic() - began < 1.2:
        if identity(child, resources) != child_identity:
            retired = True
            break
        time.sleep(0.01)
    elapsed = time.monotonic() - began
    result = {"child_stopped": retired, "observed_ms": elapsed * 1000,
              "within_one_second": retired and elapsed <= 1,
              "spotify_present": output("/usr/bin/pgrep", "-x", "Spotify") is not None}
    # A failed regression must not leave an unprotected audio process behind.
    if not retired and identity(child, resources) == child_identity:
        os.kill(child, signal.SIGTERM)
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline and identity(child, resources) == child_identity:
            time.sleep(0.01)
        if identity(child, resources) == child_identity:
            os.kill(child, signal.SIGKILL)
        result["failure_cleanup_performed"] = True
    with (root / "reaper-fault.json").open("x") as handle:
        json.dump(result, handle, indent=2)
    print(json.dumps(result))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("resources", type=Path)
    parser.add_argument("--confirmed-zero-gain", action="store_true")
    args = parser.parse_args()
    if os.environ.get("KINROX_SOLOIST_REAPER_FAULT") != "1" or not args.confirmed_zero_gain:
        parser.error("Requires explicit fault opt-in and current observed Kinrox gain zero")
    os.umask(0o077)
    measure(args.root.resolve(), args.resources.resolve())
