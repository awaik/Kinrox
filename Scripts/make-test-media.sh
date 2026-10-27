#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEDIA_DIR="$PROJECT_ROOT/DerivedData/M1Media"
if ! command -v ffmpeg >/dev/null 2>&1; then
    printf 'ffmpeg is required; script does not install dependencies.\n' >&2
    exit 1
fi
mkdir -p "$MEDIA_DIR"

# Synthetic source without downloading video. Do not overwrite existing files.
for name in h264.mp4 h264.mkv hevc.mkv; do
    if [[ -e "$MEDIA_DIR/$name" ]]; then
        printf 'Already exists: %s\n' "$MEDIA_DIR/$name"
        continue
    fi
    codec=(-c:v libx264 -preset ultrafast -pix_fmt yuv420p)
    if [[ "$name" == hevc.mkv ]]; then
        codec=(-c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -x265-params log-level=error)
    fi
    ffmpeg -hide_banner -loglevel error -n \
        -f lavfi -i 'testsrc2=size=640x360:rate=30' \
        -f lavfi -i 'sine=frequency=440:sample_rate=48000' \
        -t 12 "${codec[@]}" -c:a aac -b:a 96k \
        "$MEDIA_DIR/$name"
    printf 'Created %s\n' "$MEDIA_DIR/$name"
done
