# Matrix Screensaver

Implemented 2026-10-29 after owner approval of
[Figma page 07](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox?node-id=63-304).
The approved correction to [exit hint 67:491](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox?node-id=67-491)
is a single three-second appearance per activation. Shipped in Mac 0.3.0 (build 5) on 2026-10-30; companion App Store publication remains separate.

## Behavior

- Mac menu **Screensaver** contains only **Matrix**. It covers the player with
  independent downward green code streams, fading tails, and bright leading glyphs.
  SwiftUI Canvas draws at up to 30 fps while the view exists. The iPhone card uses
  a static preview; the Mac screensaver is animated. Reduce Motion uses a still field.
- A playing movie pauses before Matrix appears. Activation waits for the actual
  mpv pause event, with a five-second error timeout. Starting without media or with
  an already paused movie is immediate.
- The exit hint disappears after three seconds. Mouse movement and repeated menu
  selection do not restore it. Starting a new screensaver session shows it again.
- **Esc** exits Matrix and retains the movie position, pause, and native fullscreen.
  Playback resumes only when the user presses Play. Playback shortcuts and automatic
  next-file playback cannot advance the movie under Matrix. Opening a new file exits
  the screensaver and loads that file normally.
- iPhone **Screensavers** opens the Matrix card, with one start/stop action and a
  movie-pause explanation. Active state includes the paused title and position.
  Turning Matrix off returns to the paused remote. A Mac-initiated start is reflected
  on the remote too. Activation dismisses the ready destination so only the active
  remote screen remains, including Settings and a single Back step to players.
  Controls are disabled during disconnection.

## Integration

- `Shared/Design/MatrixRainView.swift` owns the procedural drawing, using the
  `screensaver/matrix-code` and `screensaver/matrix-head` color tokens.
  Timeline dates are captured by Canvas to invalidate each frame. The timeline
  must not depend on `scenePhase`: the Mac window uses an AppKit `NSHostingView`,
  outside a SwiftUI Scene, and should also keep animating on a second display.
- `PlayerViewModel` owns activation and mpv-confirmed pause; `ScreensaverPresentation`
  owns the cancellable three-second hint. `PlayerWindowController` consumes the first
  plain Esc before AppKit can leave fullscreen. Pairing cards keep priority for Esc;
  starting Matrix dismisses the welcome screen’s Connect iPhone card.
- Protocol v1 adds optional `PlayerState.screensaver` and the `setScreensaver`
  command (`off` / `matrix`). Legacy state encodes exactly as before and decodes
  without the new field. New Mac snapshots always advertise support with a value;
  a missing field disables the new remote controls and explains that Mac needs an update.
- State transitions publish immediately, including inside the position throttle.
  A command acknowledgement never invents active state on the iPhone. Remote starts
  wait for confirmed activation before acknowledgement; failure, cancellation, or
  the five-second timeout returns the existing `internal` protocol error. Other
  incoming commands remain responsive during this wait.
- New user-facing strings are translated in all 30 existing locales. Source keys,
  identifiers, and documentation remain English.

## Automated verification — 2026-10-29

Environment: macOS 26.5.2, Xcode 26.5, Apple Silicon; iPhone 17 simulator on iOS 26.5.

| Check | Result |
|---|---|
| `swift test --package-path Packages/RemoteProtocol` | 120 tests in 21 suites passed |
| Full `PlayerMac` test suite | 130 tests in 27 suites passed |
| Full `RemoteiOS` test suite | 51 tests in 10 suites passed |
| Final `ScreensaverTests` rerun after animation correction | 7 tests passed, including the new real-frame rendering regression |
| Final Mac and iOS Debug builds | Passed |
| `python3 Scripts/check-localization.py` | 30 locales, 263 UI keys |
| Strict Swift formatting lint on screensaver sources and tests | Passed |

Coverage includes legacy JSON byte compatibility, new command/state round trips,
encrypted remote start/stop, pause confirmation and failure, cancellation before
confirmation, blocked EOF advance, no automatic resume, preservation of position and
fullscreen, hint expiration, older Mac capability handling, and demo isolation.
The rendering regression captures two different frames from an AppKit-hosted
window with `scenePhase` set to background, without another state change to trigger
drawing. It honors the host's Reduce Motion setting and does not change it.

The Mac suite uses `DerivedData/MatrixValidation`, because an older loose
`RemoteProtocol.swiftmodule` in the existing default build directory shadowed the
new package framework. Existing artifacts were preserved. The iOS build uses
`DerivedData/MatrixiOS` and the dedicated **Kinrox Matrix QA** simulator
(`D016057C-D2C9-4B23-B69A-946B77EEF1EE`).

```sh
./Scripts/generate.sh
swift test --package-path Packages/RemoteProtocol
xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData/MatrixValidation \
  -clonedSourcePackagesDirPath DerivedData/SourcePackages test
xcodebuild -workspace Kinrox.xcworkspace -scheme RemoteiOS \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=D016057C-D2C9-4B23-B69A-946B77EEF1EE' \
  -derivedDataPath DerivedData/MatrixiOS test
python3 Scripts/check-localization.py
```

## Manual acceptance

1. Set Kinrox playback volume to zero, leaving system volume untouched. Open a
   synthetic test movie; select **Screensaver → Matrix** during playback.
2. Confirm the movie pauses, green streams continue falling after the exit hint
   disappears, and moving the pointer does not bring the hint or player controls back.
3. Press Esc: confirm the same paused position. Repeat in native fullscreen and
   confirm the first Esc exits Matrix while the window remains fullscreen.
4. With no movie, confirm Matrix still starts and Esc returns to the welcome screen.
5. On iPhone, open **Screensavers**, start Matrix, and stop it. Confirm the active
   card and return to the paused film at the same position. Repeat with a Mac-initiated
   start, disconnection/reconnection, and an older Mac that has no screensaver support.

The Russian iPhone entry, ready, active, and returned-paused screens were checked
in the simulator's isolated demo mode. Starting paused the demo at 0:43:00;
stopping retained that position and displayed Play.

On Mac, the native menu contained only Matrix. The animated code changed across
successive captures and continued after the hint disappeared. A synthetic five-minute
movie was playing at zero Kinrox volume before activation; Esc returned to the movie
paused at 0:10. Repeating activation in native fullscreen and pressing Esc retained
both 0:10 and fullscreen. Starting without media and returning to the welcome screen
also passed. System volume was untouched.

## Validation boundaries

- No physical iPhone installation or live phone-to-Mac acceptance run in this task.
  Encrypted transport behavior is covered by automated integration tests; simulator
  UI verification uses demo data.
- No validation on macOS 14/15, iOS 17, a projector, or a second display in this task.
- No release, App Store upload, or distribution change is part of this task.

## Review follow-up — 2026-10-29

- Full Mac suite: 133 tests in 27 suites passed. Remote regressions cover delayed
  acknowledgement, pause failure, timeout, cancellation, file opening, and shutdown.
- Full iOS suite: 53 tests in 10 suites passed, including demo playback guards and
  exiting Matrix when opening a recent movie. Protocol suite: 120 tests passed.
- Manual simulator check: start from Screensavers, confirm Settings on the single
  active screen, Back once to players, reopen, then stop and retain the paused position.
  The activation observer runs on the visible destination because SwiftUI can suspend
  updates to the covered remote view.
- Manual isolated Mac build: Connect iPhone → Screensaver / Matrix closes the card;
  Esc returns to welcome without reopening it. No media was played in this check.
- Pairing-card Esc priority was inspected in code; it was not manually exercised
  with a new physical phone in this follow-up.
