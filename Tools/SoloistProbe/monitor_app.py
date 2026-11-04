#!/usr/bin/env python3
"""Measure a specifically launched Kinrox app and its children without reading argv."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def command(*args):
    return subprocess.run(args, capture_output=True, text=True, check=False)


def measure(root, pid, resources, seconds):
    os.umask(0o077)
    expected = json.loads((root / "app-process.json").read_text())
    if expected["pid"] != pid:
        raise ValueError("The PID must match this run's launch record")
    executable = Path(expected["binary"]).resolve()
    if executable.name != "Kinrox":
        raise ValueError("Expected a Kinrox application executable")
    initial_start = None
    deadline = time.monotonic() + seconds
    with (root / "app-resources.jsonl").open("x") as output:
        while time.monotonic() < deadline and not (root / "monitor-stopped.json").exists():
            current = command("/bin/ps", "-p", str(pid), "-o", "comm=")
            if Path(current.stdout.strip()) != executable:
                break
            sample = command(str(resources), str(pid))
            if sample.returncode:
                break
            app = json.loads(sample.stdout)
            if initial_start is None:
                initial_start = app["start_ticks"]
            if app["start_ticks"] != initial_start:
                break
            phase_path = root / "phase.json"
            phase = json.loads(phase_path.read_text())["phase"] if phase_path.exists() else "idle"
            row = {"unix_seconds": time.time(), "phase": phase, "app": app,
                   "spotify_present": command("/usr/bin/pgrep", "-x", "Spotify").returncode == 0}
            children = command("/usr/bin/pgrep", "-P", str(pid))
            for child in children.stdout.split():
                if not child.isdigit():
                    continue
                name = Path(command("/bin/ps", "-p", child, "-o", "comm=").stdout.strip()).name
                if name not in ("soloist", "KinroxSoloistHost"):
                    continue
                sample = command(str(resources), child)
                if not sample.returncode:
                    row.setdefault(name, []).append(json.loads(sample.stdout))
            output.write(json.dumps(row, sort_keys=True) + "\n")
            output.flush()
            time.sleep(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("pid", type=int)
    parser.add_argument("resources", type=Path)
    parser.add_argument("--seconds", type=int, default=1800)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 3600:
        parser.error("Use a bounded measurement interval of 1–3600 seconds")
    measure(args.root.resolve(), args.pid, args.resources.resolve(), args.seconds)
