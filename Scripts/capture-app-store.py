#!/usr/bin/env python3
"""Capture real localized UI into a fresh directory; never remove existing assets."""
import argparse
import json
import plistlib
import shutil
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--languages", nargs="+")
    parser.add_argument("--app", type=Path, default=ROOT / "DerivedData/AppStoreCapture/Build/Products/Debug-iphonesimulator/RemoteiOS.app")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    app = args.output / "Capture.app"
    shutil.copytree(args.app, app)
    languages = args.languages or ["en", "ru"] + sorted(
        p.stem for p in (ROOT / "Resources/Localization").glob("*.lproj") if p.stem not in {"en", "ru"})
    # Replace demo helper text with the corresponding live UI strings in this
    # disposable copy only. Screens, controls and fictional media remain real UI.
    for lang in languages:
        path = app / f"{lang}.lproj/Localizable.strings"
        data = plistlib.loads(run("plutil", "-convert", "xml1", "-o", "-", str(path)).stdout.encode())
        data["Online · demo"] = data["Online"]
        data["Demo: code %@"] = ""
        path.write_bytes(plistlib.dumps(data))
    run("codesign", "--force", "--sign", "-", str(app))
    bundle = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
    try:
        source_path = str(args.app.resolve().relative_to(ROOT.resolve()))
    except ValueError:
        source_path = args.app.name
    try:
        run("xcrun", "simctl", "install", args.device, str(app))
        run("xcrun", "simctl", "ui", args.device, "appearance", "dark")
        run("xcrun", "simctl", "status_bar", args.device, "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "charged", "--batteryLevel", "100")
        for lang in languages:
            directory = args.output / lang
            directory.mkdir()
            for screen in ["remote", "recents", "pairing"]:
                run("xcrun", "simctl", "terminate", args.device, bundle, check=False)
                run("xcrun", "simctl", "launch", args.device, bundle, "-KinroxDemo", "-KinroxScreen", screen, "-AppleLanguages", f"({lang})", "-AppleLocale", lang)
                time.sleep(3)
                run("xcrun", "simctl", "io", args.device, "screenshot", "--type=png", str(directory / f"{screen}.png"))
            print(f"Captured {lang}", flush=True)
        (args.output / "provenance.json").write_text(json.dumps({"app": source_path, "device": args.device, "languages": languages, "screens": ["remote", "recents", "pairing"], "mode": "Debug demo; only demo helper strings replaced in copied bundle"}, indent=2) + "\n")
    finally:
        try:
            run("xcrun", "simctl", "terminate", args.device, bundle, check=False)
            run("xcrun", "simctl", "install", args.device, str(args.app))
        finally:
            run("xcrun", "simctl", "status_bar", args.device, "clear")


if __name__ == "__main__":
    main()
