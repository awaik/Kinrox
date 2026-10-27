#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v xcodegen >/dev/null 2>&1; then
    printf 'XcodeGen not found. Installation must be performed by the project owner.\n' >&2
    exit 1
fi

xcodegen generate --spec "$PROJECT_ROOT/PlayerMac/project.yml"
xcodegen generate --spec "$PROJECT_ROOT/RemoteiOS/project.yml"
