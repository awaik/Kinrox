# Music mode v2 verification

Implemented 2026-11-01; included in Mac 0.4.0 (build 6). Historical implementation
evidence follows; release checks are in [0.4.0 Verification](0.4.0-VERIFICATION.md). Contract:
[Music v2 plan](<../RESEARCHES/DONE/DONE - 2026-11-01_09-11_Music-mode-v2-implementation-plan.md>).
Setup and behaviour: [unreleased notes](../releases/UNRELEASED-MUSIC.md).

## Owner decisions

- D1: opt-in Spotify internet access on Mac only, no Kinrox backend or analytics.
- D2: official Spotify Connect Web API; audio plays in Spotify.app on the same Mac.
- D3: each user supplies their own developer app Client ID in Settings.
- Private **Kinrox Queue** approved after raw `uris` playback failed in Phase 0.
- Official Spotify logo on Mac/iPhone and a Mac link to Spotify approved.
- Recovery line in column 3 with Settings/Retry approved; favorites errors remain
  in the bottom status bar. No extra recovery dialogs were introduced.
- The owner installed the physical iPhone build and answered **“работает”** to the
  requested pause/resume, next, queue and favorites/playlist/artist check.

## Implementation

`MusicCore` contains independent favorites policy, undo mutations, occurrence-based
queue, selection and membership indexing. Only PlayerMac links `SpotifyWebAPI`.
The iPhone receives metadata and sends commands over the encrypted LAN protocol.

OAuth uses PKCE, random state, a validated loopback callback at
`http://127.0.0.1:43821/callback`, and the Mac Data Protection Keychain. No client
secret is used. Refresh is coalesced, API redirects are rejected, pagination is
origin-checked, and HTTP 429 applies a shared Retry-After cooldown. Shutdown rejects
new requests and drains entered requests before invalidating URLSession.

Library refresh publishes an atomic snapshot. Playlist membership is indexed by
snapshot ID; unchanged lists are not re-read. Favorite writes are serialized and
optimistic on Mac, with compensation on partial failure. Undo restores duplicate
playlist occurrences and positions. Unliking never unfollows artists, never alters
foreign playlists and leaves the visible row until navigation/refresh. The iPhone
updates only after confirmed Mac state, including opening the favorites sheet.

The Connect engine verifies the stored helper playlist's ownership/private state
before writing it and never adopts a playlist by name. It excludes the helper from
favorites membership. Queue changes mirror into the helper in API-sized batches;
paused edits never start playback. Disconnect clears credentials, memory and all
locally stored account-to-queue playlist bindings after pending playback work
settles. The helper playlist and intentional Spotify library changes remain intact.

Player commands complete after observed state, rather than HTTP 204 alone. The
engine checks local device, context, URI (including relinking), position, pause
and volume as relevant. State polling is 2 seconds playing / 10 seconds paused.
The coordinator serializes source transitions, waits for the previous source to
pause, and owns one Now Playing controller. Closing and immediately reopening a
window cannot race an old music engine against a new one.

Additive protocol v1 fields are optional. Eight music commands and four paged
message types have byte-exact fixtures. Queue/like-options replies include a
revision; stale pages restart at zero. Pages adapt below the protected 64 KiB
frame limit. Disconnect clears iPhone pages and pending requests. Existing video
fixtures and the cryptographic handshake remain unchanged.

## Automated evidence

Logs are local session artifacts; they are not committed deliverables.

| Scope | Result | Log |
|---|---|---|
| MusicCore + SpotifyWebAPI | 23 tests, 5 suites passed | `/tmp/kinrox-music-final-package.log` |
| RemoteProtocol + RemoteTransport | 124 tests, 22 suites passed | `/tmp/kinrox-music-protocol-final2.log` |
| Mac, including non-Latin keyboard regression | 160 tests, 36 suites passed | `/tmp/kinrox-music-final-mac-tests5.log` |
| Final Mac after lazy-list navigation correction | 160 tests, 36 suites passed | `/tmp/kinrox-music-final-mac-tests7.log` |
| Final iPhone simulator, including attribution and queue spacing | 58 tests, 12 suites passed | `/tmp/kinrox-music-final-ios-tests3.log` |
| iPhone tests on the physical device | 58 tests, 12 suites passed | `/tmp/kinrox-music-final-ios-device-tests.log` |
| Physical iPhone build/install | Build passed, installed, owner confirmed music works | `/tmp/kinrox-music-device-build.log` |
| Final physical iPhone build | Build passed; updated app installed | `/tmp/kinrox-music-device-final-build2.log` |
| Localization | 337 UI keys, all 30 locales and format arguments passed | `Scripts/check-localization.py` |
| Website generation | 90 pages in 30 locales verified | `Scripts/build-site.py --check` |
| Strict Swift formatting | Passed after explicit Spotify JSON CodingKeys | `/tmp/kinrox-music-final-format5.log` |
| Source length and shell syntax | No source/config/script over 500 lines; shell checks passed | `rg --files` line scan; `bash -n` |

Coverage includes 55 editable-playlist fixtures, duplicate removal/undo, independent
track/album/artist favorites, partial-write compensation, retry without duplicate
playlist creation, disconnected-store races, OAuth rejection and refresh, 429,
malicious paging, observed playback confirmation, paused queue edits, helper
ownership, local-device restriction, source switching and immediate window reopen.

Intermediate runs timed out in existing LAN timing tests: automatic WebSocket
pong and Matrix failed-start handling. The protocol full rerun passed all 124;
Mac full runs passed all 160. Matrix
timeout failures recurred during final UI checks; the isolated diagnostic rerun
passed all three tests (`/tmp/kinrox-music-matrix-diagnostic.log`). Its wait now
reports a closed client's real failure instead of hiding it behind an eight-second
test timeout. No production transport timeout or heartbeat was relaxed. The final full Mac run
then passed all 160 tests (`/tmp/kinrox-music-final-mac-tests7.log`). An earlier stale
incremental package build failed enum decoding; a fresh scratch build passed.
Artifacts were preserved. No test uses live Spotify unless its explicit Phase 0
environment flag is supplied.

## External review corrections — November 1, 2026

All seven review findings were checked against the current implementation:

1. **Shared license scope: fixed.** RemoteiOS links `MusicCore`, but its source path
   was absent from the shared-code permission. The exception, scope table and
   contribution terms now cover `Packages/KinroxMusic/Sources/MusicCore/` only;
   `SpotifyWebAPI` remains outside the exception. Both app bundles test the scope.
2. **Collection Shuffle: fixed.** One coordinated start now shuffles every
   occurrence, including the first, before contacting the engine. It retains the
   original source order and never marks skipped source positions as history.
   Empty collections do nothing; shuffling the existing queue remains an edit.
3. **Remote favorites lookup and replies: fixed, with corrected rationale.**
   Track/artist lookup shares the catalog, published queue and pending queue.
   Unsupported option IDs and unusable labels are filtered before pagination;
   replies are encoded and checked against the protected-frame budget. Blank
   titles were already wire-valid, contrary to the review; the wire contract
   still allows them. The UI omits blank rows. Invalid IDs did cause unsendable
   replies and are covered by regression tests.
4. **Window buttons: fixed.** The window remembers video control visibility and
   reapplies it on both mode changes, including return to an active Matrix.
5. **Disconnect storage: fixed.** The actual prefix is
   `app.kinrox.spotify.queue.`. All entries under that prefix are forgotten after
   teardown, including bindings saved by work already in flight. Unrelated
   preferences and Spotify playlists are preserved.
6. **Source arrows: fixed.** An active search is the first keyboard source, just
   as it is in the visible source column.
7. **Repeat command polling: fixed, with corrected rationale.** The repeat-only
   branch now excludes polling until its HTTP request succeeds or fails. The
   current engine does not publish Spotify's repeat state, so the review's
   specific repeat-indicator flicker claim was unsupported. Concurrent polling
   during the command was reproduced. The guard is scoped to this branch to
   avoid nesting Boolean guards around `play` and `setPaused`.

Before fixes, `MusicReviewRegressionTests`, the new bundled-license assertion,
and the delayed repeat-request test failed for the reported defects. For the
Shuffle regression, the existing button action was first extracted unchanged
into `shuffleCollection()` so the test exercised the same action. Logs:
`/tmp/kinrox-review-red.log` and `/tmp/kinrox-review-repeat-red.log`.

Verification of the reviewed implementation, completed before the concurrent
changes noted below:

| Scope | Result | Log |
| --- | --- | --- |
| Music package | 24 tests, 5 suites passed | `/tmp/kinrox-review-music.log` |
| Protocol and transport, fresh scratch directory | 125 tests, 22 suites passed | `/tmp/kinrox-review-protocol.log` |
| Mac, fresh derived data | 169 tests, 37 suites passed | `/tmp/kinrox-review-mac-fresh.log` |
| iPhone simulator, fresh derived data | 59 tests, 12 suites passed | `/tmp/kinrox-review-ios.log` |
| Environment, strict Swift lint, localization, website generation, shell syntax and 500-line limit | Passed | `/tmp/kinrox-review-env.log`, `/tmp/kinrox-review-format.log` and command output |

The first incremental Mac build could not see the new `MusicQueue.startShuffled`
method. A fresh build passed; no existing cache or artifact was deleted. Task
builds remain under `DerivedData/ReviewMac.rpd7Iv`, `DerivedData/ReviewIOS.EBFk16`
and `DerivedData/ReviewProtocol.*`.

Runtime verification used a separate demo process with Spotify restoration,
remote advertising and the updater disabled through process-only settings.
Shuffle began on Warm Wind and kept all 12 album tracks; source arrows moved from
search to liked tracks and back after leaving the field editor. Matrix → Music
→ Matrix via Command-2/Command-1 restored hidden window buttons without mouse
movement. The screenshot and accessibility state both confirmed this. Volume
remained zero. Live Spotify and the physical iPhone were not retested in this
review pass; HTTP failures, favorites and disconnect use controlled fixtures.

After those builds completed, concurrent work changed Spotify playback
restrictions and track availability (including `MusicViewModel+Playback.swift`,
`SpotifyConnectMusicEngine.swift`, its state extension, remote commands and
`Command+MusicAvailability.swift`). A closing strict-lint run then reported
formatting errors in those new edits. They were left untouched; all seven review
fixes were checked for preservation. The passing results above apply to the
tested build, not to subsequent concurrent revisions of the working tree.

## Visual checks

Figma page [08 · Music — Spotify](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox?node-id=88-304)
remains the layout source. Approved additions were made there before code:

- Full/compact Mac title bars: `103:935`, `110:3089`.
- iPhone header, queue header and favorites sheet: `111:2937`, `111:3074`, `111:3291`.
- Recovery component `116:3116`, with offline, re-auth, Premium, other-device and
  unavailable variants `117:3098`, `117:3101`, `117:3104`, `117:3107`, `117:3110`.

Figma Plugin API screenshots were inspected, including the full iPhone remote.
Standard context/screenshot calls for two mobile frames returned Transport closed;
Plugin API rendering succeeded. Official white SVG attribution was imported
unmodified from Spotify's design asset bundle. The Mac logo opens the selected
album/current track in Spotify; the iPhone logo makes no internet request.

Mac screenshots for albums, liked tracks and queue at both 1440 × 900 and
1024 × 768 are in `/tmp/kinrox-music-snapshots/`. Rendered sizes were inspected;
track columns fit the available width, deck bars stay inside the display and the
compact search clears the mode switch. The capture test is opt-in through
`TEST_RUNNER_KINROX_MUSIC_SNAPSHOTS` when invoked with xcodebuild.

The production Mac UI was launched, connected and browsed with the owner's account.
The physical iPhone build was installed and the owner confirmed its music controls.
Final simulator screenshots of the remote, queue and favorites sheet were compared
with Figma. The simulator initially stalled on app/test launch; a dedicated
`Kinrox Music QA 2026-11-01` device eventually launched successfully, and its final
58-test run passed. Existing simulator data was not erased.

## Corrections found during manual checks

- With the active RussianWin keyboard layout, Command-F and Command-Z did nothing,
  while arrow navigation and AppKit's Command-1/2 still worked. The custom keyboard
  handler compared Latin characters literally. It now normalizes case and falls
  back to the physical F/Z/L key only for non-ASCII input. Two regression tests cover
  Russian, Caps Lock and preservation of remapped Latin layouts. Command-F search,
  Esc and Command-Z were then verified live; a test like was restored to its original
  off state without altering playlist membership.
- Returning from flat search to an album could retain the first lazy row's old
  column geometry. The table now resets its view identity on source/album changes.
  A fresh production launch verified search → Esc restores row 1 and album columns.
- Native iOS List section margins added excess whitespace relative to Figma. Queue
  headings now use explicit row spacing; swipe removal and drag reordering remain.

## Live Spotify evidence and limits

- PKCE login/refresh, 760 liked tracks, 12 albums, 219 artists and 7 editable
  playlists were read. Initial read sweep used 37 requests; 282 playlist entries
  indexed in 3.352 seconds. These are measurements for this account, not a quota
  guarantee for arbitrary libraries.
- Consolidated library PUT/DELETE for tracks, albums and artists was verified with
  original membership restored. Playlist create, add, replace, remove and paged
  `/items` reads were verified. The empty private **Kinrox Phase 0 verification**
  playlist was intentionally retained. Four playlists named **Kinrox Queue** were
  visible at the end of development; one is the persisted active helper, while
  earlier copies remain untouched. Only the current helper ID is excluded from
  favorites. No playlist was deleted or adopted by its display name.
- Ordered raw `uris` playback returned 204 but cleared playback; subsequent controls
  returned 403. Album and private-playlist contexts, seeking, pause and next worked.
  This failure is why the approved helper playlist is required.
- Production Kinrox connected via Settings, browsed the real library, started the
  A Touma album and showed Nan Sira Madi with an eight-item queue, advancing position
  and an observed pause. Physical iPhone controls were confirmed by the owner.
- The Phase 0 final volume assertion observed 82 despite an earlier successful
  command; Spotify was muted and paused through its UI afterwards. Production
  checks began with observed volume zero. A later manual-session state showed 51
  while the owner was also testing; its cause is not established. Playback was
  paused and zero was restored. Mac system volume was never changed. These checks
  are not evidence of a universally reliable Spotify volume command.
- Full multi-playlist unlike/undo and duplicate restoration are covered by policy,
  service and endpoint tests. The whole Mac UI sequence was not independently
  repeated against every real playlist. Offline/reauth/Premium/429/device-change
  branches use controlled stubs; the real account was not revoked or rate-limited.
- The coordinator's no-overlap and window-reopen guarantees were checked with
  controllable engines. Simultaneous real video/Spotify audio switching was not
  independently exercised through every failure path.

## Release boundary

The privacy and landing copy in all 30 locales now distinguish local video/LAN
control from optional Spotify access in development builds. Generated HTML and
release notes are prepared, but no version bump, archive, notarization, appcast,
App Store submission or website deployment was performed.

Spotify policy review completed on 2026-11-01 and found unresolved release issues:
see the [compliance audit](<../RESEARCHES/DONE/DONE - 2026-11-01_11-36_Spotify-policy-compliance-audit.md>).
The current build preserves the owner's explicit heart/silent-unlike contract;
the audit proposes changes but does not implement them or clear public release.

Remaining platform limits: no artwork, iPhone album browser or audio spectrum;
the bars are decorative. Web API polling cannot identify a duplicate playlist
occurrence unambiguously after missed transitions or external changes. macOS 14
and iOS 17 are deployment targets, not manually tested runtime versions in this
session. The development Homebrew libmpv warning about macOS 26 is pre-existing;
distribution must use the pinned portable libraries.

Concurrent licensing edits and all build/test artifacts were preserved. No branch,
commit, worktree or cleanup was created/performed by the music implementation task.

## Spotify interface and consent follow-up — 2026-11-01

Implemented locally: official plus/active favorites and transient confirmed feedback,
contextual links on both platforms, complete metadata UI, explicit labels, playback
action restrictions, Disconnect cleanup, and versioned offline connection terms.
[Scope, checks and release boundaries](<../RESEARCHES/DONE/DONE - 2026-11-01_11-55_Spotify-interface-and-consent.md>).
At that stage, full terms/privacy were English only; the follow-up below completes
their localization. Publish the prepared website documents with the music release.

## Full document localization — 2026-11-01

Full connection terms (eight sections) and privacy supplement (six sections) now
cover all 30 app languages. App language selection, regional matching, RTL layout,
and rejection of incomplete or mismatched documents are implemented. The same
JSON resources generate localized terms and full privacy pages, with isolated
clickable URLs for RTL text. The consent version remains `2026-11-01`; translation
does not change the approved conditions.

Validation: 12 Mac tests across document loading, consent behavior and localization
passed; 8 website tests and 5 document publication tests passed. All 120 pages and
30 locales/348 UI keys passed offline checks. The Mac build and targeted strict
Swift formatting checks passed. No live Spotify calls or consent acceptance were
needed. [Details and release status](<../RESEARCHES/DONE/DONE - 2026-11-01_12-23_Spotify-document-localization.md>).
