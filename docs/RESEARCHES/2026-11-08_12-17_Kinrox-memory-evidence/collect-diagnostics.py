#!/usr/bin/env python3
"""Collect aggregate diagnostics only; never save allocation contents or memgraphs."""

import datetime
import json
from pathlib import Path
import re
import runpy
import subprocess


ROOT = Path(__file__).resolve().parent
PID = 45801  # The existing long-running instance; do not launch or restart it.


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def sanitize(value):
    return re.sub(r"/Users/[^/\s]+", "/Users/USER", value)


def save(name, value):
    with (ROOT / name).open("x") as output:
        output.write(value)


def capture(command):
    started = now()
    result = subprocess.run(command, text=True, capture_output=True, timeout=240)
    return {
        "command": command,
        "started_utc": started,
        "finished_utc": now(),
        "returncode": result.returncode,
        "stdout": sanitize(result.stdout),
        "stderr": sanitize(result.stderr),
    }


def main():
    inventory = runpy.run_path(str(ROOT / "measure-memory.py"))["process_inventory"](PID)
    manifests = []
    for item in inventory:
        result = capture(["vmmap", "-summary", str(item["pid"])])
        save(f"vmmap-{item['pid']}.txt", result["stdout"] + result["stderr"])
        manifests.append({
            **item, **{key: value for key, value in result.items()
                       if key not in ("stdout", "stderr")},
        })
        print(f"Captured vmmap for {item['role']} ({item['pid']})", flush=True)
    heap = capture(["heap", "-s", str(PID)])
    # Keep exact sizes but abbreviate huge generic type signatures. No object addresses requested.
    lines = heap["stdout"].splitlines()
    save("heap-top.txt", "\n".join(line[:900] for line in lines[:110]) + "\n" + heap["stderr"])
    tokens = (
        "HelpStyleConfiguration", "PopoverPresentationModifier", "NSTrackingArea",
        "DisplayList.ViewUpdater.ViewCache", "MusicCore.Music", "NSImage", "CGImage",
    )
    selected = [line for line in lines if any(token in line for token in tokens)]
    save("heap-selected.txt", "\n".join(line[:1400] for line in selected) + "\n")
    manifests.append({key: value for key, value in heap.items() if key not in ("stdout", "stderr")})
    print("Captured heap aggregates", flush=True)
    leaks = capture(["leaks", "--noContent", "--nostacks", str(PID)])
    save("leaks.txt", leaks["stdout"] + leaks["stderr"])
    manifests.append({key: value for key, value in leaks.items() if key not in ("stdout", "stderr")})
    save("diagnostics-manifest.json", json.dumps(manifests, indent=2) + "\n")
    print("Captured leaks result and diagnostic timestamps", flush=True)


if __name__ == "__main__":
    main()
