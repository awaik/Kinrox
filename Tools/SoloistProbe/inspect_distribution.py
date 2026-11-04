#!/usr/bin/env python3
"""Download and inspect Soloist without executing it or accessing credentials.

Use a fresh ignored build/ directory. The distribution must never be committed,
bundled, uploaded as a CI artifact, or redistributed.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import urllib.parse
import urllib.request


DOWNLOAD = "https://soloist-builds.spotifycdn.com/soloist_release_osx_arm64.tar.gz"
MAX_BYTES = 256 * 1024 * 1024
MAX_ENTRIES = 1000


def check_url(url):
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != "https" or parsed.hostname != "soloist-builds.spotifycdn.com"
            or parsed.username or parsed.password or parsed.port not in (None, 443)):
        raise ValueError("Unreviewed download origin")


class RestrictedRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        check_url(new_url)
        return super().redirect_request(request, response, code, message, headers, new_url)


def validated_members(archive):
    members = []
    total = 0
    paths = set()
    for member in archive:
        if len(members) >= MAX_ENTRIES:
            raise ValueError("Too many archive entries")
        members.append(member)
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or "\\" in member.name:
            raise ValueError("Unsafe archive path")
        if not (member.isfile() or member.isdir()):
            raise ValueError("Links and special entries are not permitted")
        if path in paths:
            raise ValueError("Duplicate archive entry")
        paths.add(path)
        total += member.size
        if member.size < 0 or total > MAX_BYTES:
            raise ValueError("Archive expansion limit exceeded")
    executables = [m for m in members if m.isfile() and PurePosixPath(m.name).name == "soloist"]
    if len(executables) != 1:
        raise ValueError("Expected exactly one Soloist binary")
    return members, executables[0]


def inspect(destination):
    os.umask(0o077)
    destination.mkdir(parents=True, exist_ok=False)
    archive_path = destination / "distribution.tar.gz"
    opener = urllib.request.build_opener(RestrictedRedirect())
    check_url(DOWNLOAD)
    digest = hashlib.sha256()
    count = 0
    with opener.open(DOWNLOAD, timeout=30) as response, archive_path.open("xb") as output:
        check_url(response.url)
        while chunk := response.read(1024 * 1024):
            count += len(chunk)
            if count > MAX_BYTES:
                raise ValueError("Download limit exceeded")
            digest.update(chunk)
            output.write(chunk)
    with tarfile.open(archive_path, "r:gz") as archive:
        members, executable = validated_members(archive)
        # Only extract the inspected binary, with no executable permission yet.
        binary = destination / "soloist"
        with archive.extractfile(executable) as source, binary.open("xb") as target:
            while chunk := source.read(1024 * 1024):
                target.write(chunk)
        entries = [{"name": m.name, "size": m.size} for m in members]
    report = {
        "url": DOWNLOAD, "archive_bytes": count, "archive_sha256": digest.hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "binary_bytes": binary.stat().st_size, "entries": entries,
        "executed": False, "checks": {},
    }
    checks = {
        "file": ["/usr/bin/file", str(binary)],
        "architecture": ["/usr/bin/lipo", "-archs", str(binary)],
        "load_commands": ["/usr/bin/otool", "-l", str(binary)],
        "dependencies": ["/usr/bin/otool", "-L", str(binary)],
        "signature": ["/usr/bin/codesign", "-dvvv", str(binary)],
        "signature_check": ["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(binary)],
        "gatekeeper": ["/usr/sbin/spctl", "-a", "-vv", "-t", "exec", str(binary)],
    }
    for name, command in checks.items():
        result = subprocess.run(command, text=True, capture_output=True, timeout=60, check=False)
        report["checks"][name] = {"status": result.returncode, "output": result.stdout + result.stderr}
    (destination / "inspection.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "checks"}, indent=2))
    print("Inspection saved; no executable has been run.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    inspect(parser.parse_args().destination.resolve())
