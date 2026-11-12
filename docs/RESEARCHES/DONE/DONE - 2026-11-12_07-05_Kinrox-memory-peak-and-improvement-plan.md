# Kinrox memory: 879 MiB peak investigation and improvement plan

Date: 2026-11-12 07:05 Europe/Moscow (11:05 Asia/Ho_Chi_Minh)

Status: Implemented locally; not released.

Investigation history: Investigation complete for the peak, fix not implemented. The peak was
**reproduced on every cold start** (2 of 2) and its cause identified (section 3a). The remaining
plan items are not started. No application code was changed. The owner closed the running session;
installed `/Applications/Kinrox.app` was then started and quit twice by the investigator (recorded
below as 0.5.7; artifact headers confirm `/Applications/Kinrox.app` on disk was already 0.5.8
build 18 for the cold-start runs, while the earlier 14 h session PID 78147 ran 0.5.7 build 17).

Related: [2026-11-08 memory reduction research](../2026-11-08_12-17_Kinrox-memory-reduction-research.md)
(implemented in 0.5.6) and
[Music CPU and memory investigation](<DONE - 2026-11-04_09-25_Music-CPU-and-memory-investigation.md>).
Existing sampler: `docs/RESEARCHES/2026-11-08_12-17_Kinrox-memory-evidence/measure-memory.py`.

## 1. Symptoms and question

The owner asked where roughly 200 MB goes in a Music-mode session and whether the 879 MiB peak
seen in the same process came from before the 0.5.6 memory fixes.

## 2. Measurements (2026-11-12, installed Kinrox 0.5.7 build 17)

Main process PID 78147, launched 2026-11-11 20:20:12 +07, about 14 h 15 m old at the first reading.
Physical footprint, from `footprint` and `vmmap -summary`:

| Process | Footprint |
|---|---|
| Kinrox (main) | 147 MB (154 MB 28 minutes later, same process) |
| Soloist playback engine (idle, single track, volume 0, 3 minutes old) | 28 MB |
| Sparkle `Autoupdate` (running 12 h) | 7.4 MB |
| Soloist crashpad handler | 3.7 MB |
| `KinroxSoloistHost` | 0.9 MB |
| **Total** | **≈ 187 MB** |

Main process, by category: `MALLOC_SMALL` 76 MB (67 MB of it compressed or swapped), `IOSurface`
22 MB, other `VM_ALLOCATE` 14 MB, Foundation 9 MB, graphics-owned 4.4 MB, CoreAnimation 3.4 MB.
`heap` reports 578,688 live nodes / 71.2 MB. The largest family is 21.7 MB of untyped
allocations; next are SwiftUI view-graph storage: `AnyTrackedValue` dictionaries (3.3 MB),
`HelpStyleConfiguration` elements (about 2.2 MB, roughly 27 thousand objects), button-style
configuration elements and `DisplayList` items. `phys_footprint_peak` is **879.5 MB**.

Earlier published values for the same build family: 158 MB total on 2026-11-08 (123 MB Kinrox)
and 193 MB after 12 h on 2026-11-09 (161 MB Kinrox), so the main process grew about 38 MB in 12 h.

## 3. What is established about the peak

1. The peak belongs to PID 78147, launched at 20:20 on 11-11 and running 0.5.7. The 0.5.6 memory
   changes are already in that build. The peak therefore did **not** happen before them.
2. 0.5.8 (released 11-11 22:02) lists no memory change, and the installed app is still 0.5.7.
   Nothing since the peak targets it. *(Review note: PID 78147 launched at 20:20 on 11-11 before
   0.5.8 shipped and therefore ran 0.5.7 build 17 — which also explains why Sparkle `Autoupdate`
   was resident for 12 h holding a pending 0.5.8 gentle-reminder session while the window stayed in
   Music mode. By 2026-11-12 morning `/Applications/Kinrox.app` on disk was 0.5.8 build 18, as
   recorded in line 5 of `heap-at-plateau.txt`, `vmmap-at-plateau.txt`, and
   `main-thread-sample-excerpt.txt`.)*
3. `phys_footprint_peak` records a maximum only. Time of occurrence, trigger and the owning
   allocation are unknown. The running process footprint is stable at about 150 MB, so the
   state that produced the peak is gone and cannot be inspected now.

## 3a. Reproduction and cause (2026-11-12, cold start of installed 0.5.7; artifact headers: 0.5.8 build 18)

Local-only evidence directory (not included in the repository):
`2026-11-12_07-05_Kinrox-memory-peak-evidence/`.
The owner excluded this exact directory from version control while preserving every file in place.
Evidence filenames and `EVIDENCE` paths below refer to these local-only artifacts; the measured
results, conclusions and limitations remain in this document so it can be read independently.

**Reproduced.** Run 1 (1 s sampling, `cold-start-series.jsonl`): footprint 4 MB at 2 s, then about
+100 MB per second to **848 MB at 10 s**, flat at 847–848 MB for about 7 s, then back to
**125 MB by 22 s**. Run 2: 849 MB when sampled at 11 s (peak 850 MB); 199 MB at 45 s, 154 MB at
52 s. No scroll, no refresh and no Similar request were needed, and Spotify.app was not running.
The owner's earlier 879 MB peak matches this startup spike, not a long-session effect.

**Heap at the plateau** (`heap-at-plateau.txt`): 11.3 million live nodes, 805 MB, against 579
thousand nodes and 71 MB in a normal state. Dominant types: 4.86 million `CFString` (400 MB),
2.44 million `NSMutableArray` (117 MB), 2.41 million `CFString` storage (88 MB), 1.29 million
Swift string storage (70 MB), 91 MB of `@autoreleasepool content`, 61 thousand
`NSSimpleRegularExpressionCheckingResult`, thousands of ICU `RegexMatcher` and `UnicodeSet`
objects. This is the signature of a large number of regular-expression string operations.

**Where it runs** (`sample` of the main thread, 3 s window at about 42–45 s of process life,
`main-thread-sample-excerpt.txt`): the main thread was CPU-bound (`ps` shows 100% CPU for the
first 45 s) inside:

```
closure #5 in MusicViewModel.refreshDiscovery()          MusicViewModel+DiscoveryState.swift:159
 SpotifyLibraryStore.discover(...)                        SpotifyLibraryStore+Discovery.swift:7
  MusicDiscoveryEngine.build(...)
   Sequence.contains(where:)  [closure #14]
    MusicDiscoveryIdentity.sameRecording(_:_:)            MusicDiscoveryIdentity.swift:53
     MusicDiscoveryIdentity.key(_:) / baseTitle(_:)       MusicDiscoveryIdentity.swift:26 / :20
      NSString replacingOccurrences(.regularExpression)   three patterns per call
```

**Cause (established):** Discovery v4 ranking runs at startup on the main actor and compares every
candidate with every seed through `sameRecording`. Each call recomputes `key()` and `baseTitle()`
for both tracks, and `baseTitle` compiles and runs three `NSRegularExpression` replacements. The
work is repeated per pair, with no precomputed key per track. The call sites are
`MusicDiscoveryRanking.swift:96` (candidates × seeds), `:135` (a quadratic dedupe loop over the
result so far) and `:201`. The main thread is therefore blocked for tens of seconds, which the
owner would see as a hang after launch.

**Inferred, not separately proven:** the 800 MB spike is the autoreleased `NSString` and
`NSArray` temporaries of these calls piling up inside one synchronous main-thread run that never
drains its autorelease pool (91 MB of pool content plus 4.9 million strings). The sample window
fell after the spike, so the memory-growth moment itself was not stack-sampled. Also unmeasured:
whether it began with 0.5.7 (Discovery v4) or earlier, because only the 0.5.7 build was run.

> **Plan-review code trace (verified against checkout):**
> - **Unit note:** `measure-memory.py` (`cold-start-series.jsonl`) logs binary **MiB** (`phys_footprint / 1048576`, peaking at `847.7 MiB` in Run 1, matching `vmmap`/`heap` `849.2M` in Run 2; `rusage.ru_maxrss` is decimal bytes `888.9 MB`). Keep all before/after comparisons in binary **MiB** from `footprint` / `vmmap -summary` / `measure-memory.py`.
> - **Why Discovery runs multiple times on cold start even in Video mode:** `PlayerSession` launches with `mode == .video` (`PlayerSession.swift:10`), while `MusicViewModel` restores persisted `selection.source == .similar` (`MusicViewModel+Library.swift:76-84`). During `spotify.onRestore` (`PlayerSession.swift:53-60`), `replaceStore` runs `refreshDiscovery()` #1 (empty), then `store.restore()` (`SpotifyLibraryStore.swift:75-96`) installs `preview` and `restored` while `store.isConnected == false`, triggering `acceptLibrary` → `refreshDiscovery()` #2 and #3 synchronously on `@MainActor` (`MusicViewModel+DiscoveryState.swift:126-135`). Unseeded (`seedTrack == nil`), `MusicDiscoveryRanking.swift:18` sets `seedIDs = library.likedTrackIDs` (thousands of tracks), causing the 10–17 s 849 MiB plateau before that synchronous turn returns and drains its autorelease pool (~22 s). Then `spotify.onConnected` → `syncLibrary()` (`PlayerSession.swift:68-91`, `MusicViewModel+Library.swift:145-150`) finishes `store.refresh()` and triggers `refreshDiscovery()` #4/#5 via `store.discover(...)` (`SpotifyLibraryStore+Discovery.swift:7,77`), which is the exact second CPU wave caught by `sample` at 42–45 s (`199 MiB` → `154 MiB`).
> - **Additional hot loops in `MusicCore` contributing to the spike and CPU block:**
>   1. `MusicDiscoveryIdentity.normalized(_:)` (`MusicDiscoveryIdentity.swift:4-11`) calls `.components(separatedBy: CharacterSet.alphanumerics.inverted)`, bridging Swift `String` through Objective-C `NSString` and allocating an autoreleased `NSArray`/`NSMutableArray` + `CFString` slices on every call — directly explaining the `2.44M NSMutableArray` (`117M`) and `4.86M CFString` (`400M`) in `heap-at-plateau.txt:34-35`.
>   2. `MusicDiscoveryIdentity.remixers(in:)` (`MusicDiscoveryIdentity.swift:61-77`) compiles `NSRegularExpression` on every call and runs inside nested `O(|catalog| × |collaborators|)` loops in `MusicDiscoveryLocalSignals.swift:45-59,91` and `SpotifyLibraryStore+DiscoverySignals.swift:212`.
>   3. `MusicDiscoveryLocalSignals.swift:60-67` (`likedSameDay`) runs in `O(|liked| × |seeds|)` (`O(|liked|²)` when unseeded because `seedIDs == likedTrackIDs`).
>   4. `MusicDiscoveryRanking.swift:68-81` calls `retainedHistory.contains` inside `for row in retainedHistory` (up to `20,000²` comparisons), and `:58-65` re-normalizes genres per track.
>   5. **`MusicDiscoveryRanking.swift:153-191,254-259` has an $O(N^3)$ diversity selection loop:** `while !remaining.isEmpty` calls `eligible.max`, which calls `marginal(..., selected: ordered)`, which scans all of `ordered` calling `MusicDiscoveryIdentity.sharesArtist` (allocating 4 `Set`s and re-normalizing artist names per pair). Even the 35-track unit test `MusicDiscoveryRegressionTests.seedRemixIsExcludedAndOneArtistCannotFillFirstThirty` currently takes **329 ms** out of the entire 329 ms `KinroxMusic` test run because of this loop.

## 4. Hypotheses

Results of the cold-start reproduction are marked. H1, H3 and H4 stay open for the long-session
growth (123 → 161 MB in 12 h) and the 150 MB baseline; none explains the startup spike.

| Marker | Meaning |
|---|---|
| Confirmed cause | Section 3a, regex work in Discovery ranking at startup. |
| Open | Not tested, or not needed for the peak. |

Code review found these candidates.

| # | Hypothesis | Basis | How to test |
|---|---|---|---|
| H1 | Scrolling long lists creates SwiftUI rows that stay alive. `LazyVStack` does not recycle rows, so memory grows with scroll distance through large libraries. | `LazyVStack` is used in `AlbumColumn` *(unused legacy v2 view)*, `AlbumsWorkspaceView`, `DiscoveryWorkspaceView` (plus `SourceColumn` and `QueueView`; `TrackTable` uses `List` with repeated rows); the heap holds tens of thousands of per-row style objects (`HelpStyleConfiguration`); 12 h growth. | Scroll the largest collection top to bottom while sampling; compare with a fixed row count. |
| H2 | Transient peak while the cached library is restored or a full refresh runs: batched JSON decoding plus the old and new catalog alive together. | `restore()` installs a preview, then the full snapshot; `refresh()` loads albums, playlists, liked and artists concurrently with `force: true`. | Sample a cold start and a forced refresh at 0.5 s resolution. |
| H3 | Discovery v4 responses or per-seed results retained longer than needed. | In-memory `SpotifyLibraryStore.discoveryCache` is bounded to 40 full `SpotifyDiscoveryData` entries (`SpotifyLibraryStore.swift:32`, `SpotifyLibraryStore+Discovery.swift:87`), even though SQLite `discovery_cache` already persists up to 256 entries for 24 h (`SpotifyCacheStore+Discovery.swift:37-71`). | Run Similar on many seeds, then measure. |
| H4 | Allocator retention: large short-lived buffers leave `MALLOC_SMALL` regions resident (323 MB virtual "empty", 67 MB compressed). | `vmmap` zone table; no call to `malloc_zone_pressure_relief` exists in the source. *(Note: much of the observed 323 MiB empty `MALLOC_SMALL` space in PID 78147 was left behind by the initial 849 MiB startup autorelease spike.)* | Compare footprint before and after a manual relief call in a debug build, after the startup peak is eliminated. |

Bounded already (not primary peak suspects): `searchCache` (10 entries, 60 s), disposable catalog
pruning from 0.5.6 (`SpotifyLibraryStore.swift:269-289`), and SQLite `mmap` streaming restore from
0.5.6.

## 5. Reproduction protocol for the peak

Do not run these on the owner's live session. They require a restart, so wait for the owner's
approval, or run them on an isolated build without disturbing a running `/Applications/Kinrox.app`.

1. Quit Kinrox (only when authorized); leave Spotify.app terminated (`AGENTS.md` Rule 10). Start a
   sampler first, using the local-only helper that is not included in the repository:
   `python3 -B docs/RESEARCHES/DONE/2026-11-12_07-05_Kinrox-memory-peak-evidence/measure-memory.py --pid <PID> --samples 1800 --interval 1`,
   writing to a new file.
2. Cold start; wait for the library restore; record physical footprint (`MiB`) every second.
3. Scenario A: scroll the largest album list and the track table end to end, then back.
4. Scenario B: force a library refresh (Settings → Spotify).
5. Scenario C: run Similar on 20 different seeds.
6. After each scenario, wait 60 s and record whether footprint returns to baseline.
7. Keep Kinrox playback volume at 0. Never touch the Mac system volume (`AGENTS.md` Rule 7).
8. At the highest reading, run `vmmap -summary` and `heap -sortBySize` immediately, then
   `leaks`. Save artifacts in the evidence directory beside this document.

Acceptance for the investigation: one scenario reproduces a footprint above 500 MiB and the
responsible category is named from `vmmap` or `heap`. *(Met in section 3a: cold-start Discovery
spike at 848–849 MiB.)*

## 6. Improvement plan

Execute in two phases within this pass: **Phase 1 (Steps 1–2 & Step 4)** delivers the mandatory
algorithmic, concurrency, lifecycle, cache-bounding, and repeated-row `.hoverHelp` fixes with
deterministic regressions; **Phase 2 (allocator relief in Step 2b)** applies only if live
measurement confirms net physical-footprint benefit without latency regression. Items removed
during plan review (Steps 3 and 5 below) must **not** be implemented because they contradict the
codebase or explicit owner decisions.

### Step 1 — Eliminate the 849 MiB startup peak, 45 s main-thread hang, and H3 over-retention (Mandatory)

1. **1a. Pure-Swift tokenization, static regexes with fast-paths, and `TrackIdentity` (`Packages/KinroxMusic/Sources/MusicCore/MusicDiscoveryIdentity.swift`):**
   - Replace `.components(separatedBy: CharacterSet.alphanumerics.inverted)` inside
     `normalized(_:)` (`:4-11`) with pure-Swift Unicode scalar/character word splitting after
     `folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)`. Do **not**
     call `NSString`/`CharacterSet` splitting APIs that bridge to `NSArray`/`NSMutableArray` and
     allocate millions of autoreleased `CFString` slices.
   - Compile the three `baseTitle` patterns (`:17-23`) and the `remixers(in:)` pattern (`:61-65`)
     once as `private static let` `NSRegularExpression` instances, gated behind cheap Swift
     character checks:
     - `baseTitle(_:)` skips regex execution entirely when the title contains none of `(`, `[`,
       `-`, `–`, `—`, returning `normalized(track.title)` directly.
     - `remixers(in:)` skips regex execution entirely unless a case-insensitive check finds
       `"remix"`, `"edit"`, or `"mix"` in `title`.
   - Define an internal Sendable `TrackIdentity` struct computed at most once per `track.id` per
     pass, storing:
     - `id: String`
     - `isrc: String?` (`MusicDiscoveryIdentity.isrc(track)`)
     - `baseTitle: String`
     - `key: String` (`"\(primaryArtistNorm)|\(baseTitle)"`, matching `MusicDiscoveryIdentity.key`)
     - `primaryArtistKey: String` (`normalized(track.artists.first?.name ?? track.id)`)
     - `artistIDs: [String]` (non-empty `artist.id`s)
     - `artistNormNames: [String]` (non-empty `normalized(artist.name)`s, preserving order/set)
     - `isVarious: Bool` (`track.artists.first.map(isVariousArtists) ?? false`)
     - `stableHash: UInt64` (`stableHash(track.id)`)
     - `recordingTokens: [String]`: exact equivalence tokens for `sameRecording(_:_:)` (`:51-55`):
       1. `"id:" + track.id`
       2. `"isrc:" + isrc` (when `isrc != nil`)
       3. `"key:" + key`
       4. `"aid:" + aid + "\u{1F}" + baseTitle` for each non-empty `aid` in `artistIDs`
       5. `"aname:" + aname + "\u{1F}" + baseTitle` for each non-empty `aname` in `artistNormNames`
     - **Equivalence requirement:** Two tracks satisfy `MusicDiscoveryIdentity.sameRecording(lhs, rhs)`
       if and only if their `recordingTokens` intersect. Using `key(track)` alone is **incorrect**
       because `sameRecording` also matches swapped artist billing and featured artist credits via
       `baseTitle(lhs) == baseTitle(rhs) && sharesArtist(lhs, rhs)` (verified by
       `MusicDiscoveryRankingTests.variantsShareIsrcOrSwappedBillingAndMergeReasons`).
   - Keep all existing `public static` methods on `MusicDiscoveryIdentity` intact (backed by the
     pure-Swift helpers) so external callers (`MusicViewModel+Radio.swift`,
     `MusicViewModel+RemoteSimilar.swift`, `SpotifyLibraryStore+DiscoverySignals.swift`,
     `SpotifyLibraryStore+MetaBrainz.swift`, and `MusicDiscoveryRankingTests`) remain source- and
     behavior-compatible.

2. **1b. Replace quadratic and cubic loops in `MusicDiscoveryLocalSignals` and `MusicDiscoveryRanking` (`Packages/KinroxMusic/Sources/MusicCore/MusicDiscoveryLocalSignals.swift`, `MusicDiscoveryRanking.swift`, and `PlayerMac/PlayerMac/Music/Spotify/SpotifyLibraryStore+DiscoverySignals.swift`):**
   - **`MusicDiscoveryLocalSignals.swift`:**
     - Build a `[String: TrackIdentity]` cache (plus lazy/fast-path normalized remixers per track)
       once per `build(...)` call.
     - Replace the nested `O(|catalog| × |collaborators|)` loop (`:45-59`) with a single pass over
       `catalog.tracks` checking pre-indexed collaborator/remixer normalized names in a
       `[String: (display: String, kind: MusicDiscoveryReasonKind)]` dictionary returned by
       `collaborators(...)` (`:76-100`).
     - Replace the `O(|liked| × |seeds|)` `likedSameDay` scan (`:60-67`) — which degrades to
       `O(|liked|²)` when unseeded (`seedIDs == library.likedTrackIDs`) — by sorting seed
       `addedAt` timestamps (`TimeInterval`) once and binary-searching (`±7 * 86_400` s window) for
       each non-seed liked track (`!seedIDs.contains(liked.id)`).
   - **`MusicDiscoveryRanking.swift`:**
     - Build a single `[String: TrackIdentity]` lookup table covering seeds, `catalog.tracks`,
       `signals.map(\.track)`, and `compilationAlbums` tracks, plus `seedRecordingTokens: Set<String>`
       as the union of `recordingTokens` across `seeds`.
     - Replace `seeds.contains(where: { sameRecording(...) })` at `:96` and `:201` with $O(1)$
       token lookup against `seedRecordingTokens`.
     - Precompute `normalizedSelectedGenre = selectedGenre.map(MusicDiscoveryIdentity.normalized)`
       once before `:58-65` and normalize `genres` once into a `Set<String>`.
     - Replace the $O(H^2)$ nested `retainedHistory.contains` inside `for row in retainedHistory`
       (`:68-81`, up to `20,000²` operations) with a prebuilt `Set<CompletedSessionTrack>` keyed by
       `(sessionID: UUID, trackID: String)`.
     - Replace the $O(N^2)$ `deduped` scan and `remove(at:)` shifts (`:132-148`) with an append-only
       `slots: [Candidate?]` array and `tokenSlots: [String: Set<Int>]`:
       - Collect matching live slot indices across `identity(candidate.item.track).recordingTokens`,
         sorted ascending (`matches`).
       - If `matches.isEmpty`, append `candidate` and register its slot under its `recordingTokens`.
       - Otherwise let `first = matches[0]`, unregister the old `recordingTokens` of every slot in
         `matches`, set `slots[idx] = nil` for `matches.dropFirst()`, compute `merged` and `best`
         using the exact existing `merge` and `preferred` closures, store `slots[first] = merged`,
         and register `first` under `identity(merged.item.track).recordingTokens`. Compact `slots`
         with `compactMap { $0 }` afterward so output order, chosen variant track, scores, and
         merged reasons remain 100% identical to the reference loop.
     - **Replace the $O(N^3)$ diversity loop (`:153-191` and `marginal` at `:254-259`):**
       - `marginal(_:selected:)` multiplies `item.score` by `0.8` iff any already-selected item in
         `ordered` shares a non-empty `artist.id` or normalized artist name with `item.track`.
       - Maintain `selectedArtistIDs: Set<String>` and `selectedArtistNames: Set<String>`
         incrementally as each winning item is appended to `ordered`, and precompute per-candidate
         `primaryArtistKey`, `seedArtistNormNames: [String]`, `artistIDs`, `artistNormNames`, and
         `stableHash` alongside an `isAlive` boolean array (eliminating `remaining.remove(at:)`
         element shifts). `marginal` becomes $O(1)$ per candidate with zero allocations and exact
         tie-breaking (`precedes`).
   - **`SpotifyLibraryStore+DiscoverySignals.swift:208-215`:** Avoid repeated normalization in
     `creditsCollaborator(track:name:)` using the fast-path `remixers(in:)`.

3. **1c. Run async Discovery computation off `@MainActor` inside `autoreleasepool` (`PlayerMac/PlayerMac/Music/Spotify/SpotifyLibraryStore+Discovery.swift`, `SpotifyLibraryStore+DiscoverySignals.swift`, `PlayerMac/PlayerMac/Music/MusicViewModel+Radio.swift`):**
   - In `SpotifyLibraryStore.discover(...)` (`SpotifyLibraryStore+Discovery.swift:7-81`), capture
     Sendable value snapshots (`catalog`, `library`, `playHistory`, `value`, `now()`,
     `sessionGeneration`, `consentGeneration`) on `@MainActor`, run `MusicDiscoveryEngine.build(...)`
     off `@MainActor` via a cancellable `Task.detached(priority: .userInitiated)` (wrapped in
     `autoreleasepool { ... }` on macOS), and re-verify `!isClosed`, `session == sessionGeneration`,
     `consent == consentGeneration`, and `!Task.isCancelled` on `@MainActor` before returning.
   - Apply the same value-snapshot + `Task.detached` + `autoreleasepool` pattern to
     `localDiscoverySignals(...)` in `SpotifyLibraryStore+DiscoverySignals.swift:89-93,124-128` and
     to the radio refill `MusicDiscoveryEngine.build(...)` in `MusicViewModel+Radio.swift:66-78`
     (guarded by `radioGeneration` and `listenBrainzEnabled` before mutating `queue`).

4. **1d. Prevent cold-start Discovery storm in Video mode while preserving synchronous `MusicViewModel` contracts (`PlayerMac/PlayerMac/App/PlayerSession.swift`, `PlayerMac/PlayerMac/Music/MusicViewModel.swift`, `MusicViewModel+DiscoveryLifecycle.swift`, `MusicViewModel+Library.swift`, `SpotifyLibraryStore.swift`):**
   - **Contract invariant:** Existing unit tests (`DiscoveryReviewModelTests.swift:244-271,300-314`,
     `DiscoveryViewModelTests.swift:74-92`) instantiate standalone `MusicViewModel(store:defaults:)`
     without mounting `DiscoveryWorkspaceView` and synchronously assert `model.discoverySnapshot != nil`
     immediately after `init`, `replaceStore`, `openSimilar`, `notInterested`, and
     `undoNotInterested`. Do **not** break those synchronous contracts by gating `MusicViewModel`
     on SwiftUI `.onAppear` alone or leaving `discoverySnapshot == nil` when `isWorkspaceActive` is
     `true`.
   - Add `private(set) var isWorkspaceActive = true` (default `true` so standalone `MusicViewModel`
     callers/tests keep synchronous local snapshot construction — now fast via Steps 1a–1b) and
     `var discoveryNeedsRefresh = false` on `MusicViewModel`, managed by
     `func setWorkspaceActive(_ active: Bool)` in `MusicViewModel+DiscoveryLifecycle.swift`.
   - In `PlayerSession` (`PlayerSession.swift:10,43-45`), call `music.setWorkspaceActive(mode == .music)`
     during `init` (`false` because `mode` starts at `.video`) and inside `mode.didSet`.
   - When `!isWorkspaceActive`, automatic startup/background triggers (`MusicViewModel.init`,
     `replaceStore`, `acceptLibrary`, `syncLibrary`) must **not** call `refreshDiscovery()`; they
     only set `discoveryNeedsRefresh = true`. When `setWorkspaceActive(true)` runs (user switches
     to `mode == .music`) and `selection.source == .similar`, if
     `discoveryNeedsRefresh || discoverySnapshot == nil || (!discoveryHasConnectedRefresh && store.isConnected)`,
     clear `discoveryNeedsRefresh` and call `refreshDiscovery()` once. Explicit user/API actions
     (`openSimilar`, `select(.similar)`, `notInterested`, `undoNotInterested`, `selectDiscoveryMode`,
     `selectDiscoveryGenre`, `setDiscoveryHideLiked`) always refresh immediately.
   - Verify iPhone Remote `startSimilarFromCurrent()` (`MusicViewModel+RemoteSimilar.swift:13-26`)
     remains unaffected even when Mac `mode == .video` (it seeds radio from `queue.current` via
     `refillDiscoveryRadioIfNeeded`, not `discoverySnapshot`).
   - **Coalesce `SpotifyLibraryStore.restore()` notifications (`SpotifyLibraryStore.swift:75-97`):**
     Currently `install(preview)` (`:87`) and `install(restored)` (`:90`) both fire `onChange?()`
     while `isRestoring == true`, and `playHistory` (`:91-95`) loads *after* `install(restored)`
     without notifying `onChange?()`. Keep `isRestoring == true` during `install(preview)` so
     `acceptLibrary` skips building Discovery on the partial preview, load `restored` and
     `playHistory`, set `isRestoring = false`, and then fire `onChange?()` once with the complete
     restored catalog + `playHistory`. Also guard `MusicViewModel.syncLibrary()`
     (`MusicViewModel+Library.swift:145-150`) so it does not trigger a duplicate `refreshDiscovery()`
     when `acceptLibrary(store)` on line 145 already started `isDiscovering`.

5. **1e. Tighten in-memory `discoveryCache` for H3 (`PlayerMac/PlayerMac/Music/Spotify/SpotifyLibraryStore.swift:32`, `SpotifyLibraryStore+Discovery.swift:83-89`):**
   - Lower the in-memory `SpotifyLibraryStore.discoveryCache` limit from `40` to `12` entries.
     `SpotifyCacheStore` already keeps up to 256 `SpotifyDiscoveryData` blobs in SQLite for 24 h
     (`SpotifyCacheStore+Discovery.swift:37-71`), so revisiting older seeds reloads from local
     SQLite without hitting Spotify or MetaBrainz APIs.

### Step 2 — Release disposable memory when leaving Discovery / Music or closing the window

1. **2a. Trim disposable view-model and store state (`MusicViewModel+DiscoveryLifecycle.swift`, `MusicViewModel+Browsing.swift`, `SpotifyLibraryStore.swift`):**
   - SwiftUI already unmounts inactive branches (`PlayerRootView.swift:54`, `MusicView.swift:21-29`).
     Release the backing disposable model state on transitions:
     - When `selection.source` leaves `.similar` (`MusicViewModel+Browsing.swift:8-34`), cancel any
       in-flight UI `browsingTask` for Discovery and set `discoverySnapshot = nil` (retaining lightweight
       `discoverySeedHistory` metadata so returning to `.similar` rebuilds immediately from cached
       data).
     - When `setWorkspaceActive(false)` runs (`PlayerSession.mode` switches from `.music` to
       `.video`), cancel any in-flight Discovery `browsingTask`, release `discoverySnapshot = nil`
       (setting `discoveryNeedsRefresh = true` if `selection.source == .similar`), clear
       `discoveredThemePlaylists` when `selectedPlaylistTheme == nil`, clear `expandedAlbumCardIDs`
       when `selection.source != .albums`, and trim `SpotifyLibraryStore.searchCache` plus
       in-memory `discoveryCache` down to at most the active seed entry.
     - **Invariants:** Never alter `queue`, `playHistory`, `PlaybackCoordinator`, `SoloistEngine`,
       or `RemoteMusicBridge` on mode switch or window close (`AGENTS.md` §3.1: view switching
       alone never pauses audio, and LAN remote state stays consistent across mode switches and
       window closure per 0.5.3).

2. **2b. Conditional allocator relief for H4 (`PlayerWindowController.swift` / `AppDelegate.swift`):**
   - Only on low-frequency idle transitions — window close (`windowWillClose`), window miniaturize,
     `NSApplication.didResignActiveNotification`, or switching `PlayerSession.mode` from `.music` to
     `.video` after Step 2a releases disposable buffers — invoke `malloc_zone_pressure_relief(nil, 0)`
     (`<malloc/malloc.h>`). Never call it on a timer, scroll event, or track transition. Keep this
     call only if `vmmap -summary` / `footprint` confirms non-negative physical-footprint savings
     and zero UI hitching.

### Step 3 — Artwork and `IOSurface` (Removed / Already Shipped)

- **Do not implement artwork thumbnail decoding or `NSCache` limits:** Kinrox has zero music or
  video cover-art URLs, downloads, image decoders, or `NSCache` instances (`AGENTS.md` §2.3
  explicitly excludes cover art; `NowPlayingController.swift:24` uses only bundled `KinroxLogo`).
- **Do not re-implement `VideoLayer` backing release:** Unmounting `VideoView` when idle and calling
  `videoLayer.releaseBacking()` in Music mode were already shipped in `0.5.6`
  (`PlayerView.swift:33-34`, `VideoView.swift:25-26`, `VideoLayer.swift:39-50`).
- **`IOSurface` (22–25.8 MiB) status:** `vmmap-at-plateau.txt:40` shows `IOSurface` was `25.8 MiB`
  (10 regions) 11 s after launch while still on the Video Welcome screen — standard macOS 26 Retina
  window + Liquid Glass compositor surfaces. Do not modify `MPVKit` CGL context lifecycle in this
  task; `MPVKit` internals must remain untouched.

### Step 4 — Lighter SwiftUI rows via lazy `.hoverHelp` (`DiscoveryTrackRow.swift`, `SourceColumn.swift`, `AlbumsWorkspaceView.swift`, `QueueView.swift`)

- `TrackTable.swift:145` and `TrackMetadataPopovers.swift:35,90` already switched to conditional
  `.hoverHelp(..., active: hovered)` in `0.5.6`, and `AlbumColumn.swift` is unused legacy code.
- Convert the remaining unconditional `.help(...)` modifiers inside **repeated list rows** (the
  source of the ~27 thousand `HelpStyleConfiguration` allocations in section 2) to
  `.hoverHelp(..., active: ...)`:
  1. `PlayerMac/PlayerMac/Music/UI/DiscoveryTrackRow.swift:150,166,202` (4 `.help` modifiers per
     row while `actions` stays mounted at `opacity == 0`): gate with
     `active: hovered || menuPresented`.
  2. `PlayerMac/PlayerMac/Music/UI/SourceColumn.swift:245,284,303`: gate row/pill `.help` modifiers
     with row hover state (`SourceColumn.swift` is **486 lines** — keep total file length **≤ 500
     lines** per `AGENTS.md` Rule 5).
  3. `PlayerMac/PlayerMac/Music/UI/AlbumsWorkspaceView.swift:264`: gate album-card favorite button
     `.help` with card hover state.
  4. `PlayerMac/PlayerMac/Music/UI/QueueView.swift:316`: gate queue-row remove button `.help` with
     `hoveredID == item.id`.
- **Guardrails:**
  - Leave single-instance window/header/transport `.help(...)` modifiers unchanged.
  - **Do not replace per-row `Button` controls with tap gestures:** removing `Button` breaks macOS
    keyboard focus, VoiceOver accessibility actions, and `Menu` popover anchoring
    (`DiscoveryTrackRow.swift:85`).
  - Defer any `NSTableView` rewrite of `TrackTable.swift` and further `MusicCatalog` layout changes
    (`0.5.6` already interns artist arrays and album strings in `MusicCatalog.swift:122-137`) unless
    post-fix Scenario A measurements still show material unbounded growth.

### Step 5 — Sparkle `Autoupdate` and Soloist helper (No Code Changes; Soloist `argv` Change Prohibited)

- **Sparkle `Autoupdate` (7.4 MiB):** Explained in section 3 note 2 (`SparkleUpdater.swift:78-91`,
  `PlayerMac/Info.plist:95-102`): PID 78147 ran `0.5.7` after `0.5.8` was published on the appcast,
  so Sparkle held an active gentle-reminder session awaiting user attention while Music mode was
  open. No Sparkle code change is needed; on an up-to-date build with no pending appcast update,
  `Autoupdate` does not stay resident.
- **Do not change Soloist `--api-key` passing:** Kinrox's own `KinroxSoloistHost` reaper
  (`PlayerMac/SoloistHost/main.c:29-53`) already takes **zero** secrets in `argv` (only PID, binary
  path, and start time). The `--api-key` flag in `SoloistProcessSupervisor.swift:232` is passed to
  Spotify's closed-source signed/notarized `soloist` binary (`com.spotify.soloist`), which has no
  stdin/env/FD key mechanism and cannot be patched or re-signed. Passing the user's personal key via
  `soloist` `argv` is an explicit **Owner Decision (2026-11-03, G0)** documented in
  `docs/runbooks/SOLOIST-VERIFICATION.md:17-19,58` and disclosed across all 30 locales of
  `SpotifyConnection.<locale>.json`. Leave `SoloistProcessSupervisor.swift` (495 lines) and
  Spotify's crashpad handler (3.7 MiB) untouched.

### Step 6 — Regression tests and runbook note

- Add deterministic automated regressions in `MusicCoreTests` and `PlayerMacTests` (section 6b)
  instead of multi-hour blocking CI soak tests.
- Record measured cold-start and Scenario A–C physical footprints in section 8 of this document (and
  update `docs/runbooks/SPOTIFY-PERFORMANCE-VERIFICATION.md` only if new live Release measurements
  are captured).

### 6a. Relevant files and 500-line ceiling check (`AGENTS.md` Rule 5)

| File | Current lines | Planned changes |
|---|---:|---|
| `Packages/KinroxMusic/Sources/MusicCore/MusicDiscoveryIdentity.swift` | 84 | Pure-Swift `normalized`, static compiled regexes + fast-paths, `TrackIdentity` with exact `recordingTokens`. |
| `Packages/KinroxMusic/Sources/MusicCore/MusicDiscoveryLocalSignals.swift` | 107 | `TrackIdentity` reuse, $O(1)$ collaborator/remixer dictionary lookup, binary-searched `likedSameDay`. |
| `Packages/KinroxMusic/Sources/MusicCore/MusicDiscoveryRanking.swift` | 278 | `TrackIdentity` table, $O(1)$ `seedRecordingTokens`, completed-history `Set`, indexed tombstone `deduped`, $O(1)$ incremental `marginal` artist sets in diversity loop. Keep ≤ 500 lines (extract helper file in `MusicCore` if needed). |
| `Packages/KinroxMusic/Tests/MusicCoreTests/MusicDiscoveryRankingTests.swift` | 198 | Exact-equivalence regression comparing fast path against reference `sameRecording`/diversity edge cases (ISRC, swapped billing, remixer credits, multi-slot transitive merge). |
| `Packages/KinroxMusic/Tests/MusicCoreTests/MusicDiscoveryRegressionTests.swift` | 43 | 20,000-track seeded (5 seeds) and unseeded (5,000 liked tracks + 5,000 play-history entries) performance & determinism regression. |
| `PlayerMac/PlayerMac/App/PlayerSession.swift` | 147 | Sync `music.setWorkspaceActive(mode == .music)` on `init` and `mode.didSet`; trigger optional Step 2b relief on `.music` → `.video`. |
| `PlayerMac/PlayerMac/Music/MusicViewModel.swift` | 380 | `isWorkspaceActive = true` and `discoveryNeedsRefresh = false` stored properties only (put methods in `+DiscoveryLifecycle.swift` to stay well under 500 lines). |
| `PlayerMac/PlayerMac/Music/MusicViewModel+DiscoveryLifecycle.swift` | 84 | `setWorkspaceActive(_:)`, idle Discovery/theme/album-expansion state trimming. |
| `PlayerMac/PlayerMac/Music/MusicViewModel+Browsing.swift` | 268 | Clear `discoverySnapshot` / cancel Discovery UI `browsingTask` when navigating away from `.similar`. |
| `PlayerMac/PlayerMac/Music/MusicViewModel+Library.swift` | 234 | Respect `isWorkspaceActive` and `store.isRestoring` in automatic `refreshDiscovery()` call sites; eliminate duplicate `syncLibrary()` trigger. |
| `PlayerMac/PlayerMac/Music/MusicViewModel+Radio.swift` | 157 | Off-`@MainActor` `Task.detached` + `autoreleasepool` for radio refill `MusicDiscoveryEngine.build`. |
| `PlayerMac/PlayerMac/Music/Spotify/SpotifyLibraryStore.swift` | 310 | Coalesce `restore()` so `isRestoring` clears after `playHistory` loads before final `onChange?()`; cap `discoveryCache` at 12; add idle cache trim helper. |
| `PlayerMac/PlayerMac/Music/Spotify/SpotifyLibraryStore+Discovery.swift` | 195 | Off-`@MainActor` `Task.detached` + `autoreleasepool` for `MusicDiscoveryEngine.build`, 12-entry `discoveryCache` bound, generation/cancellation checks. |
| `PlayerMac/PlayerMac/Music/Spotify/SpotifyLibraryStore+DiscoverySignals.swift` | 216 | Off-`@MainActor` `Task.detached` + `autoreleasepool` for `localDiscoverySignals`; fast collaborator check. |
| `PlayerMac/PlayerMac/Music/UI/DiscoveryTrackRow.swift` | 274 | Convert 4 repeated-row `.help` modifiers to `.hoverHelp(..., active: hovered || menuPresented)`. |
| `PlayerMac/PlayerMac/Music/UI/SourceColumn.swift` | **486** | **Near 500-line ceiling:** convert repeated-row `.help` at `:245,284,303` to `.hoverHelp` without exceeding 500 lines (extract subview if needed). |
| `PlayerMac/PlayerMac/Music/UI/AlbumsWorkspaceView.swift` | 293 | Convert card favorite `.help` (`:264`) to `.hoverHelp`. |
| `PlayerMac/PlayerMac/Music/UI/QueueView.swift` | 373 | Convert row remove `.help` (`:316`) to `.hoverHelp(..., active: hoveredID == item.id)`. |
| `PlayerMac/PlayerMac/Player/PlayerWindowController.swift` | 254 | Conditional `malloc_zone_pressure_relief(nil, 0)` on window close / miniaturize / resign active (if retained after measurement). |
| `PlayerMac/PlayerMacTests/DiscoveryReviewModelTests.swift` | 329 | Regressions for cold-start `.video` mode deferral (`PlayerSession`), single build after `restore()` + `playHistory`, and wakeup on `mode = .music`. |

### 6b. Verification and acceptance criteria

The reviewed protocol below is preserved as history. The 2026-11-12 orchestrator continuation
clarifies the Debug/Release/MainActor timing gates and authorizes the limited live session; those
explicit answers take precedence over the earlier wording. Physical-iPhone builds use the wired
device and existing signing, as required by the execution prompt, rather than the generic example.

Follow `docs/runbooks/RUNBOOK-TASK-TESTS.md` and `AGENTS.md` Rules 5, 6, 7, 10, and 11 (**never**
launch `iOS Simulator` or run `xcodebuild` with an `iOS Simulator` destination; never modify Mac
system volume; never launch `Spotify.app`; never overwrite `/Applications/Kinrox.app`).

1. **Red-then-green automated regressions (Mandatory):**
   - **`MusicCoreTests` scale & equivalence regression:**
     - Synthetic catalog of **20,000 tracks** (varied ISRCs, remixes/live/remastered suffixes,
       featured/swapped-billing artists, playlists, compilations) with **5 seeds**, plus a second
       **unseeded cold-start case** (`seedTrack == nil`, **5,000 `likedTrackIDs`**, **5,000
       `MusicPlayHistoryEntry` rows**).
     - Assert `MusicDiscoveryEngine.build(...)` completes in **< 250 ms** in `swift test` (down from
       tens of seconds; also verify existing 35-track
       `seedRemixIsExcludedAndOneArtistCannotFillFirstThirty` drops from ~329 ms to **< 15 ms**).
     - On a multi-hundred-track corpus with tricky variants (matching ISRC across different titles,
       swapped artist billing, `[2011 Remaster]`, `(Dawn Remix)` vs `(Club Mix)`, transitive 3-way
       variant merge), assert exact output equality against the pre-change specification.
   - **`PlayerMacTests` lifecycle & deferral regressions:**
     - With persisted `BrowserSelection(source: .similar)`, verify `PlayerSession` in default
       `mode == .video` performs **zero** Discovery builds across `replaceStore`, `store.restore()`
       (both `preview` and `restored`), and `syncLibrary()`, then builds Discovery **once** (with
       restored `playHistory` included) when `session.mode` switches to `.music`.
     - Verify standalone `MusicViewModel(store:defaults:)` tests (`DiscoveryViewModelTests`,
       `DiscoveryReviewModelTests`) continue to pass unchanged.
     - Verify switching `session.mode` back to `.video` releases `discoverySnapshot` without
       stopping active queue playback or mutating `RemoteMusicBridge` state, and switching back to
       `.music` restores `discoverySnapshot`.

2. **Exact test & build commands (Mandatory):**
   ```sh
   # 1. Shared packages
   swift test --package-path Packages/KinroxMusic
   swift test --package-path Packages/RemoteProtocol

   # 2. Regenerate Xcode projects if any file was added/removed (check before/after)
   xcodegen generate --spec PlayerMac/project.yml

   # 3. Mac Debug unit tests (portable libmpv auto-prepared if needed per RUNBOOK-TASK-TESTS.md)
   xcodebuild -project PlayerMac/PlayerMac.xcodeproj \
     -scheme PlayerMac \
     -configuration Debug \
     -destination 'platform=macOS,arch=arm64' \
     test

   # 4. Mac Release build for realistic memory/CPU profiling
   xcodebuild -project PlayerMac/PlayerMac.xcodeproj \
     -scheme PlayerMac \
     -configuration Release \
     -destination 'platform=macOS,arch=arm64' \
     build

   # 5. Generic iOS build check ONLY if shared packages changed (NO iOS Simulator per AGENTS.md Rule 11)
   xcodebuild -project RemoteiOS/RemoteiOS.xcodeproj \
     -scheme RemoteiOS \
     -configuration Debug \
     -destination 'generic/platform=iOS' \
     CODE_SIGNING_ALLOWED=NO \
     build

   # 6. Localization & line-count checks
   python3 Scripts/check-localization.py
   ```
   Also verify `wc -l` ≤ 500 on every modified source/test file (`AGENTS.md` Rule 5) and zero
   compiler warnings in touched targets.

3. **Live memory & latency verification boundaries:**
   - **Do not kill or restart a running `/Applications/Kinrox.app` session belonging to the owner**
     without explicit permission. Check `pgrep -fl Kinrox` first.
   - If no live user session is running (or in an isolated Release launch that does not touch
     `/Applications/Kinrox.app`, with `Spotify.app` terminated and Kinrox volume at `0`), run the
     Release binary from DerivedData under `measure-memory.py` (`1 s` interval, `60 s` cold start +
     Music mode switch + Scenarios A–C if connected library is available) plus `vmmap -summary` /
     `heap -sortBySize` / `leaks`.
   - **Targets (comparable conditions on the same library):**
     - Cold-start `phys_footprint_peak` **< 250 MiB** (vs **848–849 MiB** baseline in section 3a).
     - Zero main-thread hang > 250 ms during cold start or switching to `Similar`.
     - Existing Soloist & Spotify performance bounds in `AGENTS.md` preserved (Soloist ≤ 120 MiB
       physical footprint, ≤ 3% of one core, cold startup p95 ≤ 4 s, warm ≤ 3 s, Next ≤ 3.2 s;
       waived physical sleep/reboot and macOS 14 runtime checks remain waived).
   - If `/Applications/Kinrox.app` is actively running in the owner's session, record a synthetic
     20k-track `phys_footprint` / `autoreleasepool` benchmark measurement in `PlayerMacTests` /
     `MusicCoreTests` and document the honest live-session boundary in section 8 so the owner can
     run section 5 at convenience.

Estimate, not a promise: Step 1 eliminates the 849 MiB startup spike and 45 s hang completely;
Steps 2 and 4 trim idle and per-row SwiftUI overhead (especially the ~27k `HelpStyleConfiguration`
objects and cached `SpotifyDiscoveryData` graphs). A Rust rewrite remains out of scope per
`AGENTS.md` (native Swift/SwiftUI).

## 7. Open questions and unresolved assumptions

- **Historical origin (non-blocking):** Discovery v4 (`MusicDiscoveryIdentity`,
  `MusicDiscoveryRanking`, `MusicDiscoveryLocalSignals`) landed in `0.5.7` (2026-11-10), which
  matches the introduction of `sameRecording` regex scanning and the $O(N^3)$ diversity pass. A
  separate `0.5.6` binary comparison is optional and not required to ship the fix.
- **Cold-start sub-second attribution (resolved by code review):** Both `MusicDiscoveryIdentity.normalized`
  (`CharacterSet` `NSArray` bridging), `baseTitle` / `remixers` (`NSRegularExpression`), and
  `MusicDiscoveryRanking`'s quadratic/cubic loops execute inside the same synchronous `@MainActor`
  `refreshDiscovery()` call during `store.restore()` (`SpotifyLibraryStore.swift:90`), explaining
  the single un-drained autorelease pool.
- **Long-session growth (H1, H4):** Scenario A/B/C live measurements after Step 1 + Step 2 + Step 4
  will determine whether any further `TrackTable` virtualization (`NSTableView`) is warranted in a
  follow-up research pass. No owner decision blocks implementation.

## 8. Results

- 2026-11-12: cold-start peak reproduced twice (848 and 849 MiB, `/Applications/Kinrox.app` 0.5.8
  build 18 per `vmmap`/`heap` headers; earlier 14 h session PID 78147 ran 0.5.7 build 17); cause
  located in `MusicDiscoveryIdentity` / `MusicDiscoveryRanking` / `MusicDiscoveryLocalSignals` and
  cold-start `refreshDiscovery()` triggers (section 3a). At that measurement, no application code had changed.
- At the initial-stage handoff, live scenarios and the timing-contract question remained open.
  The continuation below records the orchestrator answer, final implementation, passing gates,
  live measurements, and explicit diagnostic/manual limitations.

## Model log

### 2026-11-12 07:38 Europe/Moscow — Gemini 4 Carbon (High) — `plan_review`

- **Result:** Plan reviewed, corrected against current `main`, and ready for implementation (no
  owner decision blocking).
- **Findings:**
  - **CRITICAL 1 — Prohibited Soloist `--api-key` `argv` change in original Step 5**
    (`PlayerMac/PlayerMac/Music/Soloist/SoloistProcessSupervisor.swift:229-235`,
    `PlayerMac/SoloistHost/main.c:29-53`, `docs/runbooks/SOLOIST-VERIFICATION.md:17-19,58`):
    `KinroxSoloistHost` already receives no secrets in `argv`. `--api-key` is passed to Spotify's
    closed-source signed/notarized `soloist` binary, which supports no non-`argv` secret channel and
    cannot be modified or re-signed; passing the personal key via `soloist` `argv` was explicitly
    approved by the owner on 2026-11-03 (decision G0) and disclosed in 30 locales. Attempting to
    remove `--api-key` from `argv` would break standalone Spotify playback.
  - **CRITICAL 2 — Non-existent artwork / `NSCache` pipeline and duplicate 0.5.6 `VideoLayer` work in original Step 3**
    (`Packages/KinroxMusic/Sources/MusicCore/MusicModels.swift`,
    `PlayerMac/PlayerMac/NowPlaying/NowPlayingController.swift:24`,
    `PlayerMac/PlayerMac/Player/PlayerView.swift:33-34`,
    `PlayerMac/PlayerMac/MPVKit/VideoView.swift:25-26`):
    Kinrox does not fetch, decode, or cache album/video artwork (`AGENTS.md` §2.3), has zero
    `NSCache` usage, and already releases `VideoLayer` OpenGL backing in Music mode since `0.5.6`.
    `vmmap-at-plateau.txt:40` confirms the 25.8 MiB `IOSurface` footprint exists in Video Welcome
    mode before Music UI mounts (WindowServer/Liquid Glass window backing).
  - **CRITICAL 3 — Incomplete `MusicCore` hotspot diagnosis ($O(N^3)$ diversity loop, `CharacterSet` ObjC bridging, `remixers`/`likedSameDay`/history quadratic scans) and `sameRecording` equivalence hazard in original Steps 1a–1b**
    (`Packages/KinroxMusic/Sources/MusicCore/MusicDiscoveryIdentity.swift:4-77`,
    `MusicDiscoveryLocalSignals.swift:45-67`,
    `MusicDiscoveryRanking.swift:58-81,96,132-191,201,254-259`):
    1. `normalized(_:)` (`:4-11`) calls `.components(separatedBy: CharacterSet.alphanumerics.inverted)`,
       bridging through Objective-C to allocate the `2.44M NSMutableArray` and `4.86M CFString`
       nodes seen in `heap-at-plateau.txt:34-35`.
    2. `MusicDiscoveryRanking.swift:153-191,254-259` runs an **$O(N^3)$ diversity selection loop**
       (`while !remaining.isEmpty` → `eligible.max` → `marginal` → `selected.contains { sharesArtist }`),
       missed by the original plan; even the 35-track test
       `MusicDiscoveryRegressionTests.seedRemixIsExcludedAndOneArtistCannotFillFirstThirty` takes
       329 ms today because of it.
    3. `MusicDiscoveryLocalSignals.swift:45-67` (`remixers(in:)` regex recompilation per call +
       `O(|liked| × |seeds|)` `likedSameDay`, which becomes $O(|\text{liked}|^2)$ when unseeded) and
       `MusicDiscoveryRanking.swift:68-81` ($O(H^2)$ `retainedHistory.contains`) also scale
       quadratically on large libraries.
    4. Keying lookups solely on `MusicDiscoveryIdentity.key(track)` breaks `sameRecording(_:_:)`,
       which also matches swapped artist billing and featured credits via
       `baseTitle == baseTitle && sharesArtist` (`MusicDiscoveryRankingTests.variantsShareIsrcOrSwappedBillingAndMergeReasons`),
       and naive hash-dedupe breaks multi-slot ordering/variant selection at `:132-148`.
  - **CRITICAL 4 — Naive view-gated or async-only `refreshDiscovery()` in original Steps 1c–1d breaks `MusicViewModel` test contracts and misses `SpotifyLibraryStore.restore()` coalescing**
    (`PlayerMac/PlayerMac/App/PlayerSession.swift:10,53-91`,
    `PlayerMac/PlayerMac/Music/MusicViewModel.swift:246`,
    `MusicViewModel+Library.swift:84,104-150`,
    `PlayerMac/PlayerMac/Music/Spotify/SpotifyLibraryStore.swift:75-114`,
    `PlayerMac/PlayerMacTests/DiscoveryReviewModelTests.swift:244-271,300-314`,
    `DiscoveryViewModelTests.swift:74-92`):
    Standalone `MusicViewModel` tests do not mount `DiscoveryWorkspaceView` and synchronously assert
    `discoverySnapshot != nil` right after `init`, `replaceStore`, `openSimilar`, `notInterested`,
    and `undoNotInterested`. In addition, `SpotifyLibraryStore.restore()` fires `onChange?()` during
    both `install(preview)` and `install(restored)` while `isRestoring == true` *before* loading
    `playHistory` (`:87-95`), so naive `guard !store.isRestoring` in `acceptLibrary` would drop the
    post-restore refresh altogether when active.
  - **MAJOR 1 — Evidence version & unit provenance**
    (`heap-at-plateau.txt:5`, `vmmap-at-plateau.txt:5`, `main-thread-sample-excerpt.txt:5`,
    `cold-start-series.jsonl`):
    PID 78147 ran `0.5.7 (17)` (explaining Sparkle `Autoupdate` holding a pending `0.5.8` reminder
    for 12 h), whereas `/Applications/Kinrox.app` during cold-start Runs 1–2 (PIDs 33104, 33523) was
    already `0.5.8 (18)`; `measure-memory.py` values are binary MiB (`847.7 MiB` / `849.2M` vs
    `ru_maxrss` `888.9 MB`).
  - **MAJOR 2 — Misstated SwiftUI mounting, `.help` status, accessibility regression risk, and H3 cache bound in original Steps 2 & 4**
    (`MusicView.swift:21-29`, `TrackTable.swift:145`, `DiscoveryTrackRow.swift:85,150,166,202`,
    `SourceColumn.swift:245,284,303`, `AlbumsWorkspaceView.swift:264`, `QueueView.swift:316`,
    `AlbumColumn.swift`, `SpotifyLibraryStore.swift:32`):
    Inactive SwiftUI workspaces already unmount and `TrackTable`/`TrackMetadataPopovers` already use
    `.hoverHelp`; remaining repeated-row `.help` sites are in `DiscoveryTrackRow`, `SourceColumn`
    (486 lines — near the 500-line ceiling), `AlbumsWorkspaceView`, and `QueueView`. Replacing
    `Button` with gestures would break keyboard focus, VoiceOver, and `Menu` anchoring.
  - **MAJOR 3 — Verification commands, iOS Simulator prohibition, and unrealistic 4 h / 12 h CI soak gates**
    (`AGENTS.md` Rules 5, 7, 10, 11; `docs/runbooks/RUNBOOK-TASK-TESTS.md`):
    Added exact Mac-only test/build commands, generic-iOS compile check (`CODE_SIGNING_ALLOWED=NO`,
    no Simulator), `check-localization.py`, 500-line ceiling tracking, deterministic 20k-track
    seeded + 5k-liked unseeded regressions, and live-session safety boundaries.
  - **MINOR 1 — Phased scope clarity:** Separated mandatory fixes (Steps 1, 2a, 4, 6) from
    measurement-gated allocator relief (Step 2b) and deferred `NSTableView` virtualization.
- **Changes made:** Updated Status, added verified cold-start trace and provenance notes in sections
  3/3a/4/5, rewrote section 6 (`Improvement plan`) with exact data structures, contracts, relevant
  file table (section 6a), verification commands and acceptance criteria (section 6b), updated
  sections 7–8, and renamed document with `REVIEWED - ` prefix.
- **Checks run (read-only):**
  - Inspected all cited `MusicCore`, `PlayerMac`, `SoloistHost`, `SparkleUpdater`, and test files;
    verified file line counts (`wc -l`) and incoming links (`git grep -n "2026-11-12_07-05"` → none).
  - Ran `swift test --package-path Packages/KinroxMusic`: 67 tests in 13 suites passed (`0.329 s`;
    confirmed `MusicDiscoveryRegressionTests.seedRemixIsExcludedAndOneArtistCannotFillFirstThirty`
    alone takes `0.329 s` on 35 tracks due to the $O(N^3)$ diversity loop + regex/CharacterSet work).


## Initial implementation evidence — 2026-11-12 (historical handoff)

This section preserves the initial QUESTIONS handoff. The continuation decisions and final
results below supersede its pending acceptance and live-session boundaries.

Existing edits in `AGENTS.md`, `.agents/skills/research-execute/prompts/execute.md`, and the
untracked `.agents/skills/general-release/` directory predated this implementation and are preserved.
The reviewed document and its original evidence directory also predated this pass.

### Verified plan corrections

- Preserve the existing `en_US_POSIX` normalization locale, the **12-hour** liked-date window,
  and empty artist credit equivalence. The plan's `.current`, seven-day window, and exclusion of
  empty credit tokens conflict with the unchanged-behavior requirement and current source.
- Current source locations differ from the review table. `select` is in `MusicViewModel.swift`;
  a selection observer covers all navigation paths, including album overview and search.
- Merely replacing the cubic diversity pass with repeated linear maxima still took **39.582 s**
  in the initial 20,000-track seeded Debug regression (4,829 output items). A lazy max heap with
  decreasing score bounds preserves greedy ordering and avoids that remaining quadratic pass.
  Sorting compact indices avoids repeatedly copying full track/signal values.
- `SourceColumn`, queue rows, and Discovery rows have different hover properties from those named
  in the plan. Existing local states are used; native Buttons and Menu anchors are retained.
- The source already guards `syncLibrary`'s follow-up with `!isDiscovering`. Automatic refreshes
  additionally obey workspace activity and restore state. The `PlayerSession` construction passes
  an inactive workspace before model initialization, including demo/persisted-selection cases.
- The owner's installed Kinrox session (PID 33523) and its Soloist children are running. They
  have not been stopped, restarted, controlled, or replaced. The plan's synthetic benchmark
  fallback applies. Live cold-start/scroll/refresh/20-seed and playback acceptance remain unmeasured.
- A physical iPhone is connected by cable (`devicectl`: physical, wired). Consumer verification
  used its destination, not the reviewed plan's unsigned generic-iOS command or a simulator.

### Red evidence

Logs are in `.tmp/scratch/research-execute/runs/2026-11-12_11-21-04-6YImzv/`.

- `core-red.log`: the existing 64-candidate diversity test (not 35 as the plan states) failed the
  new 15 ms assertion at **657.978 ms**, before production edits.
- `core-scale-red.log`: the old 20,000-track regression exceeded the 60-second harness limit.
- `mac-red.log`: method-only selection executed **zero tests** and is not passing evidence.
- `mac-red-suite.log`: 27 Discovery service tests ran; two new lifecycle tests reported five
  expected issues (Video-mode deferral, snapshot release, and complete-history notification).
- `core-second.log` / `core-heap.log` / `core-profile-*.log`: intermediate performance failures
  are retained. Profiling prints used for diagnosis have been removed from production source.
- `core-equivalence.log`: the multi-hundred-track reference comparison passed all three modes.
  Reference implementations are frozen test-only copies of pre-change behavior.

Release status: **not released**. No branch, commit, push, version bump, installed-app replacement,
credential change, distribution export, notarization, or publication has been performed.


### Initial-stage changes and plan outcomes (before continuation)

| Plan item | Outcome and changed paths (repository-relative) |
|---|---|
| 1a — Identity/tokenization | Implemented in `Packages/KinroxMusic/Sources/MusicCore/MusicDiscoveryIdentity.swift` and new `MusicDiscoveryTrackIdentity.swift`: ASCII/Unicode scalar normalization, static regexes with fast paths, per-pass lazy Sendable track identities and normalized artist-name cache. Public APIs remain intact. |
| 1b — Ranking/local signals | Implemented in `MusicDiscoveryLocalSignals.swift`, `MusicDiscoveryRanking.swift`, and new `MusicDiscoveryOrdering.swift` in the same directory: collaborator index, binary-search liked dates, completed-history set, seed token lookup, compact sorting/deduplication, lazy heap diversification, and single-pass reason aggregation. Exact reference equality passes. The required Debug latency gate still fails; see checks below. |
| 1c — Async computations | New `PlayerMac/PlayerMac/Music/MusicDiscoveryComputation.swift` runs Sendable snapshots off MainActor in an autorelease pool, with cancellation propagation. `Spotify/SpotifyLibraryStore+Discovery.swift`, `SpotifyLibraryStore+DiscoverySignals.swift`, and `MusicViewModel+Radio.swift` recheck session/store/consent before publishing or committing. Synchronous standalone model behavior remains intact. |
| 1d — Startup/restore | `PlayerMac/PlayerMac/App/PlayerSession.swift`, `MusicViewModel.swift`, `MusicViewModel+DiscoveryLifecycle.swift`, `MusicViewModel+DiscoveryState.swift`, `MusicViewModel+Library.swift`, and `Spotify/SpotifyLibraryStore.swift` defer automatic Discovery while inactive/restoring, publish complete restored history once, and activate one refresh. Explicit Similar actions and remote radio remain available. |
| 1e — Cache bound | `SpotifyLibraryStore+Discovery.swift` limits in-memory discovery entries to 12. A 20-seed regression confirms eviction, SQLite reload without HTTP, and active-seed trimming. Disk cache limits are unchanged. |
| 2a — Disposable state | Selection changes, inactive Music, and `PlayerMac/PlayerMac/Player/PlayerWindowController.swift` window closure release UI Discovery state and applicable search/theme/expansion caches. Tests preserve queue, history, pause state, and remote metadata. Reopening reactivates the workspace. |
| 2b — Allocator relief | Not retained: this is measurement-gated, and no live application saving or hitch evidence is available without disturbing the owner's running session. No allocator-pressure call was added. |
| 3 — Artwork/IOSurface | No changes, as specified by the reviewed plan. Existing 0.5.6 work remains intact. |
| 4 — Repeated row tooltips | `PlayerMac/PlayerMac/Music/UI/{DiscoveryTrackRow,SourceColumn,AlbumsWorkspaceView,QueueView}.swift` use conditional `hoverHelp` on repeated row labels. Button/Menu identity and explicit accessibility labels are preserved. Single header help remains eager. |
| 5 — Soloist/Sparkle | No changes. No Soloist arguments, credentials, pairing, helper lifecycle, or updater behavior changed. |
| 6 — Regressions/evidence | Added scale/equivalence, cache, restore/activation, disposal, off-main/cancellation and hidden-workspace remote regressions; expanded opt-in UI renders to Similar. Automated results and synthetic evidence follow. No release or live application performance claim is made. |

Additional implementation choices supported by profiling/equivalence:

- Identities are constructed lazily when a pass actually needs a track, rather than eagerly
  allocating metadata for every catalog entry. Normalized artist names are shared within that pass.
- A token maps to one live representative: every insertion merges all matching live slots, so two
  live representatives cannot share a token. Compact indices and separate reason arrays avoid
  copying complete tracks during each merge. Only the winning representative's own tokens survive,
  matching the original algorithm (including the three-way bridge regression).
- The diversity max heap uses only downward score corrections and the original tie-breaking,
  primary-artist caps and seed-artist caps. The frozen test reference verifies exact results for
  all three modes on a 243-track corpus; identity tests cover Unicode, swapped/empty credits,
  variants and ISRC matches.
- Tooltip modifiers are attached to labels inside stable native controls. This avoids replacing
  a Button/Menu when hover state changes.

Changed tests are `Packages/KinroxMusic/Tests/MusicCoreTests/{DiscoveryScaleTests,
DiscoveryIdentityEquivalenceTests,MusicDiscoveryRegressionTests,ReferenceDiscoveryIdentity,
ReferenceDiscoveryLocalSignals,ReferenceDiscoveryRanking}.swift` and
`PlayerMac/PlayerMacTests/{DiscoveryMemoryLifecycleTests,RemoteSimilarTests,MusicLayoutTests}.swift`.
The three `ReferenceDiscovery*` files are frozen pre-change test-only specifications, split to obey
500 lines. The full source/test/tool inventory is in
changed Swift paths (local-only artifact: `.tmp/scratch/research-execute/runs/2026-11-12_11-21-04-6YImzv/changed-swift-files.txt`).

### Initial-stage final automated checks (historical)

`RUN=.tmp/scratch/research-execute/runs/2026-11-12_11-21-04-6YImzv` below. All commands ran in the
main checkout with the existing signing configuration. No simulator was launched, no signing was
disabled, and no installed application was replaced.

| Exact command / check | Result | Evidence under `RUN` |
|---|---|---|
| `swift test --package-path Packages/KinroxMusic` | **FAIL**, 72 tests / 15 suites, two timing issues only: seeded 873.170 ms and unseeded 479.914 ms versus 250 ms. Functional/equivalence assertions passed. | `core-compact-slots.log` |
| `swift test -c release --package-path Packages/KinroxMusic` | **PASS**, 72 tests / 15 suites; seeded 232.272 ms, unseeded 117.826 ms; exact repeated outputs 4,829 and 59 items. This does not replace the failed default-Debug requirement. | `core-compact-slots-release.log` |
| Existing 64-candidate diversity regression, new `<15 ms` assertion | **PASS** in both configurations (whole test about 9 ms Debug / 3 ms Release), versus 657.978 ms pre-fix. | Same final package logs and `core-red.log` |
| `swift test --package-path Packages/RemoteProtocol` | **PASS**, 130 tests / 23 suites. No protocol source changed afterward. | `protocol.log` |
| `xcodegen generate --spec PlayerMac/project.yml` | **PASS** after adding source/test files; generated projects preserved. | `execute-1.log` (generator tool output) |
| `xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData build test` | **PASS**, 368 tests / 67 suites after the last production change, 94.835 s. | `mac-compact-final.log` and its recorded `.xcresult` |
| `xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData build` | **PASS**, local Release build only. | `mac-release-compact-final.log` |
| `xcodebuild -workspace Kinrox.xcworkspace -scheme RemoteiOS -configuration Debug -destination 'id=00008110-0009193E3EB8801E' -derivedDataPath DerivedData build` | **PASS**, signed physical-iPhone consumer build. No installation or physical-device tests performed. | `iphone-compact-final.log` |
| `python3 Scripts/check-localization.py` | **PASS**, 30 locales / 470 UI keys plus prompts and format checks. No string edits followed. | `localization.log` |
| `xcrun swift-format lint --strict <each path in changed-swift-files.txt>` | **PASS** after final source changes; maximum source/test length 493 lines (`SourceColumn.swift`). | `lint-compact-final.log`, `line-counts-final.json` |
| `./Scripts/check-env.sh` | **PASS**. Runtime listing did not boot or launch an iOS Simulator. | `environment.log` |
| Python benchmark helper syntax and execution | AST parse passed; the real owned-process benchmark below exercises the helper. No existing Python tool was modified. | `benchmark-final-measure.log` |
| `xcrun vtool -show-build` on built Mac/iPhone executables, plus plist inspection | Mac minimum 14.0; iPhone minimum 17.0. Versions remain 0.5.8 (18) / 0.2.2 (4). Metadata is not runtime acceptance on those OS versions. | `minimum-os-metadata.log` |

No new Swift compiler warnings were reported. The local Homebrew libmpv macOS-26-versus-14 linker
warning remains, as required by `RUNBOOK-BUILD-AND-SIGNING.md`; AppIntents metadata-extraction skip
warnings also remain. Thus the plan's literal all-target "zero warnings" condition is **not** met.
Neither warning was suppressed, and this local build is not a macOS 14 runtime verification.

The initial full Mac run had one fixture failure (the cache fixture lacked liked-resource
freshness); it is retained in `mac-full-first.log`. Corrected fixture and later full runs pass.
The final build/test command manifest is
recorded here (local-only artifact: `.tmp/scratch/research-execute/runs/2026-11-12_11-21-04-6YImzv/compact-final-check-results.json`).

### UI and live-session boundary

The opt-in `KINROX_MUSIC_SNAPSHOTS` test produced eight demo renders (Albums, Liked, Queue, Similar
at 1024×768 and 1440×900) in `RUN/ui`. Similar at 1024, Albums at 1440, Queue at 1024 and Liked at
1440 were visually inspected; controls/content fit without a visible regression. The rendering
case passed even in the earlier run with the unrelated cache-fixture failure. This is static
render evidence, not interactive tooltip, VoiceOver, scroll-memory or physical-device acceptance.

The installed Kinrox process and its Soloist children remained running throughout. Spotify.app
was absent at the read-only process checks. No playback command was sent, no system volume changed,
and no account/preferences/credentials were used by the synthetic benchmark. Live startup,
playback, pause, sustained-use memory/CPU and command latency on the owner's library were **not
measured**. Existing Soloist accepted bounds and the sleep/reboot waiver remain unchanged; no
separate macOS 14 runtime test was requested or performed. The synthetic result cannot establish
a new real-application cold-start peak, Soloist latency, or standalone-playback acceptance.


### Synthetic physical-footprint, CPU and latency measurement

The new tools are
DiscoveryMemoryBenchmark.swift (local-only artifact, not included in the repository: `2026-11-12_07-05_Kinrox-memory-peak-evidence/DiscoveryMemoryBenchmark.swift`)
and measure-discovery.py (local-only artifact, not included in the repository: `2026-11-12_07-05_Kinrox-memory-peak-evidence/measure-discovery.py`).
They create only synthetic metadata (20,000 tracks; 5,000 liked; 5,000 history rows; five explicit
seeds or no explicit seed; variants, playlists and compilation tracks). The benchmark performs
62 alternating builds (31 of each case), uses an autorelease pool per build, and never opens
Kinrox accounts, audio or preferences. Resource sampling targets only its owned subprocess.

Historical commands, using the local-only tools (not included in the repository), with `RUN` as
above and `EVIDENCE=docs/RESEARCHES/2026-11-12_07-05_Kinrox-memory-peak-evidence`:

```sh
clang -O2 Tools/SoloistProbe/resources.c -o "$RUN/resource-counter"
xcrun swiftc -O -whole-module-optimization -swift-version 6 \
  -strict-concurrency=complete -parse-as-library \
  Packages/KinroxMusic/Sources/MusicCore/*.swift \
  "$EVIDENCE/DiscoveryMemoryBenchmark.swift" -o "$RUN/discovery-memory-benchmark-final"
python3 "$EVIDENCE/measure-discovery.py" \
  --binary "$RUN/discovery-memory-benchmark-final" --counter "$RUN/resource-counter" \
  --output "$RUN/synthetic-release-final"
```

The helper samples native `physical_footprint_bytes` and CPU counters approximately every 50 ms,
then runs `vmmap -summary`, `heap -sortBySize`, and `leaks` while the benchmark is idle.
All three inspection commands exited 0. Raw reports are preserved in
implementation-synthetic-release (local-only artifact, not included in the repository: `2026-11-12_07-05_Kinrox-memory-peak-evidence/implementation-synthetic-release/summary.json`),
with derived metrics (local-only artifact, not included in the repository: `2026-11-12_07-05_Kinrox-memory-peak-evidence/implementation-synthetic-release/analysis.json`).

| Measurement | Observed result |
|---|---|
| Synthetic ready/fixture footprint | 17.53 MiB |
| Peak sampled physical footprint | 64.72 MiB; `vmmap` process peak **64.9 MiB** |
| Idle after first seeded/unseeded pair | 31.05 MiB, 0% sampled CPU |
| Final idle after 62 builds | 61.1 MiB (`vmmap`); allocator retention remains observable |
| Leaks | **0 bytes / 0 leaks** reported |
| Seeded latency (31 builds, 4,829 items) | First 234.46 ms; median 247.96 ms; p95 361.40 ms; max 434.01 ms |
| Unseeded latency (31 builds, 59 items) | First 163.00 ms; median 131.49 ms; p95 214.69 ms; max 239.14 ms |
| CPU during same-phase sampled compute intervals | Seeded 83.9% of one core; unseeded 76.8%; ready and initial idle 0% |

CPU percentages use deltas of user+system nanoseconds divided by elapsed seconds, excluding
sampling intervals crossing a phase boundary. Sampling/helper overhead and other owner-session
activity can affect wall time. The optimized unit-test pass at 232 ms is therefore **not** a
claim that repeated production ranking always meets 250 ms. The stress benchmark's seeded p95
also exceeds 250 ms. No threshold was weakened, result set capped, test disabled, or Debug
optimization flag changed to conceal these results.

This synthetic process is not comparable to the whole installed application's 848–849 MiB live
baseline (different UI/library/process contents). It shows bounded synthetic allocation and zero
reported leaks, not a measured percentage reduction in real-app startup memory. The initial
prototype benchmark remains in `RUN/synthetic-release`; its phase labels recorded completion
rather than computation, so only its overall peak was used diagnostically. The final benchmark
emits computation phase markers before work and preserves every raw sample. No allocator relief
or further UI virtualization is justified by this synthetic-only evidence.

### Remaining work and orchestrator question

All independent implementation/build/functional checks in this pass are complete. **Acceptance is
not complete**: section 6b explicitly requires the 20,000-track case below 250 ms under ordinary
`swift test`, and it fails in Debug. Release's required single-run test passes, but the separate
sampled sustained benchmark has a seeded p95 above 250 ms. The intended configuration and timing
protocol need clarification before changing the performance test contract or claiming completion.

The numbered question, alternatives, recommendation, and exact stopping point are in
questions.md (local-only artifact: `.tmp/scratch/research-execute/runs/2026-11-12_11-21-04-6YImzv/questions.md`).
Depending on the answer, further optimization and the affected final checks remain required.
The real-library live scenarios are unperformed under the plan's explicit synthetic fallback,
and existing local-toolchain warnings remain documented rather than treated as zero warnings.

The reviewed document and evidence stay at their current root locations. Nothing has been moved
to `DONE/`, because a required check is still failing. Release status: **not released**.

Own-diff checks completed: `git diff --check` passed, all 10 outgoing relative Markdown links
resolve, and no incoming documentation reference to this unchanged filename was found. Evidence:
`RUN/diff-check-final.log`, `RUN/documentation-links-final.json`, and `RUN/status-final.txt`.
Pre-existing AGENTS/skill edits and all generated/test artifacts remain preserved. The checkout
remains on `main`, with task changes uncommitted.

### 2026-11-12 08:20:35 Europe/Moscow — gpt-6-astra — `implementation`

- Implemented the applicable scoped plan items and recorded factual corrections above.
- Completed independent local verification: Mac/physical-iPhone builds, 368 Mac tests, 130
  protocol tests, 72 Release MusicCore tests, localization, formatting, metadata and synthetic
  measurement. The default-Debug MusicCore timing gate remains failed; no pass is inferred.
- Result: **QUESTIONS** pending the performance-contract clarification; not released. No additional
  agent, skill execution, independent post-implementation review, commit or distribution action.


## Continuation decisions — 2026-11-12

- **Orchestrator clarification (source: continuation answer 1):** the original 250 ms requirement
  limits a main-thread occupancy, not total background ranking time. The review introduced the
  default-Debug 250 ms wording. Keep full output and functional/equivalence assertions; use a
  fixed 2,000 ms Debug 20k guard and retain the small-corpus 15 ms guard. Release acceptance is
  median <250 ms after a warm-up and at least 15 repetitions per case; report p95/max without
  making p95 a gate. Measure actual Mac refresh/MainActor and first SwiftUI update where feasible.
  The earlier failed checks above remain historical evidence, not current acceptance criteria.
- **Owner authorization (source: continuation answer 2, owner quoted "Да, можно закрыть",
  2026-11-12):** gracefully quit the installed app, measure a cold start of the local Release
  bundle and real-library scenarios, then quit the local build without reopening the installed app.
  No installation, release, credential/pairing change, manual preferences/cache edit or system
  volume change is authorized. Normal requested UI navigation/refresh is used for live scenarios.
- **Verified version correction:** `/Applications/Kinrox.app/Contents/Info.plist` reports 0.5.8,
  matching earlier diagnostic headers, rather than the 0.5.7 shorthand in the authorization.
- **MainActor measurement includes the remaining synchronous path:** `refreshDiscovery()` still
  constructs the initial local/cached snapshot synchronously to preserve the existing standalone
  model contract. The new 20k Mac regression measures that turn, cached publication, mounted
  SwiftUI layout, and conservative main-queue scheduling delay through the async completion.
  It uses synthetic stores and offscreen windows without touching owner data.
- The first optimized test attempt could not import `@testable` modules because standard Release
  disables testability (`continued-mainactor-release.log`). The retry uses a command-only
  `ENABLE_TESTABILITY=YES` with `-O` still enabled and existing signing unchanged. The live app
  will be rebuilt with ordinary Release settings before launch.


### Continuation regression and corrective work

- The initial optimized Mac regression failed the actual MainActor gate: seeded refresh 269.99 ms,
  first layout 76.19 ms, combined synchronous turn 346.22 ms, conservative main-queue delay
  357.11 ms; unseeded delay 169.14 ms. Evidence: `continued-mainactor-release-sendable.log`.
  This exposed the remaining initial cached/local synchronous path rather than background ranking.
- A standalone optimized profile of copied source (not production instrumentation) attributed
  about 62 ms to local signal collection and 81 ms to candidate identity filtering. Title qualifier
  parsing still repeated for every track even when thousands shared the same suffix.
- Added per-pass suffix memoization for qualifier removal and remixer extraction. Parsing starts
  at the earliest possible expression delimiter, retaining preceding whitespace for dash matches;
  the original prefix is preserved and the combined title receives the same normalization.
  No persistent cache, candidate cap, output cap or synchronous-contract change was introduced.
  New reference comparisons include Unicode/whitespace prefixes, unmatched delimiters, multiple
  annotations and dash boundary cases; full ranking equivalence remains required.
- The optimized test-only HTTP stub failure was resolved with an explicit `@Sendable [self]`
  capture on its existing task. This is a test build prerequisite, not a production networking
  change. The compiler failure and retry logs are retained; concurrency checking was not relaxed.
- Graceful AppleScript quit of the installed 0.5.8 app succeeded; installed-app and Soloist process
  counts both reached zero (`continued-graceful-quit.log`). Spotify.app was absent. The installed
  app will remain closed after verification, per the owner's instruction.

- Further allocation reductions retain the same ranking contract: deduplication now carries
  weighted reasons instead of copying full signal/track values; recording tokens use typed
  components instead of concatenated artist/title strings. Existing exact-reference comparisons
  and 20k output equality cover both paths. Candidate and output counts remain unchanged.
- Measurement correction: the first test forced SwiftUI layout immediately inside the refresh
  caller's synchronous turn. The final regression lets AppKit schedule its update, times each
  layout and the refresh/publication calls, and observes actual run-loop busy intervals with a
  `CFRunLoopObserver`. Queue scheduling delay remains printed separately because it can include
  several actor jobs and scheduler latency. The original 269.99 ms refresh itself was a real
  failure and motivated the optimizations; the historical forced combined timings are retained.
- Final package runs after these changes: `continued-tokens-debug.log` passes 73 tests / 15 suites
  with 20k seeded/unseeded times 565 / 300 ms. `continued-tokens-release.log` passes the same
  assertions with 15 timed repetitions per case after warm-up: seeded median 173.471 ms,
  p95/max 255.356 ms; unseeded median 75.722 ms, p95/max 85.532 ms. The seeded tail above 250 ms
  is recorded under the orchestrator's accepted background-build protocol, not hidden.
- The first run-loop test compile used the SDK's renamed C constant and failed before execution
  (`continued-mainactor-runloop.log`). It was corrected to `CFRunLoopMode.commonModes`; no
  production configuration or checking rule changed.

- The corrected run-loop regression still failed with the synchronous preview: seeded refresh
  201.99 ms plus subsequent UI work produced a **308.06 ms** actual busy interval; unseeded
  144.41 ms passed (`continued-mainactor-runloop-fixed.log`). The result was not reclassified as
  background work or accepted by changing the 250 ms bound.
- Large-library cached/local previews now capture value-only inputs and use the same cancellable
  detached worker as connected Discovery. The seed/header is published immediately, with all
  candidates and ranking output published after completion. Libraries above 1,000 tracks take
  this path; this is a scheduling threshold, not a candidate/output cap. Small standalone/demo
  stores retain their existing synchronous contract and unchanged regressions. Request identity,
  store identity, selection and cancellation guards reject retired previews. Cached inputs are
  collected on MainActor; ranking and its autorelease pool run off MainActor.

- Full Debug Mac verification after preview deferral ran 369 tests / 67 suites twice. Both runs
  passed the new MainActor regression (seeded busy interval 217 ms; unseeded 92/118 ms), but
  failed the existing `ScreensaverRemoteTests.failedStart(reason: "timeout")` with `.notConnected`.
  All other tests passed. Logs: `continued-full-mac-debug.log` and
  `continued-full-mac-debug-retry.log`. Neither failed full run is counted as a pass.
- An isolated rerun of the unmodified Matrix transport suite passed all 3 tests, including all
  five failure/timeout arguments, in 12.947 s (`continued-matrix-isolated.log`). This distinguishes
  the observed full-suite failure from the passing isolated check; its cause is not established.
  No transport timeout, test assertion, production setting or unrelated source was altered.

- **Optimized MainActor gate now passes:** `continued-mainactor-preview-release.log` runs 30
  Discovery service tests successfully with existing signing, `-O` and command-only testability.
  For seeded/unseeded 20k refreshes respectively: snapshot preparation/refresh call 0.946/0.669 ms;
  store publication callback 6.900/6.972 ms; longest mounted SwiftUI layout 12.438/14.072 ms;
  longest observed main run-loop occupancy **98.990/90.321 ms** (both <250 ms). Scheduling delay,
  reported separately, was 107.663/90.006 ms. The first UI update, subsequent preview publication
  and connected result completion were observed without forcing ranking onto MainActor.

- Final required Mac Debug retry, after the isolated transport check and independent builds,
  **passed all 369 tests / 67 suites in 94.023 s** (`continued-full-mac-final.log`). Both prior
  full-suite failures remain recorded above; the transient transport failure's cause is unproven.
  No source changes or test exclusions were used to obtain the passing full run.
- Ordinary local Release and wired physical-iPhone Debug consumer builds both passed
  (`continued-ordinary-release.log`, `continued-physical-iphone.log`). The Release app was rebuilt
  without the testability override. No phone app installation or physical-device execution occurred.
  Fresh `devicectl device info details` reports wired/connected, iOS 27.0.1.
- Final scoped strict Swift lint passes; every changed source/test file is <=500 lines (maximum
  493). Final metadata still reports Mac 0.5.8 (18), minOS 14.0, and Remote 0.2.2 (4), minOS 17.0.
  Evidence: `continued-final-source-lint.log`, `continued-final-source-lines.json`,
  `continued-minimum-os-metadata.log`. The live measurement helper's Python AST parses.


## Final continuation results — 2026-11-12

Applicable items **1a–1e, 2a, 4 and 6 are implemented and locally verified**. Steps 3 and 5 remain
unchanged as required. Conditional allocator relief (2b) was not introduced: the measured startup
and session peaks are below 250 MiB, no material unbounded growth was demonstrated in this short
run, and no net-benefit/latency evidence justifies an allocator-pressure call. This does not prove
that all long-session allocator retention is gone or justify further table virtualization.

The continuation additionally changes `MusicViewModel+DiscoveryState.swift` and
`SpotifyLibraryStore+Discovery.swift` to prepare value-only preview closures and defer complete
large-library previews; adds `DiscoveryMainActorPerformanceTests.swift`; adds one explicit
`@Sendable` test-stub capture in `MusicHTTPStub.swift`; and expands the identity equivalence tests.
Final paths and lengths are recorded in `RUN/continued-source-files.txt` and
`RUN/continued-final-source-lines.json`. New evidence tools are `measure-live.py` and
`summarize-live.py` beside the pre-existing benchmark tools. No source, test, app or account in
another repository was modified.

### Final check ledger

Commands below ran from the main checkout on `main`, with ordinary project signing unchanged.
Earlier failed attempts remain in the initial-stage and continuation logs above.

| Exact command | Final result / evidence under `RUN` |
|---|---|
| `swift test --package-path Packages/KinroxMusic` | PASS, 73 tests / 15 suites; `continued-tokens-debug.log`. Seeded/unseeded 20k 565/300 ms <2,000 ms. All equivalence assertions and the small-corpus <15 ms gate retained. |
| `swift test -c release --package-path Packages/KinroxMusic` | PASS, 73 tests / 15 suites; `continued-tokens-release.log`. Fifteen timed repetitions after warm-up per case, exact output equality throughout; medians 173.471/75.722 ms <250 ms; p95/max 255.356/85.532 ms. |
| `swift test --package-path Packages/RemoteProtocol` | PASS, 130 tests / 23 suites; retained `protocol.log`. No protocol changes followed, so this successful suite was not rerun. |
| `xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData build test` | PASS, 369 tests / 67 suites, 94.023 s; `continued-full-mac-final.log`. Two earlier full-run Matrix timeout failures and a passing isolated diagnostic rerun remain recorded; their cause is unconfirmed. |
| `xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData ENABLE_TESTABILITY=YES build test -only-testing:PlayerMacTests/DiscoveryServiceTests` | PASS, 30 tests, optimized 20k MainActor occupancy 98.990/90.321 ms; `continued-mainactor-preview-release.log`. Testability was command-only; optimization and concurrency checks remained enabled. |
| `xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData build` | PASS; `continued-ordinary-release.log`. This ordinary Release bundle was used for live measurement. |
| `xcodebuild -workspace Kinrox.xcworkspace -scheme RemoteiOS -configuration Debug -destination 'id=00008110-0009193E3EB8801E' -derivedDataPath DerivedData build` | PASS, wired physical-iPhone destination; `continued-physical-iphone.log`. Build only, no installation or on-device tests. |
| `python3 Scripts/check-localization.py` | PASS, retained 30 locales / 470 UI keys; `localization.log`. No string changes followed. |
| `xcrun swift-format lint --strict <paths in RUN/continued-source-files.txt>` | PASS after last Swift edit; `continued-final-source-lint.log`. All changed source/tests <=500 lines, maximum 493. |
| `xcrun vtool -show-build <built executable>` plus plist inspection | Mac minOS 14.0 / 0.5.8 (18); iPhone minOS 17.0 / 0.2.2 (4), unchanged; `continued-minimum-os-metadata.log`. |

Known Homebrew libmpv deployment-target and AppIntents extraction warnings remain documented;
no new Swift concurrency warning, weakened build setting, version bump or distribution signing
change was introduced. Existing generated projects, test media, DerivedData, prior logs and
unrelated AGENTS/skill changes remain preserved.

### Live Release evidence

New evidence directories:
interaction session (local-only artifact, not included in the repository: `2026-11-12_07-05_Kinrox-memory-peak-evidence/live-2026-11-12-continuation/summary.json`)
and persisted-Similar cold start (local-only artifact, not included in the repository: `2026-11-12_07-05_Kinrox-memory-peak-evidence/live-2026-11-12-similar-cold/summary.json`).
Both use the existing account/cache through the ordinary app path. There was no reauthentication,
pairing, direct preference/cache edit, credential/account change, installation or system-volume
change. Only authorized navigation and forced refresh used the app's normal persistence behavior.

The observer was started before each launch using the local-only `EVIDENCE` tools and output
paths below, which are not included in the repository:

```sh
RUN=.tmp/scratch/research-execute/runs/2026-11-12_11-21-04-6YImzv
EVIDENCE=docs/RESEARCHES/DONE/2026-11-12_07-05_Kinrox-memory-peak-evidence
python3 -B "$EVIDENCE/measure-live.py" \
  --app /Users/mavbook/projects/Kinrox/DerivedData/Build/Products/Release/Kinrox.app \
  --counter "$RUN/resource-counter" \
  --output "$EVIDENCE/<new-exclusive-evidence-directory>" --interval 0.5
```

The UI tool then launched the exact local bundle. Native `proc_pid_rusage` counters ran every
0.5 s, beginning at process age 0.221/0.350 s. Cold-start maximum sample gaps were below 0.57 s;
one later scrolling interval reached 1.121 s. Kernel high-water readings from `vmmap` retain
sub-sample peaks. The first session collected 1,512 samples over 755.7 s; the second collected
892 over 445.8 s. **All 2,404 samples found Spotify.app absent.** No Soloist child was started.

| Scenario | Physical footprint and observed outcome |
|---|---|
| First cold start, 75 s, Liked tracks persisted | Sampled peak 123.25 MiB, kernel peak **123.3 MiB**, settled 119.74 MiB. |
| Second cold start, 130 s, Similar persisted via the preceding UI session | Sampled peak 120.55 MiB, kernel peak **120.8 MiB**, settled 115.77 MiB. Entering Music confirmed Similar was the restored selection and built its results on activation. |
| Music and initial Similar | Sampled peaks 146.83/144.44 MiB; settled 131.17/128.92 MiB. The raw phase named `similar-unseeded` actually used the UI's fallback track seed; the second launch exercised restored unseeded Similar. |
| B — forced library refresh | View → Refresh list / Cmd-R calls `syncLibrary()` and forced collection loads. Loading completed without an error; 61 s phase peak 136.61 MiB, end 135.17 MiB. The reviewed Settings location was inaccurate. |
| A — track/album boundaries | Visited first/last/first of 763 liked tracks and both boundaries of 855 cached albums using exposed accessibility scroll actions. A native scroll call returned `noWindowsAvailable`; the app remained running and responsive, and the exposed boundary actions succeeded. Peak sampled 174.27 MiB; kernel peak **198.3 MiB** captured the short transition. Boundary navigation is not a claim that every intermediate row was rendered. |
| C — three additional album seeds | Sampled peaks 162.41, 156.53 and 154.91 MiB; end readings 154.86, 154.74 and 152.74 MiB. Results included 24 tracks, 6 local tracks with provider unavailable, and an empty result with provider unavailable. The later restored unseeded case returned 217 tracks with provider unavailable. This is the authorized best-effort several-seed run, not the original 20-seed soak. |
| Return to Video / idle | First session peaked at **212.2 MiB** and ended at 205.0 MiB after 107 s. Physical memory did not return to the launch baseline; released model values do not guarantee immediate allocator/compositor reclamation. The entire second session's kernel peak was 167.5 MiB. |

Compared with section 3a's **848–849 MiB** installed-app cold peaks, the persisted-Similar local
Release cold peak is **120.8 MiB** (about 86% lower). Both runs used the same Mac and real account,
but installed distribution and local development-linked Release builds, cache freshness, selected
seed and accessibility tooling differ. This is a directly observed improvement, not a controlled
statistical A/B series. Section 2's 14-hour main-process footprint of roughly 147–154 MB overlaps
these short Music readings; the new run does **not** establish a long-session idle-memory reduction.

`vmmap -summary <pid>` and `heap -sortBySize <pid>` were collected at new sampled high readings
(with a 10 s diagnostic cooldown), plus final snapshots; all exited 0. Thus a transient maximum
may appear in the kernel peak field rather than exactly in that snapshot's current footprint.
The final first-session heap held about 310,796 allocations / 43.5 MiB versus the historical
578,688 / 71.2 MB. It showed 1,524 HelpStyle input nodes and 1,443 content nodes rather than the
historical roughly 27,000 family count; different UI/workload durations limit that comparison.

`leaks --noContent <pid>` **exited 1**, reporting **1,467 allocations / 23,904 bytes (23.3 KiB)**,
principally NSArray roots with AXObserverCookie children in the accessibility-driven session.
This is a recorded diagnostic finding, not a zero-leak pass. Allocation stacks were unavailable,
so attribution to Kinrox changes versus AppKit/accessibility cannot be established. It is distinct
from the historical synthetic benchmark's zero-leak result; no leak-check suppression was used.

### CPU, responsiveness and manual limits

Cold-start CPU averaged 1.06% / 0.60% of one core across the two startup windows and about 0.008%
in their final 30 s. Forced-refresh average was 6.28% (0.55% in its final 30 s). The first post-Music
Video idle tail was about 0.002%. Interactive Similar phases were much higher: about 44–53% in the
initial restored-Similar window, an idle stack sample showed repeated SwiftUI/AppKit layout work,
and the later native-shortcut phase averaged about 11%. These are **Kinrox main-process** values,
not Soloist values; no general Music CPU improvement or <=3% main-app claim is made. Exact native
counter deltas and phase boundaries are in the summary JSONs. UI automation and diagnostics affect
these measurements, but the no-UI stack sample means the entire residual cost cannot simply be
assigned to accessibility-tree collection. It warrants separate investigation outside the reviewed
algorithm/cache/tooltip changes; no unsupported cause or fix was inferred here.

Startup and Similar stack samples, including a 15 s transition sample and a native Cmd-1/Cmd-2
comparison, are preserved. Cold-start stacks were overwhelmingly waiting for events; the former
45 s regex/ranking main-thread stall was not observed. The accessibility press path itself spent
substantial samples in SwiftUI focus/render traversal, while the native shortcut trace was mostly
waiting and had no repeated ranking stack. Aggregated samples and tool round-trip time cannot
prove a universal <250 ms bound for every whole-window UI event. The explicit optimized **20k
Mac refresh/MainActor gate** is instead established by the automated 98.990/90.321 ms regression,
including catalog-value capture, publication and mounted workspace update. No sub-250 ms live
command-latency figure is fabricated from the UI tool duration.

Settings reported the existing Spotify account and “Ready on this Mac,” but the native volume
control remained disabled with an unknown value. Playback/pause/seek/Next were **not attempted**,
because zero Kinrox gain could not be confirmed before playback. No credential or pairing repair
was attempted. There is therefore no new live Soloist latency/CPU/playback acceptance series; the
prior accepted Soloist limits and automated standalone tests remain separate evidence. No system
volume change, Simulator use, physical-iPhone runtime acceptance, sleep/reboot test or separate
macOS 14 runtime test is claimed. The owner's sleep/reboot waiver remains a waiver, not a pass.

Both local Release sessions were gracefully quit. UI process inventory confirmed Kinrox and
Spotify closed; the installed `/Applications/Kinrox.app` was not reopened or overwritten. Release
status: **not released**. No commit, branch, worktree, push, PR, version bump, export, notarization,
publication, additional agent, skill launch or separate post-implementation review was performed.


### Completion and archive

The document and all 90 supporting evidence files were moved together locally to
`docs/RESEARCHES/DONE/`. The owner subsequently directed that the evidence remain local-only,
byte-for-byte in place, and not be committed. The exact directory is excluded by `.gitignore`:
`docs/RESEARCHES/DONE/2026-11-12_07-05_Kinrox-memory-peak-evidence/`.
Earlier command output, initial-stage path inventories and model logs retain their historical
locations as recorded. Evidence references above are local-only artifact paths, not repository
links. The performance-runbook link points to this self-contained research document. There are no outstanding orchestrator questions or required automated checks. The live
limits and diagnostic findings above remain explicit; they are not standalone playback or
whole-window latency acceptance. The checkout remains uncommitted on `main`; unrelated initial
AGENTS/skill edits and all generated artifacts are preserved. Release status: **not released**.

Final own-diff and archive validation is recorded in `RUN/continued-archive-checks.json`:
`git diff --check`, all outgoing document links and the changed incoming runbook link, changed
source existence/500-line ceiling, Python evidence-tool syntax, and source/destination inventory.
No source changes followed the final successful test/build/lint runs.

### 2026-11-12 09:59:28 Europe/Moscow — gpt-6-astra — `implementation`

- Completed the clarified Debug/Release/MainActor performance protocol without capping output;
  all functional/equivalence assertions remain. Final package, Mac and wired-iPhone build results
  and the earlier failures are recorded above.
- Completed the authorized real-library local Release cold starts and best-effort A/B/C scenarios,
  preserved raw samples and diagnostics, and gracefully closed the local app. The installed app
  remains closed; no account/credential repair or system-volume change occurred.
- Result: **DONE — implemented locally; not released**. Elevated Similar CPU, leak diagnostics,
  unperformed playback/physical-device runtime checks and sampling limits remain documented.
- Operation: `implementation`; actual model: `gpt-6-astra`; completion time: 2026-11-12 09:59:28
  `Europe/Moscow`. No commit, release, installation, additional agent or independent review.

## Orchestrator verification — 2026-11-12

- Inspected the diff of `MusicDiscoveryComputation.swift`, `MusicViewModel+DiscoveryState.swift`,
  `MusicViewModel+DiscoveryLifecycle.swift` and `PlayerSession.swift`. The detached worker only
  receives value captures, publication is guarded by request/store identity, and the skipped
  discarded engine build in the `previous` path does not change the output. No WebView and no
  file above 500 lines.
- Suspected race: leaving Similar while a deferred large-library preview runs, then returning
  with a connected store. Disproved: leaving Similar clears `discoverySnapshot` (item 2a), so the
  return starts a fresh refresh. Kept as a regression,
  `DiscoveryServiceTests.leavingSimilarDuringDeferredPreviewStillShowsResultsOnReturn` in
  `PlayerMac/PlayerMacTests/DiscoveryMainActorPerformanceTests.swift`.
- Reran: `swift test --package-path Packages/KinroxMusic` passed (73 tests; 20k seeded/unseeded
  558/294 ms in Debug). `xcodebuild … -only-testing:PlayerMacTests/DiscoveryServiceTests test`
  passed (31 tests). `swift-format lint --strict` passed on the new test. Every outgoing link in
  this document resolves.
- Open, outside this plan: elevated Kinrox main-process CPU while Similar is idle (44–53%,
  repeated SwiftUI/AppKit layout) and the 23.3 KiB `leaks` finding from the accessibility-driven
  session. Real playback at Kinrox volume 0 is unverified.
- Release status: not released.
