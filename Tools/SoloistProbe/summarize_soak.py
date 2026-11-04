#!/usr/bin/env python3
"""Summarize sanitized soak counters without conflating test-host and app cost."""
import argparse
import json
from pathlib import Path
import statistics


def read_lines(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def describe(values):
    if not values:
        return None
    return {"count": len(values), "min": min(values),
            "median": statistics.median(values), "max": max(values)}


def counters(rows, role):
    points = []
    for row in rows:
        value = row.get(role)
        if value:
            points.append((row["unix_seconds"], value))
    seconds = cpu = interrupts = idle = 0
    for (before, a), (after, b) in zip(points, points[1:]):
        if (a["pid"], a["start_ticks"]) != (b["pid"], b["start_ticks"]):
            continue
        elapsed = after - before
        if not 0 < elapsed < 5:
            continue
        seconds += elapsed
        cpu += b["user_ns"] + b["system_ns"] - a["user_ns"] - a["system_ns"]
        interrupts += b["interrupt_wakeups"] - a["interrupt_wakeups"]
        idle += b["platform_idle_wakeups"] - a["platform_idle_wakeups"]
    return {
        "samples": len(points), "counter_interval_seconds": seconds,
        "footprint_mib": describe([v["physical_footprint_bytes"] / 2**20 for _, v in points]),
        "rss_mib": describe([v["resident_bytes"] / 2**20 for _, v in points]),
        "cpu_percent_one_core": cpu / 1e9 / seconds * 100 if seconds else None,
        "interrupt_wakeups_per_second": interrupts / seconds if seconds else None,
        "platform_idle_wakeups_per_second": idle / seconds if seconds else None,
    }


def summarize(root):
    phases = [v for v in read_lines(root / "soak.jsonl") if "stage" in v]
    rows = read_lines(root / "process-sustained.jsonl")
    windows = []
    for phase, following in zip(phases, phases[1:]):
        if phase["stage"] not in ("playing", "paused", "parked"):
            continue
        guard = 5 if phase["stage"] == "playing" else 2
        selected = [r for r in rows
                    if phase["time"] + guard <= r["unix_seconds"] <= following["time"] - guard]
        for r in selected:
            # At most one task-owned reaper is expected. Do not sum shared mappings.
            if len(r.get("reapers", [])) == 1:
                r["reaper"] = r["reapers"][0]
        windows.append({
            "stage": phase["stage"], "occurrence": phase["occurrence"],
            "guard_seconds": guard,
            "soloist": counters(selected, "soloist"),
            "test_host": counters(selected, "test_host"),
            "reaper": counters(selected, "reaper"),
        })
    playing = [w for w in windows if w["stage"] == "playing"]
    medians = [(w["occurrence"], w["soloist"]["footprint_mib"]["median"])
               for w in playing if w["soloist"]["footprint_mib"]]
    after_warmup = [value for occurrence, value in medians if occurrence >= 3]
    result = {
        "complete": any(v["stage"] == "complete" for v in phases),
        "elapsed_seconds": phases[-1]["time"] - phases[0]["time"],
        "distinct_tracks": phases[0]["distinct_tracks"],
        "occurrences": len(playing), "presence_samples": len(rows),
        "spotify_present_samples": sum(r["spotify_present"] for r in rows),
        "playing_footprint_medians_mib": medians,
        "post_warmup_last_vs_first_median_percent":
            (after_warmup[-1] / after_warmup[0] - 1) * 100 if len(after_warmup) > 1 else None,
        "limitations": ["Intentional restarts per occurrence; cache condition is test-specific.",
                        "Release XCTest host, not production Kinrox incremental cost.",
                        "Resource monitoring and development builds were running.",
                        "Counters establish process cost, not decoded audio output."],
        "windows": windows,
    }
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.root), indent=2, sort_keys=True))
