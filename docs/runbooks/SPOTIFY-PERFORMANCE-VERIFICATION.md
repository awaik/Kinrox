# Spotify cache and latency verification — 2026-11-02

Local implementation of [the approved plan](../RESEARCHES/2026-11-01_17-00_Spotify-SQLite-and-latency-plan.md).
The implementation was committed as `80e753d` and is included in the Mac 0.4.2 release
authorized on 2026-11-02. The original implementation task did not change a Spotify account,
live playlist, website deployment, release version, signing configuration or App Store submission.
Release verification is recorded in the [0.4.2 notes](../releases/0.4.2.md).

## Implemented behavior

- `MusicCatalog` owns derived identity indices and preserves presentation order and duplicate
  playlist occurrences. Browser, album, remote metadata and merge paths use these indices.
- A serial SQLite actor stores only typed metadata in five tables under the Mac app's Caches
  directory. SHA-256 account namespaces verify Client ID/user ID, exclude backups, expire
  unvalidated resources after seven days, preserve complete resources during pruning and cap
  the file at 100 MiB. Corrupt/newer schemas recover without blocking playback. Disk write
  failure retains a successful Spotify mutation; it never triggers remote compensation.
- A verified account binding restores the cache before token refresh. Commands remain disabled
  until connection completes. Interactive login and Client ID changes hide the previous cache.
  Disconnect retires sync, settles playback, closes the client and removes owned database files,
  sidecars, account binding and queue preferences. Demo mode remains offline.
- Restoration first publishes the album/artist catalog and the initially selected album's
  tracks, then hydrates the remaining catalog off MainActor. This preview is read-only and is
  never persisted as a complete snapshot. Resource-dependent operations await full hydration;
  token refresh starts afterward. Database generation and session guards reject retired decodes
  and writers, including results suspended during disconnect.
- Library loading publishes saved albums and playlist summaries before liked tracks/artists,
  then loads changed editable playlists. Embedded album tracks avoid redundant requests.
  Navigation shares in-flight loads; search uses a 20-query, 60-second memory cache.
- Favorite intents acquire a mutation slot before resource readiness and policy evaluation.
  Membership and Undo validate complete playlists against live snapshots; unlike loads every
  editable playlist. Undo retains the confirmed post-write snapshot. Resource revisions retire
  responses crossing writes or compensation; revalidation starts after settlement. Positional
  mutations are never replayed over fetched data.
- HTTP admission allows three concurrent requests, at most two non-control requests. Control
  precedes interactive and background work. Identical cacheable reads share tasks by canonical
  URL, validator and revision. Live playback/helper validation never coalesces. Conditional 304
  retains typed data; queued requests recheck shared Retry-After before sending.
- Playback mirrors history plus current/upcoming occurrences. Validated Resume and offset jumps
  use three HTTP requests before confirmation, with no playlist writes. Manual insertion uses
  the correct position before source items without pausing. Other structural edits rebuild;
  paused edits never start playback. Helper version, ownership and privacy are checked live.
- Continuous polling is removed. A monotonic Mac clock advances displayed progress and a single
  timer observes the track boundary. Paused playback makes no background requests. The default
  confirmation delays start at 80/150/300 ms. Near-end seeks accept natural advancement. Sliders
  retain the latest pending value. Generation guards reject superseded observations and errors.
- Optional protocol field `music.positionAge` carries the age of a confirmed anchor. The iPhone
  accounts for that age once, including after metadata updates and reconnection; it does not
  receive an already-extrapolated position. Existing messages and older decoders remain valid.
- Consent version `2026-11-02` describes SQLite storage, retention and deletion in all 30 locales.
  Existing users must accept that version before reconnection/persistence. The public HTML is
  regenerated locally from the same resources.

## Measurements

Synthetic fixtures contain 100 tracks, or 10,000 tracks / 1,000 albums / 100 playlists.
Queue request budgets cover lengths 1, 50, 100 and 500. Measurements use the development Mac;
these are not Spotify service latency or physical-device measurements.

| Measurement | Baseline | Implemented result |
|---|---|---|
| 10,000-track playlist selection, optimized Swift, p95 of 20 | 138.61 ms | 2.08 ms |
| 10,000-track catalog merge + selection, optimized Swift, p95 of 20 | Not recorded | 15.18 ms |
| Cache open to first MainActor model publication, 100 tracks, Debug p95 of 20 | No disk cache | 16.65 ms; no HTTP |
| Cache open to first MainActor model publication, 10,000 tracks, Debug p95 of 20 | No disk cache | 40.98 ms; no HTTP |
| Complete cache hydration, 100 / 10,000 tracks, Debug p95 of 20 | No disk cache | 18.98 / 155.59 ms |
| Saved album with complete embedded tracks | 2 GETs in the original path | 0 additional GETs |
| Uncached album with complete embedded tracks | 2 GETs | 1 GET |
| Validated warm Resume | Full mirror path | 3 requests before confirmation; 0 playlist writes |
| Validated unchanged-order Next / Previous | Full mirror path | 3 requests before confirmation; 0 playlist writes |
| Manual queue insertion | Pause, replacement, restart | 1 helper validation GET + 1 positional POST; no pause/restart |
| Steady-state playback requests | 2 s playing / 10 s paused | No periodic polls; one boundary observation; no paused timer |
| Controlled second-observation confirmation | 2-second interval | 236.82 ms total with the default backoff |

The earlier full-mirror request counts in the plan are source-derived, not live baseline timings.
The first-publication measurement includes `MusicViewModel` receiving data and resolving the
selected album; it does not measure a rendered screen frame. Full catalog hydration is a later
publication. The 80 + 150 ms confirmation sleeps match the specified schedule; measured total
time is approximately 7 ms above the plan's 230 ms upper target due to request/scheduling overhead.
The fixture returns the old state on the first observation and the new state on the second;
it does not simulate real Spotify propagation. The catalog measurements use the same optimized
fixture before and after, without SwiftUI drawing. The initial Mac baseline build overlapped
the catalog's move into its own file; no pre-change full Mac test result is claimed.

## Verification and limitations

Logs and generated test artifacts are retained under `DerivedData/SpotifyPerformance/`.
Fresh build directories are used instead of deleting existing artifacts. An incremental Mac build
found an obsolete `Debug/RemoteProtocol.swiftmodule` alongside the newer package framework;
a new build directory avoids that conflicting module. The existing SwiftPM build directory also
produced transport-test failures and a test-helper crash; all 126 protocol tests passed in the
isolated `ProtocolFresh` directory.

| Final check | Result | Log under `DerivedData/SpotifyPerformance/` |
|---|---|---|
| PlayerMac Debug, arm64 | 210 tests / 43 suites passed | `mac-final-report.log` |
| PlayerMac Release | Build succeeded | `release-build-final.log` |
| KinroxMusic package | 32 tests / 7 suites passed | `music-final.log` |
| RemoteProtocol package, isolated scratch directory | 126 tests / 22 suites passed | `protocol-fresh.log` |
| RemoteiOS, iPhone 17 simulator | 61 tests / 12 suites passed | `ios-tests.log` |
| Python scripts, including all-locale cache disclosures | 46 tests passed | `scripts-handoff.log` |
| Localization | 30 locales / 348 UI keys, prompts and format arguments verified | `localization-final.log` |
| Generated website | 120 pages / 30 languages verified | `site-final.log` |
| Strict Swift lint | All 279 repository Swift files passed | `format-handoff.log` |
| Whitespace / changed Swift file length | `git diff --check` passed; maximum 400 lines | Console output |

Coverage includes namespace isolation, resource expiry, corruption/future schemas, retired
writers, cancellation, conditional responses, prioritized requests and cooldowns, partial sync,
mutation/compensation races, complete playlist readiness, duplicate-preserving Undo, helper
validation, warm request budgets, insertion/rebuild cases, stale boundary results, EOF, local
progress and slider coalescing. The simulator includes anchor-age correction. Existing
`freshSpotifyRestrictionsPreventSeekRequest` passed in the complete Mac suite; this does not
establish the cause of the earlier reviewer-reported flake.

No live Spotify session or physical iPhone verification was performed. Local notification-based
Spotify reconciliation remains optional and is not installed: changes made directly in Spotify
are observed on the next Kinrox command or expected track boundary. Duplicate URIs remain
inherently ambiguous after missed external transitions because Spotify does not expose the
current occurrence index. macOS 14 and iOS 17 were not separately exercised; development libmpv
retains the existing newer-macOS linker warning.


## Discovery memory follow-up — 2026-11-12, not released

The [local implementation and live evidence](<../RESEARCHES/DONE/DONE - 2026-11-12_07-05_Kinrox-memory-peak-and-improvement-plan.md>)
replaces pairwise Discovery scans with indexed equivalent ranking, defers large preview builds
off MainActor, bounds disposable caches and lazily installs row help. The 20k optimized ranking
medians are 173/76 ms (seeded/unseeded); measured Mac MainActor occupancies are 99/90 ms.

Two local Release cold starts on the real library peaked at 123.3/120.8 MiB, compared with the
installed build's 848–849 MiB reproduced peak. The longer interaction session peaked at 212.2 MiB.
This is not a long-session or full standalone playback acceptance run: Similar retained elevated
SwiftUI CPU work, accessibility diagnostics reported 23.3 KiB of leaked allocations, and playback
was not attempted because the UI could not confirm zero volume. The report preserves these limits,
provider-unavailable results and earlier test failures alongside the final passing 369-test Mac run.
No release or installed-app replacement occurred.
