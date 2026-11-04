#!/usr/bin/env python3
"""Summarize successful native command observations and retain failures separately."""
import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import statistics


def summarize(root):
    rows = [json.loads(line) for line in (root / "measurements.jsonl").read_text().splitlines()]
    groups = defaultdict(list)
    for row in rows:
        if "confirmed_ms" in row:
            groups[row["operation"]].append(row["confirmed_ms"])
    operations = {}
    for name, samples in groups.items():
        ordered = sorted(samples)
        operations[name] = {"count": len(samples), "p50_ms": statistics.median(samples),
                            "p95_ms": ordered[math.ceil(len(samples) * .95) - 1],
                            "max_ms": max(samples)}
    result = {"complete": any(r.get("stage") == "complete" for r in rows),
              "failures": [r for r in rows if r.get("stage") == "failed"],
              "operations": operations, "p95_method": "nearest rank",
              "limitations": ["Confirmed state, not decoded output latency.",
                              "Volume samples are idempotent zero-gain commands.",
                              "Cold means empty audio cache with stored session; OS caches uncontrolled.",
                              "Development builds and monitoring may run concurrently."]}
    trace = root / "native-trace.jsonl"
    if trace.exists():
        events = [json.loads(line) for line in trace.read_text().splitlines()]
        result["native_starts"] = sum(r.get("operation") == "start" for r in events)
        result["explicit_loads"] = sum(len(groups[name]) for name in ("cold_load", "prime_cache", "warm_load", "next"))
        result["inactive_notifications"] = sum(r.get("active") is False and r.get("event") == "device_changed" for r in events)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.root), indent=2, sort_keys=True))
