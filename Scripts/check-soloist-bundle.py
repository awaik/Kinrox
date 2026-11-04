#!/usr/bin/env python3
"""Kinrox may bundle its own reaper; the Spotify executable/archive must stay external."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tarfile

POLICY = json.loads(Path(__file__).with_name("soloist-policy.json").read_text())
SPOTIFY_IDENTITIES = {artifact[key] for artifact in POLICY["testedArtifacts"]
                      for key in ("archiveSHA256", "binarySHA256")}
MACHO = {bytes.fromhex(x) for x in ("cffaedfe", "feedfacf", "cafebabe", "bebafeca")}


def verify_host_signature(app, helper):
    def identity(path):
        result = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=2", str(path)],
                                capture_output=True, text=True, timeout=10)
        if result.returncode:
            raise ValueError("A Kinrox signing identity is missing.")
        return dict(line.split("=", 1) for line in result.stderr.splitlines() if "=" in line)

    parent, child = identity(app), identity(helper)
    team = parent.get("TeamIdentifier", "")
    if (not re.fullmatch(r"[A-Z0-9]{10}", team)
            or child.get("TeamIdentifier") != team
            or child.get("Identifier") != "app.kinrox.soloist-host"):
        raise ValueError("The Kinrox reaper has an unexpected signing identity.")
    result = subprocess.run(["/usr/bin/codesign", "--verify", "--strict",
                             f'-R=anchor apple generic and certificate leaf[subject.OU] = "{team}" '
                             'and identifier "app.kinrox.soloist-host"', str(helper)],
                            capture_output=True, timeout=10)
    if result.returncode:
        raise ValueError("The Kinrox reaper signature is invalid.")


def verify(app):
    helper = app / "Contents/Helpers/KinroxSoloistHost"
    if not helper.is_file() or helper.is_symlink():
        raise ValueError("The Kinrox-owned reaper is missing.")
    verify_host_signature(app, helper)
    for file in app.rglob("*"):
        if file.is_symlink() or not file.is_file():
            continue
        digest = hashlib.sha256()
        with file.open("rb") as stream:
            first = stream.read(4)
            digest.update(first)
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
        if digest.hexdigest() in SPOTIFY_IDENTITIES:
            raise ValueError("A Spotify distribution artifact is present in the app.")
        if first in MACHO:
            signature = subprocess.run(
                ["/usr/bin/codesign", "-d", "--verbose=2", str(file)],
                capture_output=True, text=True, timeout=10)
            if "Identifier=" + POLICY["identifier"] in signature.stderr.splitlines():
                raise ValueError("A Spotify executable is present in the app.")
        if first[:2] == b"\x1f\x8b":
            # The official Soloist archive remains forbidden even after a rolling update.
            try:
                with tarfile.open(file, "r:gz") as archive:
                    total = 0
                    for index, member in enumerate(archive):
                        total += member.size
                        if index >= 1000 or total > 64 * 1024 * 1024:
                            raise ValueError("A bundled archive exceeds the inspection bound.")
                        if Path(member.name).name == "soloist":
                            raise ValueError("A Spotify archive is present in the app.")
            except tarfile.ReadError:
                pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    verify(args.app.resolve())
    print("Kinrox-owned helper present; no Spotify distribution artifact bundled.")
