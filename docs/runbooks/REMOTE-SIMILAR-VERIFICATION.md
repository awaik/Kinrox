# Remote Similar — Verification

Implemented 2026-11-11 at the owner's request: the iPhone remote starts and stops
Similar on the Mac, and hides tracks or artists with Not interested and Undo.
Design: Figma page `12 · Remote — Similar` (`205:4347`). Released in Mac 0.5.8 (build 18)
and Remote 0.2.2 (build 4) on 2026-11-11 ([Mac 0.5.8 Verification](0.5.8-VERIFICATION.md)).

## Behaviour

- **Listen to similar** starts from the playing track. The current track and manually
  added tracks stay; pending source tracks are replaced by up to 10 similar tracks,
  then the existing refill keeps the queue topped up.
- While the first tracks are being found, the Mac publishes `similar.finding = true`
  and `similar.active = false`; the remote keeps the loading state and source-list
  labels until replacement tracks are committed. If
  nothing playable is found, Similar stays off and the Mac status reads
  "Nothing similar found yet".
- **Stop** keeps the tracks already added and stops adding new ones.
- **Not interested** (track or primary artist) is offered only while Similar runs: on
  the deck menu, as a leading swipe on Similar queue rows, and in their long-press
  menu. The Mac stores the exclusion, removes matching pending source tracks and skips
  a matching current track in one playback operation. If no playable replacement is
  ready, playback stops. Repeated hides still prune and skip; Undo (6 s) removes only
  an exclusion created by that command and does not restore removed queue items.
- An older Mac omits `state.music.similar`; the remote sends nothing and shows
  "Update Kinrox on Mac to use Similar." The new Mac remains compatible with
  Remote 0.2.1, which ignores the field.

## Protocol

Additive v1 (see AGENTS.md §6.3): `RemoteSimilarState` in `MusicState.similar`,
`Command.setSimilar(active:)` and
`Command.setNotInterested(trackId:scope:excluded:)`. Reference fixtures:
`command-setSimilar.json`, `command-setNotInterested.json`, `state-music-similar.json`.

## Automated checks (2026-11-11)

| Command | Result |
|---|---|
| `swift test --package-path Packages/RemoteProtocol` | 130 tests passed, including fixtures and `SimilarProtocolTests` |
| `swift test --package-path Packages/KinroxMusic` | 66 tests passed, including `QueueReplaceSourceTests` |
| PlayerMac `xcodebuild … test` | 359 tests passed, including `RemoteSimilarTests` |
| RemoteiOS `xcodebuild … test` (iPhone 17 simulator) | 67 tests passed (simulator-only skips unchanged), including `SimilarRemoteTests` |
| `xcrun swift-format lint --strict --recursive PlayerMac RemoteiOS Packages Shared` | clean |
| `python3 Scripts/check-localization.py` | 30 locales, 456 keys; one new key |

Demo-mode screenshots (`-KinroxDemo -KinroxScreen music-similar` and
`music-similar-queue`) were checked in English and Russian on the iPhone 17 simulator.

## Not verified

- Real Spotify discovery started from the remote (tests use a discovery provider stub).
- A physical iPhone against a Mac build with this change; no TestFlight upload.

## Review corrections (2026-11-11)

Regression tests reproduced premature active state, an already-hidden current track
continuing to play, Undo removing an older exclusion, and source removal racing with
Next before the fixes. `QueueReplaceSourceTests` also reproduced loss of current and
history context after Repeat All followed by Previous. The focused iPhone suites
(`SimilarRemoteTests`, `LockScreenControllerTests`, `LockScreenRemoteTests`) then passed
18 tests; MusicCore/SpotifyWebAPI passed 67, PlayerMac passed 361, and the full iPhone
simulator suite passed 80 tests. The active Similar demo screen was also inspected.
