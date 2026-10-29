#!/usr/bin/env python3
"""Catch startup crashes that notarization/static signature checks cannot detect."""

import argparse
import os
import plistlib
import subprocess
import tempfile
import time
from pathlib import Path


def check(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    signature = subprocess.run(["codesign", "-d", "--verbose=2", str(app)],
                               check=True, capture_output=True, text=True).stderr
    if "runtime" not in signature:
        raise ValueError("Startup regression requires Hardened Runtime")
    raw = subprocess.check_output(
        ["codesign", "-d", "--entitlements", ":-", str(app)], stderr=subprocess.DEVNULL)
    entitlements = plistlib.loads(raw) if raw.strip() else {}
    for key in ["allow-jit", "allow-unsigned-executable-memory", "disable-library-validation",
                "disable-executable-page-protection", "get-task-allow"]:
        if entitlements.get("com.apple.security.cs." + key) or entitlements.get("com.apple.security." + key):
            raise ValueError(f"Unexpected release exemption: {key}")
    # Only launch with no media arguments; no test sound or user file is opened.
    # A file avoids filling a pipe while waiting for startup. A loaded dylib and
    # a live process alone also describe an app blocked in its startup-error alert.
    with tempfile.TemporaryFile() as diagnostics:
        check_process(app, binary, diagnostics)


def check_process(app, binary, diagnostics):
    process = subprocess.Popen(
        [str(binary)], stdout=subprocess.DEVNULL, stderr=diagnostics,
        env={**os.environ, "KINROX_RELEASE_SMOKE_TEST": "1"})
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if process.poll() is not None:
                diagnostics.seek(0)
                raise RuntimeError(f"Release exited during startup: {process.returncode}; "
                                   + diagnostics.read().decode(errors="replace"))
            time.sleep(0.1)
        diagnostics.seek(0)
        messages = diagnostics.read().decode(errors="replace")
        if process.poll() is not None:
            raise RuntimeError(f"Release exited during startup: {process.returncode}; {messages}")
        if "KINROX_PLAYER_READY" not in messages.splitlines():
            raise RuntimeError(f"Player initialization did not complete: {messages}")
        loaded = subprocess.check_output(["lsof", "-p", str(process.pid)], text=True)
        if "/opt/homebrew/" in loaded or "/usr/local/Cellar/" in loaded:
            raise RuntimeError("Release loaded a Homebrew dependency")
        if str(app / "Contents/Frameworks/libmpv.2.dylib") not in loaded:
            raise RuntimeError("Bundled libmpv was not loaded")
        sparkle = app / "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
        if sparkle.exists() and str(sparkle) not in loaded:
            raise RuntimeError("Bundled Sparkle was not loaded")
        print("PASS: player initialized with Hardened Runtime, bundled libmpv, and no exemptions")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    check(parser.parse_args().app.resolve())
