#!/usr/bin/env python3
"""Copy an app and embed its complete libmpv dependency graph, without signing."""

import argparse
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
from pathlib import Path


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def dependencies(path):
    return [line.strip().split(" (", 1)[0]
            for line in run("otool", "-arch", "arm64", "-L", path).splitlines()[1:]]


def system_library(name):
    return name.startswith(("/System/Library/", "/usr/lib/"))


def minimum_os(path):
    output = run("xcrun", "vtool", "-arch", "arm64", "-show-build", path)
    match = re.search(r"\bminos\s+([\d.]+)", output)
    if not match:
        raise ValueError(f"Missing macOS build version: {path}")
    return tuple(int(part) for part in match[1].split("."))


def verify(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    frameworks = app / "Contents/Frameworks"
    target = tuple(int(part) for part in info["LSMinimumSystemVersion"].split("."))
    paths = [executable, *sorted(frameworks.glob("*.dylib"))]
    for path in paths:
        if run("lipo", "-archs", path) != "arm64":
            raise ValueError(f"Expected arm64-only binary: {path}")
        if minimum_os(path) > target:
            raise ValueError(f"{path.name} requires a newer macOS than {target}")
        for name in dependencies(path):
            if system_library(name):
                continue
            prefix = "@executable_path/../Frameworks/" if path == executable else "@loader_path/"
            if not name.startswith(prefix) or not (frameworks / name[len(prefix):]).is_file():
                raise ValueError(f"Unresolved or external dependency: {path.name}: {name}")
        load_commands = run("otool", "-arch", "arm64", "-l", path)
        for rpath in re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset", load_commands):
            if rpath.startswith("/") and not system_library(rpath):
                raise ValueError(f"External runtime search path: {path.name}: {rpath}")
    return len(paths) - 1


def bundle(source, libraries, destination):
    if destination.exists():
        raise ValueError(f"Refusing to overwrite {destination}")
    info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    executable = source / "Contents/MacOS" / info["CFBundleExecutable"]
    queue = [name for name in dependencies(executable) if not system_library(name)]
    graph = {}
    while queue:
        name = Path(queue.pop()).name
        if name in graph:
            continue
        path = libraries / name
        if not path.is_file():
            raise ValueError(f"Missing vendored dependency: {name}")
        graph[name] = path.resolve()
        queue.extend(dep for dep in dependencies(path)
                     if not system_library(dep) and Path(dep).name != name)
    if "libmpv.2.dylib" not in graph:
        raise ValueError("Application does not link libmpv.2.dylib")
    shutil.copytree(source, destination, symlinks=True)
    frameworks = destination / "Contents/Frameworks"
    frameworks.mkdir(exist_ok=True)
    manifest = []
    for name, path in sorted(graph.items()):
        output = frameworks / name
        if output.exists():
            raise ValueError(f"Refusing to overwrite existing bundled library: {output}")
        arches = run("lipo", "-archs", path).split()
        if arches == ["arm64"]:
            shutil.copy2(path, output)
        else:
            run("lipo", path, "-thin", "arm64", "-output", output)
        output.chmod(0o755)
        manifest.append({"file": name, "upstreamSHA256": hashlib.sha256(path.read_bytes()).hexdigest()})
    binary = destination / "Contents/MacOS" / info["CFBundleExecutable"]
    for path in [binary, *sorted(frameworks.glob("*.dylib"))]:
        args = []
        if path != binary:
            args += ["-id", "@loader_path/" + path.name]
        for dep in dependencies(path):
            if system_library(dep):
                continue
            prefix = "@executable_path/../Frameworks/" if path == binary else "@loader_path/"
            args += ["-change", dep, prefix + Path(dep).name]
        load_commands = run("otool", "-arch", "arm64", "-l", path)
        for rpath in re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset", load_commands):
            if rpath.startswith("/") and not system_library(rpath):
                args += ["-delete_rpath", rpath]
        if args:
            run("install_name_tool", *args, path)
    (destination / "Contents/Resources/BundledLibraries.json").write_text(
        json.dumps(manifest, indent=2) + "\n")
    count = verify(destination)
    print(f"Bundled and verified {count} libraries in {destination}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--libraries", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if args.verify_only:
        print(f"Verified {verify(args.app)} bundled libraries")
    elif args.libraries and args.output:
        bundle(args.app, args.libraries, args.output)
    else:
        parser.error("--libraries and --output are required when bundling")
