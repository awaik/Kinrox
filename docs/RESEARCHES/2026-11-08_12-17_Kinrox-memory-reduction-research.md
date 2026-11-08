# Kinrox memory use after a long session: evidence and reduction plan

Date: 2026-11-08 12:17 Europe/Moscow (16:17 Asia/Ho_Chi_Minh)

Status: Implemented and released in Mac 0.5.6 (build 16) on 2026-11-08 (all 5 steps applied and verified in `PlayerMac` and `KinroxMusic`).

Scope: Recheck the running local application, explain what the measurements do
and do not establish, and propose memory reductions without removing features.
No application code, installed application, playback controls, or account data
were changed. No release, restart, installation, or independent review was performed.

## 1. Conclusions

1. There is evidence of substantial UI allocation overhead in one observed state,
   but **halving total memory use is not demonstrated or guaranteed**.
2. The original roughly 419 MiB total was a valid snapshot, not a fixed cost.
   A later 120-second series measured **450.75 MiB median** across four processes,
   with a **449.92–488.19 MiB** range. Main-process uptime was 17h24m–17h26m.
3. A later heap inspection found about **232 thousand allocations / 75.7 MiB**,
   versus **1.60 million / 155.9 MiB** in the preceding investigation. Main-process
   footprint nevertheless changed from 377.6 MiB to approximately 417 MiB.
   This is strong reason to reject a simple allocation-count-to-footprint claim.
4. The heap scan found **2 leaks totaling 112 bytes**. Those detected leaks cannot
   explain hundreds of MiB. Reachable but unnecessary allocations, allocator
   retention, graphics resources, and unobserved lifetime problems remain possible.
5. The best plan starts with matched measurements of UI, graphics and allocation
   lifetimes. Then test conditional popover infrastructure, correct lazy layout
   boundaries, and bounded disposable metadata. Escalate to reusable AppKit rows
   or deferred video rendering only when an experiment supports the change.
6. The previously suggested 180 MiB main-process budget is an **exploratory
   target**, not an estimate of achievable savings. Smaller SwiftUI objects alone
   have not been shown sufficient to reach it.

## 2. Environment, provenance and boundaries

| Item | Observed value |
|---|---|
| Application | `/Applications/Kinrox.app`, 0.5.5, build 15 |
| Main PID | 45801; unchanged throughout the observations |
| Main launch | 2026-11-07 22:53:47 +07 |
| Hardware | MacBookPro18,2, Apple Silicon, 32 GiB RAM |
| Runtime | macOS 26.5.2, build 25F84 |
| Source HEAD | `243ecb7d91be0741154a82ec2cd7868873609055` |
| Source relation | No `PlayerMac`, `Packages`, or `Shared` changes from `v0.5.5` to HEAD |
| Initial working tree | Clean before this research |

Source equivalence by git diff supports inspecting these files for this release;
it does not constitute a reproducible-build proof for the installed executable.

The owner reports long-running playback. Process start times establish uptime,
not a complete trace of uninterrupted audio. Soloist is replaced during operation;
its short current-process uptime must not be mistaken for a Kinrox restart.
No historical 24-hour memory trace or controlled cold-start baseline exists here.

The investigator did not change window visibility, selection, navigation, volume,
or playback. The user's ongoing interaction was not controlled or logged.
Consequently, the observations are not matched before/after experiments on one
screen and must not be described as a navigation-free idle benchmark.
No Spotify.app process appeared in the earlier process inventory; this is not
continuous absence monitoring for the entire session.

Evidence directory: [2026-11-08_12-17_Kinrox-memory-evidence](2026-11-08_12-17_Kinrox-memory-evidence/).
All artifacts avoid account identifiers, tokens, track titles, allocation contents,
and full command arguments. User-home paths in tool output are redacted.

## 3. Method and memory accounting

The time series used `proc_pid_rusage`, flavor `RUSAGE_INFO_V0`, with its layout
checked against the installed macOS SDK `sys/resource.h` (96-byte structure).
It records footprint and RSS separately, every two seconds for 61 samples.
The approximately 416.95 MiB final main reading agrees with the subsequent
`vmmap -summary` reading of 416.9M, allowing for elapsed time and rounding.

- **Physical footprint** is the primary comparison metric; RSS alone can conceal
  compressed memory and includes a different set of mappings.
- MiB means 1,048,576 bytes. The report interprets `vmmap`'s binary `M` units as MiB.
- The process total is a sum of attributed process footprints, not a calculation
  of globally unique physical pages. It does not sum shared-library RSS mappings.
- The secondary Soloist process is associated by executable path and parent PID 1.
  It is labeled secondary, rather than asserting an unverified internal role.
- Heap bytes, dirty/swapped region columns, graphics mappings, and footprint
  measure different things. Do not add them into a supposed independent breakdown.
- `vmmap`'s swapped column is not a direct measurement of physical swap-file use.
  Compression, accounting, graphics mappings and overlapping categories matter.
- Allocation count counts malloc blocks, not user-visible widgets or model objects.
- `heap` and `leaks` can fault pages into memory and perturb timing. The passive
  series finished before the new diagnostic scans; do not compare scanner RSS as
  an improvement or regression. Earlier scans had already occurred in the session.

Apple describes footprint accounting and these tools in
[Detect and diagnose memory issues](https://developer.apple.com/videos/play/wwdc2021/10180/)
and [iOS Memory Deep Dive](https://developer.apple.com/videos/play/wwdc2018/416/).
The latter's iOS-specific limits are not applied to macOS in this report.

## 4. Actual measurements

### 4.1. Earlier observations retained from this conversation

These values were read from live tool output before the evidence directory was
created. They are transcribed observations, not reconstructed raw files.

| Local time (+07) | Observation |
|---|---|
| 15:37 | Kinrox 387.7 MiB; Soloist 26.7 MiB; support approximately 4.5 MiB; total approximately 419 MiB |
| 15:37 | Main-process lifetime peak 743.1 MiB |
| 15:53 | Main-process footprint 377.6 MiB |
| 15:53:40 | `heap`: 1,600,658 malloc blocks, approximately 155.9 MiB |

The earlier heap included 47,232 `HelpStyleConfiguration` style-input blocks
(3,690 KiB), 44,765 related source-input blocks (3,497 KiB), and two selected
popover-modifier types with 7,744 blocks / 605 KiB each. These are internal
structural counts: they do not mean 7,744 open panels or fully realized popovers.
Their retained descendants and contribution to footprint were not measured.

### 4.2. Recorded 120-second series

Time: 2026-11-08 16:18:28–16:20:28 +07 (09:18:28–09:20:28 UTC).
All 61 samples contained four successfully measured processes; no read failed.
The same playback-helper PID was observed throughout this short series.

| Process | Minimum MiB | Median MiB | Maximum MiB |
|---|---:|---:|---:|
| Kinrox | 416.91 | 416.94 | 455.45 |
| Soloist playback | 28.09 | 29.11 | 29.56 |
| KinroxSoloistHost | 0.92 | 0.92 | 0.92 |
| Secondary Soloist process | 3.72 | 3.72 | 3.72 |
| **Total attributed footprint** | **449.92** | **450.75** | **488.19** |

The total started at 485.17 MiB and ended at 450.44 MiB. This shows variation
and a decrease within this interval; it proves neither continuous growth nor
long-term stability. A decreasing two-minute trace cannot exclude leaks.
Totals' extrema are calculated per sample, not by adding each role's extrema.

Raw data: [memory-series.jsonl](2026-11-08_12-17_Kinrox-memory-evidence/memory-series.jsonl).
Statistics: [memory-summary.json](2026-11-08_12-17_Kinrox-memory-evidence/memory-summary.json).

### 4.3. Recorded diagnostics after the series

Main `vmmap` at 16:20:37: **416.9 MiB footprint**, **743.1 MiB lifetime peak**.
The malloc-zone table lists approximately **75.7 MiB allocated** and **68.9 MiB
fragmentation** across zones. That fragmentation figure is not a promise that
68.9 MiB can be returned to the OS by freeing one set of objects.

Graphics entries are material: `IOAccelerator (graphics)` lists 135.7 MiB virtual
and 119.6 MiB resident; `IOSurface` lists 54.9 MiB virtual and 31.0 MiB resident.
`shared memory` lists 146.0 MiB virtual and 82.0 MiB in its swapped column.
These values identify an investigation area, **not independent additive savings**.
There is no allocation backtrace or resource ownership trace proving how much
belongs to video, SwiftUI composition, window buffers, or a specific feature.

At 16:20:56, `heap` found **231,806 blocks / 79,347,716 bytes (75.7 MiB)**.
Compared with the earlier tool observation, the live heap shrank substantially,
while footprint stayed higher. The heap includes:

| Selected allocation family | Count | Bytes |
|---|---:|---:|
| Non-object allocations, unidentified by this scan | 64,663 | 48,612,332 |
| SwiftUI display-list view-cache dictionary storage | 4 | 4,868,352 |
| Help style input, one selected type | 1,218 | 97,440 |
| Related help source input, one selected type | 1,194 | 95,520 |
| MusicTrack array storage, selected type | 3 | 442,368 |
| MusicAlbum array storage, selected type | 3 | 278,528 |
| MusicQueueItem array storage, selected type | 3 | 330,752 |
| MusicArtist array storage, selected type | 3,467 | 492,528 |

Selected model-array storage is small relative to footprint, but these rows do
not include every string, nested buffer, index, or object reachable from a model.
The 48.6 MB non-object category is not attributed without allocation backtraces.
Small `NSImage`/`CGImage` object headers do not measure decoded backing surfaces.

At 16:21:11, `leaks --noContent --nostacks` reported **2 leaks / 112 bytes**,
in `CFData`. It did not report a large unreachable-memory leak. A leak scan
cannot identify all unwanted reachable retention or prove absence of growth.

Artifacts: [vmmap](2026-11-08_12-17_Kinrox-memory-evidence/vmmap-45801.txt),
[heap top entries](2026-11-08_12-17_Kinrox-memory-evidence/heap-top.txt),
[selected heap types](2026-11-08_12-17_Kinrox-memory-evidence/heap-selected.txt),
[leaks](2026-11-08_12-17_Kinrox-memory-evidence/leaks.txt),
[command timestamps and exit codes](2026-11-08_12-17_Kinrox-memory-evidence/diagnostics-manifest.json).

## 5. Source findings: confirmed behavior versus hypotheses

Paths beginning `Music/`, `Player/`, or `MPVKit/` below are relative to
`PlayerMac/PlayerMac/`; `MusicCatalog` and `MusicDiscoveryEngine` are under
`Packages/KinroxMusic/Sources/MusicCore/`. No source changes were made.

### A. Popover and tooltip infrastructure per track row

**Confirmed:** `Music/UI/TrackMetadataPopovers.swift`, `TrackArtistLink` and
`TrackAlbumLink`, attach `.popover` and `.help` unconditionally to each realized
link. The Boolean binding controls presentation; it does not conditionally omit
the presentation modifier. `Music/UI/TrackTable.swift`, `MusicTrackRow`, also
attaches title help. By contrast, `Music/UI/MusicControls.swift`, `TrackHeart`,
conditionally installs its popover background only when that anchor is active.

**Hypothesis:** extending the existing conditional-anchor pattern to artist and
album panels could reduce retained infrastructure. Preserve all panel content,
click and modifier-click navigation, anchoring, dismissal, keyboard and VoiceOver
behavior. Tooltip text must remain available, including for truncated titles;
do not simply delete `.help` to produce a favorable number. Test an equivalent
visible-row native tooltip implementation only if measured overhead warrants it.

**Unproven:** large savings, full panel content being allocated while closed,
or these modifiers explaining most of 417 MiB. The later scan directly limits
how confidently the earlier high counts can be generalized.

### B. Lazy boundaries and reusable rows

**Confirmed:** `TrackTable`, `SourceColumn`, and `CompactQueueColumn` already use
`LazyVStack`; replacing an imaginary eager top-level stack is not a new solution.
However, `DiscoveryWorkspaceView.tracksSection` uses a regular `VStack` around
the complete recommended-track `ForEach`. Its outer lazy stack sees a section,
not individual recommendation rows. `MusicDiscoveryEngine.build` returns all
ordered candidate items, so this section is not globally capped to a tiny count.
Expanded `AlbumWorkspaceCard` track lists also use a regular inner `VStack`.

**Proposal:** flatten recommendation rows into the scroll container's lazy
structure, and evaluate large expanded albums similarly. Keep every result,
reason badge, album expansion and action; pagination must not silently truncate
results. Preserve stable occurrence identity where repeated tracks are valid.

**Hypothesis:** dense rows may benefit further from a reusable `NSTableView`
implementation through SwiftUI. Treat that as a measured fallback, not a rewrite
of the app. Preserve the approved appearance, sorting, focus, scroll position,
context menus, gestures, drag/drop, popovers and accessibility.

Apple documents on-demand creation in
[Creating performant scrollable stacks](https://developer.apple.com/documentation/swiftui/creating-performant-scrollable-stacks)
and view reuse in
[NSTableViewDelegate view creation](https://developer.apple.com/documentation/appkit/nstableviewdelegate/tableview(_:viewfor:row:)).
Lazy creation alone is not a guarantee of minimum long-session retained memory.

### C. Video rendering remains initialized in Spotify mode

**Confirmed:** `Player/PlayerWindowController.swift` constructs `MPVPlayer`
unconditionally. `MPVKit/MPVPlayer.swift` initializes `MPVRenderContext`, CGL and
`VideoLayer`. `PlayerRootView` keeps the video subtree mounted with opacity zero
in music mode. Opacity and accessibility hiding are not engine teardown.

**Hypothesis:** idle video rendering and graphics resources may contribute to
music-only footprint. Their exact contribution is not measured; the graphics
region totals must not be attributed wholly to libmpv.

**Proposal:** compare a controlled music-only harness with and without initial
video renderer creation. If material, defer the renderer until needed or detach
only inactive visual resources. Keep the engine's playback truth, loaded media,
selected tracks, last frame, remote commands, mode-switch semantics and safe
render teardown. Switching views must never start or pause audio. Recreating a
renderer must not lose playback position or cause blank/fullscreen regressions.

### D. Disposable metadata can outlive the search-cache limit

**Confirmed:** `SpotifyLibraryStore+Loading.swift`, `search`, caps `searchCache`
at 20 entries and treats hits as fresh for 60 seconds, but also merges every
result into the session-wide `catalog`. Evicting a search entry does not prune
those catalog entities. `SpotifyLibraryStore+Discovery.swift` likewise merges
remote discovery entities into `catalog`. `MusicCatalog.merge` adds/replaces by
ID and has no session-budget eviction. Thus many distinct browsing requests can
increase retained metadata even with a bounded search-cache dictionary.

**Not established:** that browsing caused this long session's footprint, or that
metadata currently dominates. Passive playback and active discovery are different
workloads. No exact current library counts or private payloads were extracted.

**Proposal:** separate durable library/playlist data from disposable search and
discovery material, or budget the latter by estimated bytes and recency. Pin the
active screen, every queue occurrence, playback metadata, open previews, active
mutations and undo dependencies. Reload evicted disposable metadata from the
existing disk cache where possible. Keep search coverage, recommendations and
queue content intact; avoid extra API traffic and visible navigation delays.

`MusicViewModel` and `SpotifyCacheStore.previous` also retain catalog snapshots.
Swift value-semantic arrays and dictionaries can share storage until mutation;
multiple properties do not prove independent full copies. Measure copy-on-write
retention during updates before changing the cache diff or transaction design.

### E. Fragmentation and graphics need allocation-lifetime evidence

**Confirmed:** the later snapshot has a much smaller live heap but a substantial
footprint, significant allocator fragmentation and graphics entries.

**Hypotheses:** formerly large UI allocations leave partially used pages;
display-list/window/renderer surfaces survive screen changes; large temporary
decode or catalog-update buffers create peaks. No hypothesis is yet isolated.

Use Instruments Allocations generations plus VM Tracker and resource lifetimes
on an isolated Release build. Avoid periodic forced purges, restarting the app,
discarding user data, or removing capabilities as memory "fixes". Apple explains
why unwanted reachable allocations may evade Leaks in
[Making changes to reduce memory use](https://developer.apple.com/documentation/xcode/making-changes-to-reduce-memory-use).

## 6. Implementation order and evidence required

| Priority | Work | Decision criterion |
|---|---|---|
| P0 | Create matched Release workloads and record window/collection state, heap generations, VM and graphics ownership | Explain transitions and largest retained categories before claiming causes |
| P1 | Conditional artist/album presentation infrastructure; flatten Discovery lazy rows | Measurable footprint/peak reduction with identical functionality and results |
| P2 | Bound disposable search/discovery lifetime and reduce proven temporary/COW retention | Repeated unique browsing stops retaining unneeded entities; no extra visible latency or data loss |
| P2 | Isolate idle video renderer cost; defer only when justified | Demonstrated music-only savings with all video and coordination checks passing |
| P3 | Reuse native rows in the largest proven UI hotspot | Additional measured gain justifies integration complexity and preserves visual/interaction parity |

Savings from these proposals overlap. Do not assign or add speculative MiB
estimates. Optimize one variable at a time and retain unchanged baseline results.
The roughly 33.8 MiB median helper cost is a small fraction of this session's
total; replacing the playback engine is not the first proposal.

## 7. Validation plan without feature reduction

1. Use the same machine, OS, Release configuration, window size, library fixture,
   selected collection, queue, scroll path, playback state and measurement method.
   Compare repeated baseline/candidate runs, separating startup, warm playback,
   pause, occluded window, restored window, mode switching and active browsing.
   Measure before heap scans; instrumented and ordinary runs are separate series.
2. Include large synthetic libraries, long queues with repeated track occurrences,
   all-results Discovery, expanded albums and repeated full-list scrolling.
   Record both unique IDs and occurrence counts so deduplication cannot masquerade
   as memory savings. Keep all items reachable and playable.
3. Exercise title/artist/album tooltips, anchored previews and dismissal, modifier
   clicks, favorites and undo, per-collection sort/filter/focus restoration,
   queue insertion/reordering/removal, album/playlist drops, keyboard controls,
   VoiceOver and 30-language layouts. Preserve the approved Figma appearance.
4. Verify video open, seek, audio/subtitle choices, fullscreen, last-frame behavior,
   Matrix, Now Playing and LAN remote controls. Verify video/music coordination,
   window close/reopen and Spotify playback with Spotify.app fully terminated.
   Any future test-controlled media playback must use Kinrox volume zero.
5. Measure median, p95 and peak footprint per phase for each process and total;
   log helper transitions and failed reads. Measure CPU, wakeups and accepted
   startup/resume/Next latency so caching savings do not trade away responsiveness.
   Establish an attribution trace before claiming a peak was caused by one action.
6. Add lifecycle assertions or allocation-generation checks for the actual hot
   objects, not source-text snapshots. The existing 900-artist test counts AppKit
   subviews and excludes `NSSlider`; it does not bound SwiftUI graph allocations
   or long-session footprint. Preserve existing regression suites and supplement
   them with matched performance runs rather than fragile absolute unit-test RAM.
7. Finish with a logged 24-hour ordinary-Release playback run and a separate
   repeat-navigation soak. Compare equivalent warmed checkpoints and determine
   whether retained memory plateaus. A proposal is accepted only if the measured
   reduction survives this workload and the functional checks still pass.

For a claimed **2x reduction**, total attributed footprint must be at most 50%
of its matched baseline in the stated phase, with no meaningful regressions in
other phases. Relative to the original 419 MiB snapshot this implies about
210 MiB total / 180 MiB main process; relative to the new 450.75 MiB median it
implies about 225 MiB total. These are different baselines, not interchangeable
acceptance results. No target has been achieved by this research.

Runtime testing remains on the available macOS version. Check deployment-target
metadata; do not add a separate macOS 14 runtime requirement or reopen the owner's
waived physical sleep/reboot checks.

## 8. Deliverables, checks and remaining limitations

- Added this research/plan and aggregate evidence only. Application implementation
  and tests are unchanged; application test suites were not rerun for documentation.
- Collection scripts perform no application controls or account reads. They record
  process counters and aggregate diagnostics; no memgraphs or allocation contents.
- The sampler completed all 61 reads for all four observed processes. `vmmap`
  agreed with the subsequent main-process sampler reading within rounding/time.
- The `leaks` result reports a nonzero leak count; its return status is preserved
  in the manifest rather than presented as a passed zero-leak check.
- Report/artifact links, JSON/JSONL parsing, recalculated series statistics,
  Python syntax, redaction, line limits and authored-file whitespace checks
  passed. Captured diagnostic formatting was preserved. Results and the initial
  whitespace-check correction are recorded in
  [validation.json](2026-11-08_12-17_Kinrox-memory-evidence/validation.json).
- Unresolved: allocation backtraces, graphical resource ownership, controlled
  screen-state reproduction, cold baseline, 24-hour trend and achievable savings.
  No large-leak, continuous-playback, stable-RAM or 2x-reduction claim is made.

Related historical evidence:
[Music CPU/memory investigation, 0.5.1 to 0.5.2](<DONE/DONE - 2026-11-04_09-25_Music-CPU-and-memory-investigation.md>)
and [Soloist verification](../runbooks/SOLOIST-VERIFICATION.md).
Earlier report targets and planned reductions are not treated as fresh measured
results for 0.5.5.

## 9. Additional root causes identified in `heap-top.txt` and implemented fixes (2026-11-08)

1. **`SoloistProcessSupervisor` per-track `URLSession` & verification churn (fixed in `Music/Soloist/SoloistProcessSupervisor.swift`):**
   - `heap-top.txt` recorded `168 __NSURLSessionWebSocketTask` (`172 KB`), `169 __NSURLSessionLocal` (`76 KB`), `169 std::__shared_ptr_emplace<NWIOConnection>` (`130 KB`), `840 NSURLRequestInternal` (`215 KB`), `1,009 CFHTTPMessage` (`280 KB`), and `1,194 dispatch_queue_t (serial)` (`153 KB`) after ~168 played tracks (~1–2 MiB total direct heap size).
   - In `HEAD` (`v0.5.5`), `SoloistProcessSupervisor.launch()` created a new `URLSession` on every track launch, and `stop()` called `socket?.cancel(with: .goingAway, reason: nil)` and `session?.invalidateAndCancel()` without calling `URLSessionTask.cancel()`. While `heap-top.txt` alone (without `MallocStackLogging` retain graphs) does not isolate why `CFNetwork` kept 168 invalidated session/WebSocket state machines alive after teardown raced with child termination, creating a fresh `URLSession` per track was unnecessary.
   - **Fix:** Reuse a single `URLSession` via `activeSession()` across track launches (invalidated in `close()`), abort dead tasks immediately via `(activeSocket as URLSessionTask).cancel()`, and cache a nanosecond-precision `SoloistVerifiedStamp` (`dev`, `ino`, `mode`, `uid`, `size`, `mtime`, `ctime`, `btime`, `digest`, `hostRequirement`, verified unchanged before and after hashing/signing) so `launch()` does not re-read the multi-megabyte binary and spawn `/usr/bin/codesign` on every track change when the files on disk are unchanged.
2. **Idle `VideoLayer` OpenGL backing in Music mode (fixed in `MPVKit/VideoLayer.swift`, `MPVKit/VideoView.swift`, `Player/PlayerView.swift`, `Player/PlayerRootView.swift`):**
   - **Fix:** Unmount `VideoView` / `WelcomeView` inside `PlayerView` when `session.mode != .video` and no video is active (`!model.hasMedia && !model.isLoading`), and call `videoLayer.releaseBacking()` (`frame = .zero`, `contents = nil`) when `VideoHostView` leaves its window (`window == nil`), while preserving `PlayerView` state and traffic-light coordination.
3. **Conditional popover/help modifiers & lazy stacks (fixed in `Music/UI/TrackMetadataPopovers.swift`, `TrackTable.swift`, `DiscoveryWorkspaceView.swift`, `AlbumsWorkspaceView.swift`):**
   - **Fix:** Attach `.popover` on `TrackArtistLink` and `TrackAlbumLink` only when `isPresented` is true, scope row/link `.help` tooltips via `.hoverHelp(_:active: hovered)`, and replace eager inner `VStack` containers in `DiscoveryWorkspaceView.tracksSection` and expanded `AlbumWorkspaceCard` views with `LazyVStack`.
4. **SQLite `mmap`, streaming batch decoding, digest-based cache diff, `MusicCatalog` String/Artist interning, and disposable catalog pruning (fixed in `SpotifyCacheDatabase.swift`, `SpotifyCacheDecoder.swift`, `SpotifyCacheStore.swift`, `MusicCatalog.swift`, `SpotifyLibraryStore*.swift`):**
   - **Fix:** Enable `PRAGMA journal_mode = WAL`, `PRAGMA mmap_size = 67108864` (64 MiB), `PRAGMA cache_size = -2000` (2 MiB private page cache), and `PRAGMA temp_store = MEMORY`; stream catalog JSON blobs directly from SQLite `mmap` pointers into framed batch buffers (`catalogBatches`) without per-row `[Data?]` copies; replace `SpotifyCacheStore.previous: SpotifyCachedLibrary?` with lightweight 64-bit entity digests (`SpotifyCacheSummary`); intern `[MusicArtist]` arrays and `String` buffers in `MusicCatalog.merge`; and bound disposable search/discovery catalog entities via `pruneDisposableCatalog`.
5. **Observation isolation in `MusicViewModel` (fixed in `Music/MusicViewModel.swift`):**
   - **Fix:** Extract `MusicPopoverState` and `MusicFocusState` as dedicated `@Observable` objects on `MusicViewModel` so row popover/focus observers are isolated from catalog, library, and playback mutations.
