#!/usr/bin/env python3
"""Read Kinrox process footprints without reading arguments or application data.

Uses RUSAGE_INFO_V0, verified against the local macOS SDK sys/resource.h.
The output contains no tokens, track metadata, command arguments, or home paths.
Example: python3 measure-memory.py --pid 45801 --samples 61 --interval 2
"""

import argparse
import ctypes
import datetime
import json
import subprocess
import time


class RUsageInfoV0(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64)
        for name in (
            "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups",
            "pageins", "wired_size", "resident_size", "phys_footprint",
            "proc_start_abstime", "proc_exit_abstime",
        )
    ]


def process_inventory(main_pid):
    output = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,etime=,comm="], text=True
    )
    processes = []
    for line in output.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) != 4:
            continue
        pid, ppid, uptime, path = fields
        processes.append((int(pid), int(ppid), uptime, path))
    main = [item for item in processes if item[0] == main_pid]
    if not main or not main[0][3].endswith("/Kinrox.app/Contents/MacOS/Kinrox"):
        raise RuntimeError("Requested PID is not the expected Kinrox executable")
    soloist_paths = {
        path for _, ppid, _, path in processes
        if ppid == main_pid and "/Kinrox/Engines/Soloist/" in path
        and path.endswith("/soloist")
    }
    selected = []
    for pid, ppid, uptime, path in processes:
        if pid == main_pid:
            role = "Kinrox"
        elif ppid == main_pid and path.endswith("/KinroxSoloistHost"):
            role = "KinroxSoloistHost"
        elif ppid == main_pid and path in soloist_paths:
            role = "Soloist playback"
        elif ppid == 1 and path in soloist_paths:
            role = "Soloist secondary (same executable path)"
        else:
            continue
        selected.append({"pid": pid, "ppid": ppid, "uptime": uptime, "role": role})
    return selected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--samples", type=int, default=61)
    parser.add_argument("--interval", type=float, default=2)
    args = parser.parse_args()
    if args.samples < 1 or args.interval < 0:
        parser.error("samples must be positive and interval must be nonnegative")
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    libproc.proc_pid_rusage.restype = ctypes.c_int
    assert ctypes.sizeof(RUsageInfoV0) == 96
    started = time.monotonic()
    for index in range(args.samples):
        deadline = started + index * args.interval
        time.sleep(max(0, deadline - time.monotonic()))
        record = {
            "timestamp_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "elapsed_seconds": round(time.monotonic() - started, 3),
            "metric": "proc_pid_rusage RUSAGE_INFO_V0; bytes",
            "processes": [],
        }
        for item in process_inventory(args.pid):
            usage = RUsageInfoV0()
            if libproc.proc_pid_rusage(item["pid"], 0, ctypes.byref(usage)) != 0:
                item["error_errno"] = ctypes.get_errno()
            else:
                item.update(
                    physical_footprint_bytes=usage.phys_footprint,
                    resident_size_bytes=usage.resident_size,
                    process_start_abstime=usage.proc_start_abstime,
                )
            record["processes"].append(item)
        record["attributed_footprint_sum_bytes"] = sum(
            item.get("physical_footprint_bytes", 0) for item in record["processes"]
        )
        record["complete"] = not any(
            "error_errno" in item for item in record["processes"]
        )
        print(json.dumps(record, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
