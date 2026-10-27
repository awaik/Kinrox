#!/bin/bash
# Captures iPhone remote screenshots for the landing site (site/assets/img/remote/<lang>/).
#
# Uses the Debug simulator build in demo mode (-KinroxDemo -KinroxScreen <screen>).
# Demo-only hints ("Online · demo", "Demo: code …") are replaced in a temporary copy
# of the app bundle with the strings a real connection shows. App sources are untouched.
#
# Requires: a booted iPhone simulator, a Debug-iphonesimulator build of RemoteiOS,
# ImageMagick (magick) and WebP tools (cwebp). The script installs nothing.
#
# Usage: Scripts/capture-landing-screenshots.sh [simulator-udid]
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$PROJECT_ROOT/DerivedData/Build/Products/Debug-iphonesimulator/RemoteiOS.app"
WORK="$PROJECT_ROOT/DerivedData/LandingShots"
OUT="$PROJECT_ROOT/site/assets/img/remote"
BUNDLE_ID="app.kinrox.remote"
LANGUAGES=(en ru)
SCREENS=(players pairing remote recents)

for tool in magick cwebp; do
    command -v "$tool" >/dev/null 2>&1 || { printf '%s is required.\n' "$tool" >&2; exit 1; }
done
[[ -d "$APP" ]] || { printf 'Build RemoteiOS for the simulator first: %s\n' "$APP" >&2; exit 1; }

DEVICE="${1:-$(xcrun simctl list devices booted | grep -Eo '[0-9A-F-]{36}' | head -1)}"
[[ -n "$DEVICE" ]] || { printf 'Boot an iPhone simulator first.\n' >&2; exit 1; }

rm -rf "$WORK" && mkdir -p "$WORK/raw"
cp -R "$APP" "$WORK/RemoteiOS.app"
for lang in "${LANGUAGES[@]}"; do
    strings="$WORK/RemoteiOS.app/$lang.lproj/Localizable.strings"
    online="$(plutil -extract "Online" raw "$strings")"
    plutil -replace "Online · demo" -string "$online" "$strings"
    plutil -replace "Demo: code %@" -string "" "$strings"
done
codesign --force --sign - "$WORK/RemoteiOS.app" >/dev/null 2>&1

xcrun simctl install "$DEVICE" "$WORK/RemoteiOS.app"
xcrun simctl status_bar "$DEVICE" override --time "9:41" --dataNetwork wifi --wifiMode active \
    --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
xcrun simctl ui "$DEVICE" appearance dark

for lang in "${LANGUAGES[@]}"; do
    mkdir -p "$WORK/raw/$lang" "$OUT/$lang"
    for screen in "${SCREENS[@]}"; do
        xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
        xcrun simctl launch "$DEVICE" "$BUNDLE_ID" -KinroxDemo -KinroxScreen "$screen" \
            -AppleLanguages "($lang)" -AppleLocale "${lang}_US" >/dev/null
        sleep 4
        xcrun simctl io "$DEVICE" screenshot --type=png "$WORK/raw/$lang/$screen.png" >/dev/null 2>&1
    done
    # The players list is cropped below the title so the demo badge stays out of frame.
    magick "$WORK/raw/$lang/players.png" -crop 1206x860+0+630 +repage "$WORK/raw/$lang/players-list.png"
    for name in pairing remote recents players-list; do
        magick "$WORK/raw/$lang/$name.png" -resize 780x -strip "$WORK/$lang-$name.png"
        cwebp -quiet -q 86 -m 6 "$WORK/$lang-$name.png" -o "$OUT/$lang/$name.webp"
    done
    printf 'Saved %s screenshots to %s\n' "$lang" "$OUT/$lang"
done

# Put the regular build back so the simulator does not keep the patched copy.
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl status_bar "$DEVICE" clear
