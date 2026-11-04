#!/usr/bin/env python3
"""Thirty-minute, ten-occurrence zero-gain soak using the captured in-memory URI."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    with (root / "soak.jsonl").open("x") as output:
        def record(value):
            value["time"] = time.time()
            output.write(json.dumps(value, sort_keys=True) + "\n")
            output.flush()

        def command(operation):
            result = subprocess.run(
                [sys.executable, str(Path(__file__).with_name("control.py")), str(root), operation],
                capture_output=True, text=True, timeout=30)
            if result.returncode:
                record({"failed": operation})
                raise RuntimeError("Probe command failed; inspect the sanitized reply.")
            record(json.loads(result.stdout))

        record({"stage": "start", "distinct_tracks": 1, "occurrences": 10, "gain": 0})
        for index in range(10):
            command("single_track")
            record({"stage": "playing", "occurrence": index + 1})
            time.sleep(160)
            command("pause")
            record({"stage": "paused", "occurrence": index + 1})
            time.sleep(10)
            command("suspend")
            record({"stage": "parked", "occurrence": index + 1})
            time.sleep(10)
            print(f"Occurrence {index + 1}/10 complete.", flush=True)
        record({"stage": "complete"})
        command("shutdown")


if __name__ == "__main__":
    main()
