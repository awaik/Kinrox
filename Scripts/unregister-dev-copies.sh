#!/bin/sh
# Removes development, release-staging, and mounted-DMG copies of the Mac player from the
# LaunchServices database, so Finder's "Open With" lists only the installed app.
# Usage: Scripts/unregister-dev-copies.sh [--dry-run] [kept app path, default /Applications/Kinrox.app]
# Copies are not deleted; LaunchServices registers a copy again when it is built or launched.
set -eu

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    shift
fi
KEEP="${1:-/Applications/Kinrox.app}"
while [ "${KEEP%/}" != "$KEEP" ]; do KEEP="${KEEP%/}"; done

# A dump record lists `path:` before `identifier:`; never reuse a previous record's path.
"$LSREGISTER" -dump 2>/dev/null | LC_ALL=C awk '
    /^----------/ { path = ""; next }
    /^path:/ { sub(/^path:[ \t]*/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0; next }
    /^identifier:[ \t]*app\.kinrox\.player$/ && path != "" { print path }
' | sort -u | while IFS= read -r app; do
    [ "$app" = "$KEEP" ] && continue
    echo "Unregistering $app"
    [ "$DRY_RUN" -eq 1 ] || "$LSREGISTER" -u "$app" 2>/dev/null || true
done
