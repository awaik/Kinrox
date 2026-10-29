#!/usr/bin/env python3
"""Add an EdDSA-signed Mac release to the Sparkle appcast, without network access.

The result is written next to the release; copy it to site/appcast.xml only after the
DMG is public, so the feed never points to a missing asset."""

import argparse
import email.utils
import html
import re
import subprocess
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urljoin, urlsplit

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPOSITORY = "https://github.com/awaik/Kinrox"
MINIMUM_SYSTEM = "14.0"
ET.register_namespace("sparkle", SPARKLE)


def tag(name):
    return f"{{{SPARKLE}}}{name}"


def signature(sign_update, dmg):
    output = subprocess.check_output([str(sign_update), str(dmg)], text=True)
    match = re.fullmatch(r'\s*sparkle:edSignature="([A-Za-z0-9+/]+=*)" length="(\d+)"\s*', output)
    if not match:
        raise ValueError(f"Unexpected sign_update output: {output!r}")
    if int(match[2]) != dmg.stat().st_size:
        raise ValueError("Signed length differs from the DMG size")
    return match[1], match[2]


def inline_html(text, base_url):
    # Render tokens once: never apply Markdown substitutions to generated HTML or code.
    # Treat code spans atomically inside labels and bold text, too.
    tokens = r"`([^`]+)`|\[((?:`[^`]+`|[^\]`])+)\]\(([^)\s]+)\)|\*\*((?:`[^`]+`|[^`])+?)\*\*"
    parts, end = [], 0
    for match in re.finditer(tokens, text):
        parts.append(html.escape(text[end:match.start()], quote=False))
        code, label, target, bold = match.groups()
        if code is not None:
            parts.append(f"<code>{html.escape(code, quote=False)}</code>")
        elif label is not None:
            url = urljoin(base_url, target)
            parsed = urlsplit(url)
            if parsed.scheme not in ("http", "https") or not parsed.netloc:
                raise ValueError(f"Unsupported release notes link: {target}")
            parts.append(f'<a href="{html.escape(url, quote=True)}">{inline_html(label, base_url)}</a>')
        else:
            parts.append(f"<b>{inline_html(bold, base_url)}</b>")
        end = match.end()
    parts.append(html.escape(text[end:], quote=False))
    return "".join(parts)


def notes_html(markdown, version):
    """Release notes for Sparkle's window: plain-text descriptions lose line breaks."""
    blocks, paragraph, items = [], [], []
    base_url = f"{REPOSITORY}/blob/v{version}/docs/releases/"

    def flush():
        if paragraph:
            blocks.append(f"<p>{inline_html(' '.join(paragraph), base_url)}</p>")
            paragraph.clear()
        if items:
            blocks.append("<ul>" + "".join(f"<li>{inline_html(i, base_url)}</li>" for i in items) + "</ul>")
            items.clear()

    for line in markdown.strip().splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            flush()
            if stripped.startswith("# "):
                continue  # Sparkle already titles the window with the version.
            blocks.append(f"<h3>{inline_html(stripped.lstrip('#').strip(), base_url)}</h3>")
        elif stripped.startswith("- "):
            if paragraph:
                flush()
            items.append(stripped[2:])
        elif not stripped:
            flush()
        elif items:
            items[-1] += " " + stripped  # Wrapped list item.
        else:
            paragraph.append(stripped)
    flush()
    return "\n".join(blocks)


def version_tuple(version):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version or ""):
        raise ValueError(f"Invalid version: {version!r}; expected major.minor.patch")
    return tuple(map(int, version.split(".")))


def build_number(build):
    if not re.fullmatch(r"[1-9][0-9]*", str(build)):
        raise ValueError(f"Invalid build number: {build!r}; expected a positive integer")
    return int(build)


def validate_release(appcast, version, build):
    new_version, new_build = version_tuple(version), build_number(build)
    tree = ET.parse(appcast)
    channel = tree.getroot().find("channel")
    if channel is None:
        raise ValueError("Appcast has no channel")
    for item in channel.findall("item"):
        existing_version = item.findtext(tag("shortVersionString"))
        existing_build = build_number(item.findtext(tag("version")))
        if new_version <= version_tuple(existing_version) or new_build <= existing_build:
            raise ValueError(f"Release must be newer than {existing_version} build {existing_build}")
    return tree


def add_release(appcast, version, build, dmg, edsig, length, notes, date):
    tree = validate_release(appcast, version, build)
    channel = tree.getroot().find("channel")
    if dmg.name != f"Kinrox-{version}-arm64.dmg":
        raise ValueError(f"Unexpected DMG name: {dmg.name}")
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Kinrox {version}"
    ET.SubElement(item, "pubDate").text = email.utils.format_datetime(date)
    ET.SubElement(item, tag("version")).text = str(build)
    ET.SubElement(item, tag("shortVersionString")).text = version
    ET.SubElement(item, tag("minimumSystemVersion")).text = MINIMUM_SYSTEM
    ET.SubElement(item, tag("hardwareRequirements")).text = "arm64"
    ET.SubElement(item, tag("fullReleaseNotesLink")).text = f"{REPOSITORY}/releases/tag/v{version}"
    ET.SubElement(item, "description").text = notes_html(notes, version)
    ET.SubElement(item, "enclosure", {
        "url": f"{REPOSITORY}/releases/download/v{version}/{dmg.name}",
        "length": length, "type": "application/octet-stream", tag("edSignature"): edsig})
    # Newest first: before the previous newest item, or after the channel metadata.
    newest = channel.find("item")
    channel.insert(len(channel) if newest is None else list(channel).index(newest), item)
    ET.indent(tree, space="  ")
    return tree


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", type=Path, required=True)
    parser.add_argument("--check", action="store_true", help="Validate release ordering without signing or writing")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--dmg", type=Path)
    parser.add_argument("--sign-update", type=Path)
    parser.add_argument("--notes", type=Path)
    args = parser.parse_args()
    validate_release(args.appcast, args.version, args.build)
    if args.check:
        print(f"Validated {args.version} build {args.build} against {args.appcast}.")
        return
    if any(value is None for value in (args.output, args.dmg, args.sign_update, args.notes)):
        parser.error("--output, --dmg, --sign-update, and --notes are required unless --check is used")
    if args.output.exists():
        raise SystemExit(f"Refusing to overwrite {args.output}")
    edsig, length = signature(args.sign_update, args.dmg)
    tree = add_release(args.appcast, args.version, args.build, args.dmg, edsig, length,
                       args.notes.read_text(), datetime.now(timezone.utc))
    tree.write(args.output, encoding="utf-8", xml_declaration=True)
    print(f"Wrote {args.output}; publish it to site/appcast.xml after the DMG is public.")


if __name__ == "__main__":
    main()
