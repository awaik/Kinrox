# M5 Verification Report — Native iPhone Remote Application

Date: 2026-10-27.
Milestone M5 implemented and ready for review; uncommitted on `main`.
Manual checklist on Mac + physical iPhone confirmed by owner: "Double-checked everything, everything works."

## Implementation

- Standard launch utilizes native Bonjour `_kinrox._tcp`, TransportClient, and secure protocol v1. Single active Mac selection with isolated session generation UUIDs.
- Device discovery lists combine Bonjour broadcast and Keychain saved records by stable serverId.
- PIN entry: 6 digits transmitted automatically; server governs retry limits and timeouts.
- Keychain storage: `app.kinrox.remote.servers`, account serverId, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- Command suite: togglePause, seek forward/back, continuous scrub release, setVolume (10 Hz throttle), next/previous, fullscreen, openRecent.
- Reconnection backoff: 0.5s -> 1s -> 2s -> 4s -> 8s -> 10s with 120s ceiling. Background mode cleanly sends bye frame within 0.25s.
- Isolated demo store mode for testing without a Mac.

## Verifications

- Automated test run on physical iPhone 13 Pro: **43 tests across 8 suites, TEST SUCCEEDED**.
- `PlayerMac` automated tests: 65 tests passed.
- `RemoteProtocol` automated tests: 111 tests passed.
- Local network privacy checks verified against Apple TN3179.

## Connection Recovery Regression — 2026-10-27

Report: the iPhone remote repeatedly loses its connection and requires Retry,
which reconnects immediately. The saved physical-device diagnostic log
`DerivedData/M5/iphone-after-mac-restart.log` records `nonLocalEndpoint` after
successful authentication. Live observation also showed ordinary disconnections
and reconnection attempts to ports that the Mac listener had just abandoned.

Two defects were reproduced with failing regression tests:

- `WebSocketPeer` treated a temporarily unavailable or unresolved network path as
  a nonlocal endpoint. This terminal error disabled automatic recovery. Both
  initial readiness and later path updates now reject unavailable routes with
  retryable `notConnected`; resolved addresses still undergo the local-subnet check.
- `RemoteServer.networkChanged()` restarted its listener and disconnected every
  remote on every network notification. Network.framework manages live listener
  interface changes. Notifications now recreate only a missing listener, leaving
  healthy connections and in-progress pairing intact. Sleep, disable, and explicit
  Retry retain their existing shutdown behavior.

Regression coverage includes missing/unresolved routes, an unavailable route with
a retained address, healthy local path updates, nonlocal-address rejection,
automatic token-based recovery, bounded retries, and continued state delivery
after repeated Mac network notifications.

Verification:

- `swift test --package-path Packages/RemoteProtocol`: 115 tests passed.
- PlayerMac full test suite: 69 tests passed, including real libmpv playback at
  player volume 0 and the new live Bonjour/WebSocket regression.
- RemoteiOS suite on iPhone 17 Simulator: 48 tests passed. The existing two
  physical-device-only integration tests remain skipped on Simulator.
- RemoteiOS suite on physical iPhone 13 Pro: 48 tests passed, including both real
  Bonjour/TransportClient/Keychain integration tests. The first unlocked run
  exposed English-only expectations in three existing tests; these now use the
  localized messages, and the full device run passes with Russian selected.
- Strict Swift formatting checks on changed Swift files and `git diff --check`
  passed. Build products and test result bundles are in
  `DerivedData/ConnectionRecovery`. The iPhone app was updated by the device test
  run. The existing Mac player was left running to preserve its open paused movie;
  the physical Mac-to-iPhone endurance check still needs the new Mac build launched.

## Review Follow-up — 2026-10-27

- Confirmed a remaining recovery gap: `NWPath.status` may still be `satisfied`
  when the local-subnet policy stops permitting an already connected endpoint.
  `WebSocketPeer` now remembers the endpoint approved at initial readiness and
  closes that same endpoint with retryable `notConnected` on policy loss. Initial
  policy rejection and a different rejected endpoint remain `nonLocalEndpoint`.
  Every replacement connection must pass the policy again.
- Added real-loopback regressions with a controllable policy result. Loss of
  approval failed before the fix for both client and server roles, then passed.
  Initial rejection and a changed port on the same host are also covered; the
  tests do not reconfigure system interfaces or claim to reproduce DHCP timing.
- Confirmed incomplete publication cleanup after listener failure. The failed
  state callback now cancels `recentTask` and resets the state publisher, matching
  the existing shutdown cleanup. Transport already closes sessions before this
  callback, so no additional connection teardown was needed.
- The full recursive Swift lint command reproduces 15 pre-existing diagnostics
  in untouched files. Broad formatting was deferred to keep this correction
  scoped; the runbook command remains valid and has not been weakened.

Verification for this follow-up:

- `swift test --package-path Packages/RemoteProtocol`: 118 tests passed.
- PlayerMac build and full test suite: 69 tests passed, including real playback
  at player volume 0, transport lifecycle, and publisher-reset coverage.
- RemoteiOS build and suite on iPhone 17 Simulator: 48 tests reported successful;
  the two physical-device-only integration tests remain skipped.
- Strict Swift lint on all changed Swift files and `git diff --check` passed.
  The existing recursive lint baseline remains as described above.
- App test logs and result bundles: `DerivedData/ReviewFollowup.ajnHhZ/`.
  Physical iPhone endurance and actual interface/DHCP transitions were not rerun.
