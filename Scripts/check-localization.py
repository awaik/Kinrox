#!/usr/bin/env python3
"""Validate localization coverage and format arguments without network access."""
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = {
    "en", "ru", "es", "fr", "de", "pt", "it", "zh-Hans", "zh-Hant", "ja", "ko",
    "ar", "hi", "bn", "ur", "id", "ms", "vi", "th", "tr", "fa", "pl", "uk",
    "nl", "ro", "el", "cs", "sv", "hu", "he",
}
RESOURCE_ROOT = ROOT / "Resources/Localization"


def read(path):
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(path)],
        check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout)


def validate():
    languages = {path.stem for path in RESOURCE_ROOT.glob("*.lproj")}
    assert languages == LANGUAGES, f"Unexpected locales: {languages ^ LANGUAGES}"
    source = read(RESOURCE_ROOT / "en.lproj/Localizable.strings")
    for language in sorted(languages):
        folder = RESOURCE_ROOT / f"{language}.lproj"
        translated = read(folder / "Localizable.strings")
        assert translated.keys() == source.keys(), f"Missing/extra keys: {language}"
        for key, value in translated.items():
            assert isinstance(value, str) and value.strip(), (language, key)
            # Only object arguments are supported; reject stray format directives.
            assert value.count("%@") == key.count("%@"), (language, key)
            assert "%" not in value.replace("%@", ""), (language, key)
        info = read(folder / "InfoPlist.strings")
        assert info.get("NSLocalNetworkUsageDescription", "").strip(), language
    used = set()
    for directory in ["PlayerMac/PlayerMac", "RemoteiOS/RemoteiOS", "Shared"]:
        for path in (ROOT / directory).rglob("*.swift"):
            used.update(re.findall(r'L10n\.(?:text|format)\(\s*"([^"\\]+)"', path.read_text()))
    assert used <= source.keys(), f"Missing source keys: {used - source.keys()}"
    assert not source.keys() - used, f"Unused source keys: {source.keys() - used}"
    print(f"Verified {len(languages)} locales, {len(source)} UI keys, permission prompts, and format arguments.")


if __name__ == "__main__":
    validate()
