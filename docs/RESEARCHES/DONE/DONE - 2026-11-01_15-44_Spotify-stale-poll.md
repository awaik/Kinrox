# Spotify playback: stale polling response after a command

Status: implemented locally; 183 Mac tests passed. Not published.

## Report and live evidence

The owner reported that the production Mac app connects to Spotify but plays
only one song, and that trying different controls does not recover playback.
Expected behavior is that starting an album or Play All plays the selected queue
and keeps the current song, controls and subsequent track changes synchronized.

The installed 0.4.0 app displayed an old song and an outside-Kinrox playback error.
A subsequent Play All attempt displayed the unavailable error instead of starting
the selected queue. The installed binary did not provide enough diagnostics to
identify the exact request or ordering that caused that live failure.

Temporary local diagnostics in fresh Debug and optimized Release builds showed
successful album playback, manual Next, automatic advancement and a multi-page
Liked Songs queue. Thus the live failure was not reproduced consistently. The
race below is proven independently; it is not proof that every observed failure
has this single cause. Diagnostic code has been removed from the final sources.

## Confirmed cause and reproduction

Defect class: asynchronous stale-response race in Spotify Connect state polling.

`SpotifyConnectMusicEngine+State.swift` checked only `isCommandRunning` before
and after awaiting a background playback request. A complete command can start
and finish while that old request remains in flight, making the flag false again.

1. Hold an in-flight poll for the previous playlist context.
2. Complete `SpotifyConnectMusicEngine.play` for a new queue, including observed
   confirmation that the selected context is playing.
3. Release the earlier poll with either the old context or HTTP 503.
4. The original engine emits an outside-Kinrox or unavailable failure and sets
   `polling` to nil. `play` already called `beginPolling` while that old task
   existed, so no replacement remains to observe track changes.

This can freeze Kinrox's displayed song/state. It does not by itself prove that
Spotify's audio stops after one song.

## Correction

Every playback command now advances a generation counter. Polling captures the
generation before sending its request and validates it on both success and
failure. Results superseded by a command are ignored, and the polling task stays
alive for the new queue. The existing in-progress and shutdown checks remain.

Files:

- `PlayerMac/PlayerMac/Music/Spotify/SpotifyConnectMusicEngine.swift`
- `PlayerMac/PlayerMac/Music/Spotify/SpotifyConnectMusicEngine+State.swift`
- `PlayerMac/PlayerMacTests/SpotifyConnectTests.swift`

Restarting polling for every command was considered unnecessary: a generation
check directly protects the asynchronous boundary without introducing task
replacement races. Current authentication, context and API failures still stop
polling and require user action; no ownership/privacy checks or retries change.

## Regression and verification

`completedPlayDiscardsEarlierPollResults` uses the real engine/client with gated
HTTP fixtures. Both the stale-context response and stale HTTP 503 failed before
the correction: polling became nil, no next request was sent, and a failure event
was emitted. The initial method-level Xcode test filter selected zero tests;
the subsequent whole `SpotifyLibraryTests` suite produced the valid red result.

After the fix, 28 tests across Spotify library, follow-up, playback and music
review suites passed. The regression was then extended to verify that a fresh
poll observes the second track's occurrence. `currentPollFailureStillStopsPolling`
also checks that a current outside-context response or HTTP 503 is still reported.

- Red: `/tmp/kinrox-spotify-poll-red2.log` (exit 65, six assertions across two cases).
- Initial green: `/tmp/kinrox-spotify-poll-green.log` (28 tests passed).
- Full Mac suite: `/tmp/kinrox-spotify-poll-full.log` (183 tests in 40 suites passed).
- Release build: `/tmp/kinrox-spotify-poll-release.log` (passed).
- Strict swift-format lint on all three changed Swift files: passed.
- `git diff --check`: passed.

Acceptance: stale results cannot stop observation of a successful new queue;
the second occurrence becomes current; genuine current errors remain visible.
All three acceptance checks passed. The full suite used `xcodebuild -workspace
Kinrox.xcworkspace -scheme PlayerMac -configuration Debug -destination
'platform=macOS,arch=arm64' -derivedDataPath DerivedData/SpotifyBug.FAWveN test`.
The optimized build used the same workspace/scheme/destination with
`-configuration Release`, a separate derived-data directory, and `build`.

## Remaining findings and release boundary

- During live checks Spotify showed newly created helpers as public, despite the
  creation request specifying `public: false`. The next start therefore creates
  another helper under the existing privacy guard. The service-side reason is
  unconfirmed and this separate behavior is not changed by the polling fix.
- Seeking very close to a track boundary can report an unconfirmed seek after
  Spotify already advances to the next track. This is a separate confirmation
  issue, not changed here.
- Live checks created Kinrox Queue helpers and a silent test video/recents entry.
  These artifacts were retained; no playlists or user files were deleted.
- The installed `/Applications/Kinrox.app` was not replaced. The existing live
  diagnostic Release process predates this correction. The corrected optimized
  development build is in
  `DerivedData/SpotifyPollFix.YhI9A9/Build/Products/Release/Kinrox.app`.
- The corrected build is not a notarized distribution release. Full repetition
  of the owner's live scenario against this corrected build remains unverified.
- Unrelated remote signing, TestFlight and PlayerRootView work was preserved.
