#!/usr/bin/env python3
"""Fetch pinned macOS 11+ arm64 libraries and their source/license material."""

import concurrent.futures
import hashlib
import json
import re
import shutil
import subprocess
import tarfile
import uuid
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "Vendor/iina-1.5.0"
COMMIT = "f86d54276547df6d14104583ea604af67433f1e1"
BASE = "https://github.com/iina/deps-buildscripts"
BINARIES_SHA = "ec7266468a297b907eadbb473c7b3d2992cd274c40d379d8e0e8910caedfae50"
SCRIPTS_SHA = "d48afe266236fea9bcc952de9564ce1ef411020889344c81ea47ce66bc2ee27e"
SOURCE_LOCK = json.loads((ROOT / "Scripts/release-source-lock.json").read_text())
GITHUB_SOURCES = SOURCE_LOCK["sources"]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def download(url, target, expected):
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        temporary = target.with_name(target.name + ".download-" + uuid.uuid4().hex)
        subprocess.run(["curl", "-fsSL", "--retry", "2", "--connect-timeout", "20",
                        "--max-time", "600", url, "-o", str(temporary)], check=True)
        actual = sha256(temporary)
        if actual != expected:
            raise ValueError(f"SHA256 mismatch for {url}: {actual}; preserved {temporary}")
        temporary.rename(target)
    actual = sha256(target)
    if actual != expected:
        raise ValueError(f"Cached file does not match expected SHA256: {target}")
    return actual


def github_sources(repo, ref, label, sources, records):
    # The checked-in lock includes recursive gitlinks. Never resolve mutable tags
    # at build time, and never trust a cached archive's self-reported checksum.
    if SOURCE_LOCK["buildscriptsRevision"] != COMMIT or SOURCE_LOCK["releases"].get(repo) != ref:
        raise ValueError(f"Update the source lock for {repo} {ref}")
    selected = [r for r in GITHUB_SOURCES if r["name"] == label or r["name"].startswith(label + "--")]
    if not any(r["name"] == label for r in selected):
        raise ValueError(f"Missing source lock for {label}")
    for record in selected:
        download(record["url"], sources / record["file"], record["sha256"])
        records.append(record)


def main():
    VENDOR.mkdir(parents=True, exist_ok=True)
    binaries = VENDOR / "iina-deps-arm64.zip"
    download(BASE + "/releases/download/iina-1.5.0-release/iina-deps-arm64.zip",
             binaries, BINARIES_SHA)
    scripts_archive = VENDOR / "buildscripts.tar.gz"
    download("https://api.github.com/repos/iina/deps-buildscripts/tarball/iina-1.5.0-release",
             scripts_archive, SCRIPTS_SHA)
    if not (VENDOR / "lib").exists():
        with zipfile.ZipFile(binaries) as handle:
            for entry in handle.namelist():
                if Path(entry).is_absolute() or ".." in Path(entry).parts:
                    raise ValueError(f"Unsafe archive entry: {entry}")
            handle.extractall(VENDOR / "lib")
    # A verified download is insufficient if a cached extracted dylib was edited.
    with zipfile.ZipFile(binaries) as handle:
        for entry in handle.infolist():
            if not entry.is_dir():
                cached = VENDOR / "lib" / entry.filename
                if not cached.is_file() or cached.read_bytes() != handle.read(entry):
                    raise ValueError(f"Extracted dependency differs from pinned archive: {cached}")
    if not (VENDOR / "buildscripts").exists():
        with tarfile.open(scripts_archive) as handle:
            handle.extractall(VENDOR / "buildscripts", filter="data")
    link = VENDOR / "lib/libmpv.dylib"
    if not link.exists():
        link.symlink_to("libmpv.2.dylib")
    scripts = next((VENDOR / "buildscripts").glob("*/versions.env")).parent
    source_root = VENDOR / "corresponding-source"
    source_root.mkdir(exist_ok=True)
    sources = source_root / "archives"
    sources.mkdir(exist_ok=True)
    if not (source_root / "buildscripts").exists():
        shutil.copytree(scripts, source_root / "buildscripts")
    variables = {}
    for key, value in re.findall(r'^([A-Z0-9_]+)="([^"\n]*)"',
                                 (scripts / "versions.env").read_text(), re.M):
        value = re.sub(r"\$\{([A-Z0-9_]+)\}", lambda m: variables[m[1]], value)
        variables[key] = value
    records = []

    def fetch(item):
        key, url = item
        name = key.removesuffix("_URL")
        archive = sources / (name.lower() + "-" + url.rsplit("/", 1)[1])
        digest = download(url, archive, variables[name + "_SHA256"])
        print(f"Verified source: {name}", flush=True)
        return {"name": name, "url": url, "file": archive.name, "sha256": digest}

    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        for record in pool.map(fetch, [(k, v) for k, v in variables.items() if k.endswith("_URL")]):
            records.append(record)
    github_sources("libjxl/libjxl", "v" + variables["LIBJXL_VERSION"], "libjxl", sources, records)
    # Official GitHub mirror of VideoLAN libplacebo; same release tag and submodules.
    github_sources("haasn/libplacebo", "v" + variables["LIBPLACEBO_VERSION"], "libplacebo", sources, records)
    notices = VENDOR / "licenses"
    notices.mkdir(exist_ok=True)
    for record in records:
        with tarfile.open(sources / record["file"]) as handle:
            for member in handle:
                parts = Path(member.name).parts
                if (not member.isfile() or len(parts) > 3 or member.size > 2_000_000
                        or not re.match(r"^(COPYING|LICENSE|LICENCE|NOTICE|COPYRIGHT)", parts[-1], re.I)):
                    continue
                destination = notices / record["name"] / "/".join(parts[1:])
                destination.parent.mkdir(parents=True, exist_ok=True)
                data = handle.extractfile(member).read()
                if destination.exists() and destination.read_bytes() != data:
                    raise ValueError(f"Existing license differs: {destination}")
                destination.write_bytes(data)
    mpv = next(record for record in records if record["name"] == "MPV")
    includes = VENDOR / "include/mpv"
    includes.mkdir(parents=True, exist_ok=True)
    with tarfile.open(sources / mpv["file"]) as handle:
        for member in handle:
            if member.isfile() and "/include/mpv/" in member.name and member.name.endswith(".h"):
                destination = includes / Path(member.name).name
                data = handle.extractfile(member).read()
                if destination.exists() and destination.read_bytes() != data:
                    raise ValueError(f"Existing header differs: {destination}")
                destination.write_bytes(data)
    manifest = {"upstream": BASE, "revision": COMMIT,
                "binariesSHA256": BINARIES_SHA, "buildscriptsSHA256": SCRIPTS_SHA,
                "sources": sorted(records, key=lambda r: r["name"])}
    (source_root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (source_root / "README.txt").write_text(
        "Corresponding source for Kinrox's bundled libmpv and dependencies.\n"
        f"Upstream build recipes and patches: {BASE}/tree/{COMMIT}\n"
        "Source archives are unmodified and verified; see manifest.json.\n"
        "Use buildscripts/readme.md and versions.env for compiler options and order.\n"
        "Archives named libjxl--... and libplacebo--... are pinned git submodules;\n"
        "extract them into the matching subdirectories before compiling.\n"
        "Test-only libjxl testdata/googletest and disabled skcms are omitted.\n"
        "Kinrox packaging changes only Mach-O load paths and code signatures.\n")
    print(f"Prepared libraries, {len(records)} source archives, and license notices in {VENDOR}")


if __name__ == "__main__":
    main()
