# M1 Verification Report — 2026-10-25

M1 implemented in working tree on `main`, changes uncommitted.
MPVKit resides in `PlayerMac/PlayerMac/MPVKit` with bridging header, approved by owner.

## Implementation

- libmpv 0.41.0 / client API 2.5.0 integrated via `Config/MPV.xcconfig`.
- `MPVPlayer` isolated to MainActor, UI consumes `PlayerEngine`. Commands use `mpv_command_async`.
- Dedicated background thread copies mpv events into `PlaybackEvent: Sendable` prior to subsequent `mpv_wait_event`. Model consumes AsyncStream and throttles position updates to ~10 Hz.
- `CAOpenGLLayer`, OpenGL 3.2 Core, and current CGL context handle rendering.
- Window opens local files via ⌘O / NSOpenPanel; supports launch path arguments.
- Teardown frees render context, terminates event loop thread, and destroys mpv handle safely.

## Results

Environment: Apple Silicon, macOS 26.5.2, Xcode 26.5, Swift 6.3.2.
Three test media samples generated via `bash Scripts/make-test-media.sh` in `DerivedData/M1Media`.

| Verification | Result |
|---|---|
| MP4 / H.264 | Frames, duration, and position progression confirmed |
| MKV / H.264 | Frames, duration, and position progression confirmed |
| MKV / HEVC 10-bit | Frames, duration, and position progression confirmed |
| Hardware decoding | `hwdec-current=videotoolbox` across all three |
| Audio track | `audio-codec-name=aac`, `current-ao=coreaudio` across all three |
| Pause and exact 5s seek | Confirmed via engine events |
| Next file load after pause | New file playback commences smoothly |
| Resize during pause / Retina 2x | Buffer updates dynamically |
| Window close/reopen cycles | No crashes or resource leaks |
| Teardown lifecycle | Safe termination and context cleanup |

All automated unit and playback tests passed (`TEST SUCCEEDED`).
Known limitation: macOS 14 deployment target linker warning due to Homebrew libmpv macOS 26 build.
