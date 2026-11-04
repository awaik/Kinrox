#!/usr/bin/env python3
"""Inspect same-user argv exposure using a fixed invalid key, never a real secret."""

import argparse
import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import time


SENTINEL = "KINROX_NON_SECRET_ARGV_SENTINEL_20261102"
REQUIREMENT = ('anchor apple generic and certificate leaf[subject.OU] = "2FNC3A47ZF" '
               'and identifier "com.spotify.soloist"')


def run(binary, output):
    os.umask(0o077)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R=" + REQUIREMENT,
                    str(binary)], check=True, capture_output=True)
    output.mkdir(parents=True, exist_ok=False)
    data, cache = output / "profile", output / "cache"
    data.mkdir(mode=0o700)
    cache.mkdir(mode=0o700)
    command = [str(binary), "--device-name", "Kinrox Sentinel " + output.name,
               "--api-key", SENTINEL, "--data-dir", str(data), "--cache-dir", str(cache),
               "--cache-size", "200", "--initial-volume", "0", "--ws", "127.0.0.1:0"]
    started = time.monotonic()
    report = {"real_key_used": False, "argv_visible_to_same_user": False,
              "spotify_presence": [], "samples": [], "websocket": None}
    # Invalid-key diagnostic output only; a live-key runner must never use this path.
    with (output / "sentinel-output.txt").open("xb") as log:
        process = subprocess.Popen(command, stdout=log, stderr=log)
        try:
            for _ in range(50):
                elapsed = time.monotonic() - started
                ps = subprocess.run(["/bin/ps", "-ww", "-p", str(process.pid), "-o", "command="],
                                    capture_output=True, text=True, check=False)
                report["argv_visible_to_same_user"] |= SENTINEL in ps.stdout
                present = subprocess.run(["/usr/bin/pgrep", "-x", "Spotify"],
                                         capture_output=True, check=False).returncode == 0
                report["spotify_presence"].append({"seconds": elapsed, "present": present})
                memory = subprocess.run(["/bin/ps", "-p", str(process.pid), "-o", "rss=,pcpu="],
                                        capture_output=True, text=True, check=False)
                report["samples"].append({"seconds": elapsed, "rss_kib_and_cpu_percent": memory.stdout.strip()})
                if report["websocket"] is None and (data / "ws.port").exists():
                    address = (data / "ws.addr").read_text().strip()
                    port = int((data / "ws.port").read_text().strip())
                    if address != "127.0.0.1" or not 1 <= port <= 65535:
                        raise ValueError("Unexpected listener address")
                    listeners = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(process.pid),
                                                "-iTCP:" + str(port), "-sTCP:LISTEN"],
                                               capture_output=True, text=True, check=False)
                    if listeners.returncode or f"127.0.0.1:{port}" not in listeners.stdout:
                        raise ValueError("Endpoint is not owned by the probe child")
                    with socket.create_connection((address, port), timeout=1) as client:
                        nonce = base64.b64encode(os.urandom(16)).decode()
                        client.sendall((f"GET / HTTP/1.1\r\nHost: {address}:{port}\r\n"
                                        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                                        f"Sec-WebSocket-Key: {nonce}\r\nSec-WebSocket-Version: 13\r\n"
                                        "Origin: https://example.invalid\r\n\r\n").encode())
                        response = client.recv(4096)
                    report["websocket"] = {
                        "owned_loopback_listener": True,
                        "untrusted_origin_accepted_without_auth": response.startswith(b"HTTP/1.1 101"),
                    }
                if process.poll() is not None:
                    break
                time.sleep(0.2)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=0.5)
                except subprocess.TimeoutExpired:
                    process.kill()
            report["exit_code"] = process.wait(timeout=2)
            report["elapsed_seconds"] = time.monotonic() - started
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k not in ("samples", "spotify_presence")}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    run(args.binary.resolve(), args.output.resolve())
