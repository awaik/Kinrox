#!/usr/bin/env python3
"""Submit one secret-free command to the task-owned native live harness."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import time
import uuid

OPERATIONS = ["snapshot", "capture_track", "play_captured", "play", "pause", "seek",
              "set_volume", "set_shuffle", "set_repeat_track", "set_repeat_context",
              "activate", "deactivate", "restart", "single_track", "suspend", "resume_captured",
              "bind_account", "audition", "shutdown"]


def run(args):
    os.umask(0o077)
    root = args.root.resolve()
    if not (root / "ready.json").exists() or (root / "stopped.json").exists():
        raise SystemExit("The probe is not running in this control directory.")
    with (root / "controller.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        indices = [int(match[1]) for path in root.iterdir()
                   if (match := re.fullmatch(r"command-(\d{4})\.json", path.name))]
        last = max(indices, default=0)
        if last and not (root / f"reply-{last:04d}.json").exists():
            raise SystemExit("The previous command has not settled; preserved all commands.")
        index = last + 1
        if index > 9999:
            raise SystemExit("Command limit reached.")
        command = {"operation": args.operation}
        if args.operation in ("capture_track", "play_captured"):
            command["slot"] = args.slot
        if args.operation == "seek":
            if args.position_ms is None or not 0 <= args.position_ms <= 86_400_000:
                raise SystemExit("Seek requires a bounded --position-ms value.")
            command["fields"] = {"position_ms": args.position_ms}
        if args.operation == "set_volume":
            command["fields"] = {"volume": 0}
        if args.operation in ("set_shuffle", "set_repeat_track", "set_repeat_context"):
            if args.enabled is None:
                raise SystemExit("This command requires --enabled true/false.")
            command["fields"] = {"enabled": args.enabled == "true"}
        # Publish a complete request atomically without replacing an existing command.
        # Retain the staging file as an artifact; no request history is deleted.
        staging = root / ("request-" + uuid.uuid4().hex + ".json")
        with staging.open("x") as stream:
            json.dump(command, stream)
        os.link(staging, root / f"command-{index:04d}.json")
        response = root / ("stopped.json" if args.operation == "shutdown"
                           else f"reply-{index:04d}.json")
        deadline = time.monotonic() + 25
        while not response.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        if not response.exists():
            raise SystemExit("Observation timed out; do not resubmit before reconciliation.")
        result = json.loads(response.read_text())
        print(json.dumps({"index": index, "operation": args.operation, "reply": result}))
        return 0 if result.get("success", result.get("stopped", False)) else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("operation", choices=OPERATIONS)
    parser.add_argument("--position-ms", type=int)
    parser.add_argument("--slot", type=int, choices=[0, 1], default=0)
    parser.add_argument("--enabled", choices=["true", "false"])
    raise SystemExit(run(parser.parse_args()))
