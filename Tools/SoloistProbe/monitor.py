#!/usr/bin/env python3
"""Presence and per-process counters only; never query process command lines."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def sample(root, helper=None, output_name="process-samples.jsonl"):
    os.umask(0o077)
    start = time.monotonic()
    owned_host = None
    helper = helper or root / "resources"
    if Path(output_name).name != output_name:
        raise ValueError("Output name must stay inside the artifact directory")
    with (root / output_name).open("x") as output:
        while time.monotonic() - start < 3600 and not (root / "stopped.json").exists():
            spotify = subprocess.run(["/usr/bin/pgrep", "-x", "Spotify"], capture_output=True).returncode == 0
            row = {"monotonic_seconds": time.monotonic() - start, "unix_seconds": time.time(),
                   "spotify_present": spotify}
            if (root / "ready.json").exists():
                candidates = [root / "ready.json"] + sorted(root.glob("reply-*.json"))
                latest = json.loads(candidates[-1].read_text())
                pid = latest.get("pid")
                if pid:
                    # Check the basename, not argv; this PID belongs to the live task's child.
                    comm = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True)
                    if Path(comm.stdout.strip()).name == "soloist":
                        parent = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "ppid="], capture_output=True, text=True)
                        owned_host = parent.stdout.strip()
                        for role, current in [("soloist", pid), ("test_host", parent.stdout.strip())]:
                            if not str(current).isdigit(): continue
                            result = subprocess.run([str(helper), str(current)], capture_output=True, text=True)
                            if result.returncode == 0:
                                row[role] = json.loads(result.stdout)
            if owned_host and owned_host.isdigit():
                comm = subprocess.run(["/bin/ps", "-p", owned_host, "-o", "comm="], capture_output=True, text=True)
                if Path(comm.stdout.strip()).name == "Kinrox":
                    if "test_host" not in row:
                        result = subprocess.run([str(helper), owned_host], capture_output=True, text=True)
                        if result.returncode == 0:
                            row["test_host"] = json.loads(result.stdout)
                    children = subprocess.run(["/usr/bin/pgrep", "-P", owned_host, "-x", "(reaper|KinroxSoloistHost)"], capture_output=True, text=True)
                    for child in children.stdout.split():
                        if not child.isdigit(): continue
                        result = subprocess.run([str(helper), child], capture_output=True, text=True)
                        if result.returncode == 0:
                            row.setdefault("reapers", []).append(json.loads(result.stdout))
            output.write(json.dumps(row, sort_keys=True) + "\n")
            output.flush()
            time.sleep(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--resources", type=Path)
    parser.add_argument("--output-name", default="process-samples.jsonl")
    args = parser.parse_args()
    sample(args.root.resolve(), args.resources.resolve() if args.resources else None, args.output_name)
