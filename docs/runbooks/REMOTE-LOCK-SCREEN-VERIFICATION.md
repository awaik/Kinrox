# Remote Lock Screen — Verification

Implemented 2026-11-11 at the owner's request: the iPhone remote shows a Live Activity on
the Lock Screen and in the Dynamic Island with Mac controls. Design: Figma page
`13 · Remote — Lock Screen` (`212:304`). Released in Remote 0.2.2 (build 4) with Mac 0.5.8
on 2026-11-11 ([Mac 0.5.8 Verification](0.5.8-VERIFICATION.md)). No Mac or protocol changes
are required.

## Why a Live Activity

iOS shows the system Now Playing widget only for an app that plays audio itself. The
remote plays no audio, and keeping silent audio running to get the widget would break App
Review rules, drain the battery and interrupt other apps' audio. A Live Activity with
interactive buttons (iOS 17) is the supported route.

## Behaviour

- The card appears while the remote is connected and the Mac has media; it updates from
  confirmed state only. Music: volume −, previous, play/pause, next, volume +. Video:
  volume −, −10 s, play/pause, +10 s, volume +. Volume steps by 5 (Kinrox volume on the Mac).
- A button press runs `LockScreenControlIntent` in the app process, even after the app
  was terminated. The remote reconnects with the stored token (up to 6 s), sends the
  command, waits up to 1.5 s for the new state, refreshes the card, keeps the connection
  10 s for repeated presses and then sends `bye`. The pressed button shows a ring until then.
- No socket stays open in the background, so a change made on the Mac appears after the next
  press or when the remote opens. The progress bar and times run on system timers. After
  the expected end of a track, the card dims and shows the next track with
  "Updates when you tap".
- If the Mac cannot be reached, the card shows "Mac unavailable · Open Kinrox Remote" with
  disabled buttons.
- The card ends when media closes, the Mac is forgotten or deselected, demo mode is toggled,
  or Settings → "Lock Screen controls" is turned off. A card left paused in the background
  dismisses itself one hour after the pause started (owner decision); iOS ends any Live
  Activity after 8 hours. To arrange removal without running background code later,
  the paused card uses ActivityKit's end-with-delayed-dismissal policy: it remains on
  the Lock Screen, while the Dynamic Island presentation ends immediately. A later
  press can create a replacement card; foreground removal also removes retained ended cards.
- The protocol carries no artwork, so the tile shows a music or video glyph.

## Automated checks (2026-11-11)

| Command | Result |
|---|---|
| RemoteiOS `xcodebuild … test` (iPhone 17 simulator) | 75 tests passed (simulator-only skips unchanged), including `LockScreenControllerTests` and `LockScreenRemoteTests` |
| `xcrun swift-format lint --strict --recursive PlayerMac RemoteiOS Packages Shared` | clean |
| `python3 Scripts/check-localization.py` | 30 locales, 463 keys; seven new keys; the checker now also scans the widget sources |

The tests cover card content for music and video, update de-duplication, the one-hour pause
limit, the sending and unavailable states, the setting, and a background press that
reconnects, sends `togglePause`, refreshes the card and disconnects after 10 s.

Demo mode on the iPhone 17 simulator (iOS 26.5, Russian): the compact Dynamic Island and
the Lock Screen card render as designed. On the locked simulator the system hides seconds in
timers ("42:--").

## Physical iPhone (2026-11-11)

Debug build on iPhone 13 Pro (no Dynamic Island) against Mac Kinrox 0.5.7: the card
appears on the Lock Screen and its buttons (volume, track change, play/pause) control the
Mac; owner confirmed "работает".

The first device build showed the card, but buttons did nothing: `Config/Shared.xcconfig`
set `LM_SKIP_METADATA_EXTRACTION = YES` (from M0), so the app had no
`Metadata.appintents` and iOS ran the intent in the extension, where no handler exists.
`RemoteiOS/project.yml` now turns extraction on for the app and the extension. Check
after a build that both `RemoteiOS.app/Metadata.appintents` and
`PlugIns/RemoteLockScreen.appex/Metadata.appintents` exist; an incremental build can leave
a stale embedded extension, so use `clean build` when in doubt.

## Not verified

- A press after iOS terminated the remote, the unavailable state, the Settings switch and
  the one-hour pause limit on the device; whether buttons of a paused card that already
  ended still run the command.
- Dynamic Island on a device (the test iPhone has none).
- No TestFlight upload. Automatic signing created the extension's App ID
  (`app.kinrox.remote.lockscreen`) on the first device build.

## Review corrections (2026-11-11)

The presenter now retains delayed-dismissal handles, removes all retained cards on
immediate dismissal, restores active/stale/ended content on process launch, and treats
stale activities as updatable. The controller restores the original pause timestamp,
including across later paused updates and process restarts. Sending/unreachable
feedback can recreate an ended card. The root scene starts the normal network lifecycle
only outside the background; a background intent owns its bounded session.

Overlapping button requests retain the sending indicator until the final request
finishes. Volume steps accumulate from the pending target and reset on confirmation or
session completion. The card and expanded Dynamic Island share unavailable/stale text.

Before the fixes, regression tests failed for cold content restoration, feedback after
delayed ending, rapid volume increments, and premature Similar state. All 18 focused
remote tests passed afterwards, including cold background session expiry and restoration
of the original pause deadline. The full RemoteiOS suite passed 80 tests in 15 suites.
The active Similar screen and music Lock Screen card were inspected in demo mode on the
iPhone 17 simulator (iOS 26.5, English); the initial system Live Activities consent prompt
was left unchanged. Real ActivityKit removal and button delivery after process termination
or delayed ending still need physical-device verification.

Apple documents [starting a Live Activity from a LiveActivityIntent](https://developer.apple.com/documentation/AppIntents/LiveActivityIntent)
and [immediate or delayed dismissal of an ended card](https://developer.apple.com/documentation/activitykit/activityuidismissalpolicy).
