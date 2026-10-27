# M3 Verification Report — System Media Keys and "Now Playing"

Date: 2026-10-26. macOS 26.5.2, Xcode/SDK 26.5, Swift 6.3.2, arm64.
Clean working tree on `main`, changes uncommitted.

## Outcome

`SystemNowPlayingCenter` encapsulates MediaPlayer behind a testable protocol.
`NowPlayingController` coordinates with the window view model via AppDelegate.
Publishes video title, folder or "Kinrox", duration, position, playback rate,
media type `.video`, and application logo. Engine events confirm actual state.

Supported commands: play/pause/toggle, next/previous file, seek to absolute position,
and skip by ±10 seconds. Inactive commands disabled; boundary switches disabled at playlist limits.
Without an open media file, handlers return `.noActionableNowPlayingItem`.
Success response indicates command acceptance by mpv event queue.

Position updates synchronize with mpv events rather than UI throttle limits.
Normal playback ticks avoid rewriting the dictionary; metadata updates,
pause/EOF transitions, seek completions, and drifts exceeding 1.5s refresh it.
Short seeks track via `MPV_EVENT_PLAYBACK_RESTART`.

Closing the window tears down metadata, assigns `.stopped`, disables command listeners,
removes own targets, and unobserves the model. Stale callbacks cannot affect a subsequent window.

## Threading and Verified APIs

Reviewed against macOS SDK 26.5 headers:
`MPRemoteCommand.h`, `MPRemoteCommandCenter.h`, `MPNowPlayingInfoCenter.h`, `MPMediaItem.h`.
`playbackState` explicitly set during state transitions.
Command handlers run synchronously on MainActor via `assumeIsolated` or `DispatchQueue.main.sync`.
Artwork loading isolated from MainActor to avoid background crashes.

## Verifications

- All 43 tests across PlayerMac, RemoteProtocol, and RemoteiOS passed (`TEST SUCCEEDED`).
- Player volume muted to 0 during automated playback integration tests; system volume untouched.
- Clean formatting and bounds checks passed.
