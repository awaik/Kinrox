#!/usr/bin/env python3
"""Measure the owned Release harness at zero gain; no keys or track URIs are accepted."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--recoveries", type=int, default=30)
    parser.add_argument("--controls", type=int, default=200)
    parser.add_argument("--park-seconds", type=int, default=70)
    args = parser.parse_args()
    assert 1 <= args.recoveries <= 30 and 0 <= args.controls <= 200
    assert 65 <= args.park_seconds <= 120
    root = args.root.resolve()
    output = root / "recovery-benchmark.jsonl"
    # This runner expects a captured URI and an already suspended native process.
    # Exclusive output creation prevents accidental replay of the same experiment.
    with output.open("x") as stream:
        def record(value):
            stream.write(json.dumps(value, sort_keys=True) + "\n")
            stream.flush()

        def command(operation, *fields):
            result = subprocess.run(
                [sys.executable, str(Path(__file__).with_name("control.py")),
                 str(root), operation, *fields], capture_output=True, text=True, timeout=30)
            if result.returncode:
                record({"operation": operation, "failed": True})
                raise RuntimeError("Probe command failed; inspect its sanitized reply.")
            reply = json.loads(result.stdout)["reply"]
            record({"operation": operation, "reply": reply})
            return reply

        record({"stage": "park", "seconds": args.park_seconds})
        print("Waiting with the owned audio process stopped.", flush=True)
        time.sleep(args.park_seconds)
        for index in range(args.recoveries):
            reply = command("resume_captured")
            if reply["state"]["status"] != "playing" or reply["state"]["volume"] != 0:
                raise RuntimeError("Recovery did not confirm muted playback.")
            command("suspend")
            print(f"Recovery {index + 1}/{args.recoveries} confirmed.", flush=True)
        command("resume_captured")
        record({"stage": "controls", "samples_per_operation": args.controls})
        for index in range(args.controls):
            command("pause")
            command("play")
            command("seek", "--position-ms", str(10_000 if index % 2 else 20_000))
            # Zero is already set: this records idempotent acceptance, not gain-change latency.
            command("set_volume")
            if (index + 1) % 25 == 0:
                print(f"Control cycle {index + 1}/{args.controls} confirmed.", flush=True)
        command("suspend")
        record({"stage": "complete"})
        print("Benchmark complete; native process stopped, harness remains parked.", flush=True)


if __name__ == "__main__":
    main()
