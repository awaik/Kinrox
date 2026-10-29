#!/bin/bash
# Build a standalone Developer ID app; retain every intermediate for inspection.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
VERSION="${1:?Usage: build-release.sh VERSION BUILD_NUMBER}"
BUILD_NUMBER="${2:?Usage: build-release.sh VERSION BUILD_NUMBER}"
: "${APPLE_TEAM_ID:?Set the Apple Developer team ID}"
: "${APPLE_SIGNING_IDENTITY:?Set the Developer ID Application certificate SHA-1}"
: "${NOTARYTOOL_PROFILE:?Set the existing notarytool Keychain profile name}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid version" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid build number" >&2; exit 1; }
RELEASE_DIR="$PROJECT_ROOT/dist/$VERSION-build$BUILD_NUMBER"
[[ -f "docs/releases/$VERSION.md" ]] || { echo "Write docs/releases/$VERSION.md first" >&2; exit 1; }
python3 Scripts/update-appcast.py --check --appcast site/appcast.xml \
    --version "$VERSION" --build "$BUILD_NUMBER"
# xcconfig values spell `//` as `/$()/`; remove the empty expansion to get the key.
UPDATE_KEY="$(sed -n 's/^KINROX_UPDATE_PUBLIC_KEY = //p' Config/Updates.xcconfig | sed 's/\$()//g')"
[[ "$UPDATE_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
    echo "Set KINROX_UPDATE_PUBLIC_KEY in Config/Updates.xcconfig (Sparkle generate_keys)" >&2; exit 1; }
[[ ! -e "$RELEASE_DIR" ]] || { echo "Refusing to overwrite $RELEASE_DIR" >&2; exit 1; }
mkdir -p "$RELEASE_DIR"
VENDOR_DIR="$PROJECT_ROOT/Vendor/iina-1.5.0"
python3 Scripts/prepare-release-dependencies.py > "$RELEASE_DIR/dependencies.log" 2>&1
./Scripts/generate.sh
xcrun notarytool history --keychain-profile "$NOTARYTOOL_PROFILE" > "$RELEASE_DIR/notary-preflight.json"

python3 - "$RELEASE_DIR" "$APPLE_TEAM_ID" "$APPLE_SIGNING_IDENTITY" <<'PY'
import plistlib, sys
from pathlib import Path
root = Path(sys.argv[1])
with (root / 'ExportOptions.plist').open('xb') as f:
    plistlib.dump({'method': 'developer-id', 'signingStyle': 'automatic',
                  'teamID': sys.argv[2], 'signingCertificate': sys.argv[3]}, f)
PY

xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$RELEASE_DIR/DerivedData" -archivePath "$RELEASE_DIR/Kinrox.xcarchive" \
    -allowProvisioningUpdates "MARKETING_VERSION=$VERSION" "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" \
    "DEVELOPMENT_TEAM=$APPLE_TEAM_ID" "CODE_SIGN_STYLE=Automatic" \
    "CODE_SIGN_IDENTITY=Apple Development" "PROVISIONING_PROFILE_SPECIFIER=" "PROVISIONING_PROFILE=" \
    "KINROX_MPV_INCLUDE_DIR=$VENDOR_DIR/include" "KINROX_MPV_LIBRARY_DIR=$VENDOR_DIR/lib" \
    archive > "$RELEASE_DIR/archive.log" 2>&1
SPARKLE_TOOLS="$RELEASE_DIR/DerivedData/SourcePackages/artifacts/sparkle/Sparkle"
# The appcast signature must verify against the key shipped in Info.plist.
[[ "$("$SPARKLE_TOOLS/bin/generate_keys" -p)" == "$UPDATE_KEY" ]] || {
    echo "Keychain EdDSA key does not match KINROX_UPDATE_PUBLIC_KEY" >&2; exit 1; }
xcodebuild -exportArchive -archivePath "$RELEASE_DIR/Kinrox.xcarchive" \
    -exportPath "$RELEASE_DIR/export" -exportOptionsPlist "$RELEASE_DIR/ExportOptions.plist" \
    -allowProvisioningUpdates > "$RELEASE_DIR/export.log" 2>&1
# Updates need the owner's EdDSA public key and the HTTPS feed (Config/Updates.xcconfig).
python3 - "$RELEASE_DIR/export/Kinrox.app/Contents/Info.plist" "$UPDATE_KEY" <<'PY'
import plistlib, sys
from urllib.parse import urlparse
info = plistlib.load(open(sys.argv[1], 'rb'))
assert info.get('SUPublicEDKey') == sys.argv[2], 'Info.plist EdDSA key differs from Config/Updates.xcconfig'
assert urlparse(info.get('SUFeedURL', '')).scheme == 'https', 'Update feed must use HTTPS'
assert info.get('SUEnableSystemProfiling') is False, 'System profiling must stay disabled'
PY

mkdir "$RELEASE_DIR/dmg-root"
APP="$RELEASE_DIR/dmg-root/Kinrox.app"
python3 Scripts/bundle-libmpv.py "$RELEASE_DIR/export/Kinrox.app" \
    --libraries "$VENDOR_DIR/lib" --output "$APP"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp -R "$VENDOR_DIR/licenses" "$APP/Contents/Resources/ThirdPartyLicenses"
cp "$VENDOR_DIR/corresponding-source/manifest.json" "$APP/Contents/Resources/DependencySources.json"
sed "s/@KINROX_VERSION@/$VERSION/g" docs/releases/THIRD-PARTY-NOTICES.txt \
    > "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt"
cp "$SPARKLE_TOOLS/LICENSE" "$APP/Contents/Resources/ThirdPartyLicenses/Sparkle-LICENSE.txt"

# Preserve the distribution app identifier and team; all libraries receive the
# same signature, so the development library-validation exemption is unnecessary.
codesign -d --entitlements :- "$RELEASE_DIR/export/Kinrox.app" 2>/dev/null \
    > "$RELEASE_DIR/entitlements.plist"
python3 - "$RELEASE_DIR/entitlements.plist" <<'PY'
import plistlib, sys
from pathlib import Path
p = Path(sys.argv[1])
d = plistlib.loads(p.read_bytes())
d.pop('com.apple.security.cs.disable-library-validation', None)
d.pop('com.apple.security.get-task-allow', None)
p.write_bytes(plistlib.dumps(d))
PY
for library in "$APP"/Contents/Frameworks/*.dylib; do
    codesign --force --sign "$APPLE_SIGNING_IDENTITY" --options runtime --timestamp "$library"
done
# Sparkle's helpers are signed inside-out, as Sparkle documents for manual signing.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$APPLE_SIGNING_IDENTITY" --options runtime --timestamp \
    "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
codesign --force --sign "$APPLE_SIGNING_IDENTITY" --options runtime --timestamp \
    --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
for item in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
    codesign --force --sign "$APPLE_SIGNING_IDENTITY" --options runtime --timestamp "$item"
done
codesign --force --sign "$APPLE_SIGNING_IDENTITY" --options runtime --timestamp \
    --entitlements "$RELEASE_DIR/entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"
python3 Scripts/bundle-libmpv.py "$APP" --verify-only
python3 Scripts/check-release-launch.py "$APP"
ditto -c -k --keepParent "$APP" "$RELEASE_DIR/Kinrox-notarization.zip"
xcrun notarytool submit "$RELEASE_DIR/Kinrox-notarization.zip" \
    --keychain-profile "$NOTARYTOOL_PROFILE" --wait --output-format json > "$RELEASE_DIR/app-notarization.json"
python3 - "$RELEASE_DIR/app-notarization.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'Accepted', d
PY
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ln -s /Applications "$RELEASE_DIR/dmg-root/Applications"
cp docs/releases/INSTALL.txt "$RELEASE_DIR/dmg-root/INSTALL.txt"
DMG="$RELEASE_DIR/Kinrox-$VERSION-arm64.dmg"
hdiutil create -volname "Kinrox $VERSION" -srcfolder "$RELEASE_DIR/dmg-root" \
    -format UDZO -ov "$DMG"
codesign --sign "$APPLE_SIGNING_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait --output-format json > "$RELEASE_DIR/dmg-notarization.json"
python3 - "$RELEASE_DIR/dmg-notarization.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'Accepted', d
PY
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
codesign --verify --strict "$DMG"
hdiutil verify "$DMG"
tar -czf "$RELEASE_DIR/Kinrox-$VERSION-dependency-sources.tar.gz" \
    -C "$VENDOR_DIR" corresponding-source
(cd "$RELEASE_DIR" && shasum -a 256 "Kinrox-$VERSION-arm64.dmg" \
    "Kinrox-$VERSION-dependency-sources.tar.gz" > SHA256SUMS.txt)
# EdDSA-signed appcast entry; sign_update reads the private key from the login Keychain.
python3 Scripts/update-appcast.py --appcast site/appcast.xml --output "$RELEASE_DIR/appcast.xml" \
    --version "$VERSION" --build "$BUILD_NUMBER" --dmg "$DMG" \
    --sign-update "$SPARKLE_TOOLS/bin/sign_update" --notes "docs/releases/$VERSION.md"
echo "Prepared notarized release in $RELEASE_DIR; publication is a separate step."
