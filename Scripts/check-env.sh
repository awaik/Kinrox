#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ANALYTICS=1
missing=0

report() {
    printf '\n%s\n' "$1"
    shift
    "$@" || printf 'Unavailable (nothing installed).\n'
}

for tool in xcodebuild xcrun swift git xcodegen pkg-config; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'Missing required tool: %s\n' "$tool"
        missing=1
    fi
done

if ! pkg-config --exists mpv 2>/dev/null || [[ ! -r /opt/homebrew/include/mpv/client.h ]]; then
    printf 'M1 requires installed libmpv and headers at /opt/homebrew/include/mpv.\n'
    missing=1
fi

report "macOS and architecture:" sw_vers
uname -m

report "Xcode and Developer SDKs:" xcodebuild -version
xcode-select -p

report "Swift:" swift --version
xcrun swift-format --version

report "Homebrew and pkg-config:" brew --version
pkg-config --version

report "mpv (version and libmpv pkg-config):" mpv --version
pkg-config --modversion mpv

report "Available iOS Simulator runtimes (xcrun simctl):" \
    xcrun simctl list runtimes

if [[ "$missing" -ne 0 ]]; then
    printf '\nEnvironment check found missing components. See AGENTS.md.\n' >&2
    exit 1
fi

printf '\nAll required tools are installed.\n'
