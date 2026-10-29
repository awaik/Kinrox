# Live folder playlist during playback

Status: implemented on 2026-10-29 following the owner's implementation request.
Automated verification results and remaining manual limits are recorded below.
Not released. No separate review has taken place.

Date: 2026-10-29. Filename timestamp: Europe/Moscow.

## Problem and expected behavior

The owner reports that another episode can finish downloading while a video is
playing, but neither the Mac player nor the iPhone remote discovers it because
it was absent when the folder playlist was created.

Expected behavior: a newly available video in the current video's directory joins
the naturally sorted playlist without reopening the current video. The Mac list,
navigation buttons, system media commands, and remote navigation availability
update together. Playback position and pause state remain unchanged.

The remote currently exposes Next/Previous and recent files, not a complete folder
browser. This correction updates navigation availability; discovered files do not
become recent files until they have actually been opened successfully.

### Reproduction to run before implementation

1. Create a temporary folder containing only a playable `Episode 1.mkv`.
2. Open it in Kinrox, set Kinrox playback volume to zero, and connect the iPhone.
3. Confirm that Next is unavailable after the initial folder scan finishes.
4. Copy a completed `Episode 2.mkv` into that same folder while playback continues.
5. Inspect the Mac playlist and the remote Next button; then let episode 1 end.
6. Repeat with a completed file renamed from `Episode 2.mkv.!qB` to
   `Episode 2.mkv`.

Current behavior is supported by source inspection and the owner's report.
These steps were exercised through filesystem, connected transport, and real libmpv
integration tests during implementation. A physical iPhone check remains pending.

## Confirmed cause and affected paths

Defect class: an indefinitely cached directory snapshot with no invalidation.

- `PlayerMac/PlayerMac/Library/FolderPlaylist.swift`: `scan(for:)` enumerates
  regular video files and applies Finder ordering. Directory read failures are
  currently converted to an empty enumeration (`try? ... ?? []`), so a transient
  read failure and an empty folder cannot be distinguished by callers. However,
  `FolderPlaylist.init(items:current:)` and `Equatable` already match `current`
  by `VideoFiles.key` and retain `current` at its sorted position when absent
  from `items`.
- `PlayerMac/PlayerMac/Player/PlayerViewModel.swift`: `updatePlaylist(for:)` scans
  on initial open and reuses `playlist.items` when switching to an existing
  neighbor. There is no directory monitor or background refresh, and in-flight
  scans require `self.currentURL == url` instead of reconciling with the latest
  item in the same canonical folder. `advanceAfterEnd()` reads only cached
  `playlist?.next`.
- `PlayerMac/PlayerMac/Player/PlayerViewModel+Commands.swift`: `canNext`,
  `canPrevious`, `playlistCaption`, `next()`, and `previous()` depend on
  `playlist`.
- `PlayerMac/PlayerMac/Remote/RemoteServer.swift` and
  `PlayerMac/PlayerMac/Remote/RemoteStatePublisher.swift`: playback observer
  notifications produce `PlayerState` snapshots containing `canNext` and
  `canPrevious`. Changes to those flags are not `positionOnly` and therefore
  publish immediately without waiting for the 2 Hz position throttle.
- `RemoteiOS/RemoteiOS/Connection/RemoteAppModel.swift` and
  `RemoteAppModel+Commands.swift`: the iPhone disables navigation and does not
  send Next when the received state says it is unavailable.
- `PlayerMac/PlayerMac/NowPlaying/NowPlayingController.swift`: system command
  availability (`.nextTrack`, `.previousTrack`) and folder artist metadata also
  update from `model.observePlayback`.

Refreshing only when Next is pressed cannot resolve the disabled remote button.
Updating `model.playlist` and calling `notifyPlayback()` is sufficient for
SwiftUI, Now Playing, and the existing remote protocol; no new network message
or iOS change is required.

## Alternatives and recommendation

| Approach | Benefit | Limitation |
| --- | --- | --- |
| Manual refresh or refresh on opening the playlist | Small implementation | Does not update the remote during unattended playback |
| Scan every 5–10 seconds | Simple and predictable | Delayed discovery and disk access even when nothing changes |
| `DispatchSource` directory watching with single-loop coalescing and fallback | Prompt discovery with minimal idle work and simple lifecycle | Requires descriptor cleanup and error-preserving rescans |

Recommended: watch the canonical parent directory with a `DispatchSource` wrapped
in an `AsyncStream` (matching the stream-injection style of `TrackController` and
`TrackFileScanner`), coalesce bursts in a single sequential worker task, perform
an on-demand rescan at EOF only when `next` is missing or dirty, and fall back to
periodic scans only while a live descriptor cannot be opened. Recursive FSEvents
monitoring is unnecessary for the flat folder playlist.

## Proposed behavior and implementation

### 1. Stream-based directory monitor and single-loop coalescing

- Add `PlayerMac/PlayerMac/Library/FolderMonitor.swift` (and regenerate
  `PlayerMac.xcodeproj` via `./Scripts/generate.sh`) using injectable `@Sendable`
  closures rather than a multi-protocol adapter/clock hierarchy:
  - `scan: @Sendable (URL) throws -> [URL]` (default `FolderPlaylist.scanItems(in:)`),
  - `watch: @Sendable (URL) -> AsyncStream<FolderWatchEvent>` (default
    `DispatchSource` on `open(path, O_EVTONLY)`),
  - `sleep: @Sendable (Duration) async throws -> Void` (default
    `Task.sleep(for:clock: .suspending)`).
- Keep `PlayerViewModel.init(engine:recents:playlistProvider:)` source-compatible
  with existing test suites (`PlayerCommandsTests`, `NowPlayingControllerTests`,
  `LibraryTests`, `RemoteServerHarness`) that pass a trailing closure on synthetic
  paths such as `/tmp/Series`. When a custom `playlistProvider` is injected
  without a live watcher, use an empty watch stream so tests do not touch real
  disk or open descriptors on non-existent paths.
- Observe only the canonical parent directory (`VideoFiles.key(url.deletingLastPathComponent())`).
  Reuse the active monitor across transitions within the same canonical folder,
  including symlink aliases.
- Start the watch stream before kicking off the initial scan so no file created
  between initial enumeration and watcher registration can be missed.
- Coalesce notifications with a single sequential worker loop instead of separate
  trailing-debounce and max-wait timers:
  1. When `.changed` arrives, set `needsRescan = true` and wake the worker.
  2. While `needsRescan` is true, sleep for a fixed `250 ms` coalescing window
     (absorbing any burst of events without pushing the deadline forward), clear
     `needsRescan = false`, and run one background `scan(folder)`.
  3. If another event arrived while `scan(folder)` was executing, `needsRescan`
     is true again and the loop runs one follow-up cycle automatically.
- Guarantee descriptor cleanup: close `fd` strictly inside the `DispatchSource`
  cancel handler, and invoke `source.cancel()` from `continuation.onTermination`.
  Cancel the monitor when media is cleared, the canonical folder changes, or
  `shutdown()` runs.

### 2. Reconcile results via `FolderPlaylist` without disrupting playback

- Add `FolderPlaylist.scanItems(in folder: URL) throws -> [URL]` so callers can
  distinguish a read failure from a valid empty directory, while keeping
  `FolderPlaylist.scan(for:)` for existing synchronous callers. Add a deterministic
  path tie-breaker to `FolderPlaylist.finderOrder` when `localizedStandardCompare`
  returns `.orderedSame`.
- Reuse `FolderPlaylist.init(items:current:)` directly for reconciliation: it
  already locates `current` by `VideoFiles.key`, preserves `current` as a sorted
  anchor when it disappears from disk or uses a non-standard extension, removes
  vanished neighbors, and inserts newly discovered files.
- Reconcile against `self.currentURL` at commit time on `@MainActor`, guarded by
  a `folderGeneration` token that increments only when the canonical folder
  changes, the current file is cleared, or the player shuts down. A scan that
  started during Episode 1 and finishes after switching to Episode 2 in the same
  folder still updates the playlist anchored on Episode 2; scans from an old
  folder or closed session are discarded.
- On initial scan failure for a new folder, fall back to
  `FolderPlaylist(items: [], current: currentURL)` (retaining the playing item).
  On background rescan failure, keep the last valid `FolderPlaylist` snapshot
  untouched without showing alerts or interrupting playback.
- Because `FolderPlaylist` is `Equatable`, commit and call `notifyPlayback()`
  only when `updated != self.playlist`. Never reload, seek, pause, or record
  recent files in response to a directory update.

### 3. Unified recovery, wake, and EOF behavior

- Unify directory replacement and watcher unavailability through stream
  termination in `watch(folder:)`:
  - On `.write`, `.extend`, `.attrib`, or `.link`, yield `.changed`.
  - On `.delete`, `.rename`, or `.revoke` of the watched directory vnode, yield
    `.invalidated` and finish the stream. The worker waits `250 ms`, rescans, and
    re-invokes `watch(folder:)` to attach to a replaced directory at the same path.
  - When `open(O_EVTONLY)` fails (initially or after a deleted directory was not
    recreated), the stream finishes without yielding. The worker waits the
    fallback `10 s` interval, rescans, and retries `watch(folder:)`. Once
    `watch(folder:)` succeeds, fallback polling stops automatically.
- Observe `NSWorkspace.didWakeNotification` to trigger a post-wake rescan. Do not
  add separate `willSleepNotification` timer-pause logic. Explicitly select
  `SuspendingClock` so delays pause while macOS is asleep; the SDK declares the
  default clock for `Task.sleep(for:)` as `ContinuousClock`.
- Keep normal EOF advancement (`advanceAfterEnd()`) synchronous when
  `playlist?.next` is already available, no watcher rescan is pending, and the
  file is reachable: open `next` immediately as today so episode transitions stay
  instant and existing synchronous EOF tests remain valid.
- Perform a one-shot immediate async rescan at EOF only when `autoAdvance && hasMedia`
  and `playlist?.next == nil` (or a watcher invalidation is pending / `next` is
  missing on disk):
  - Cancel any pending EOF rescan task on `open(url:)`, `setPaused(_:)`,
    `seek(...)`, `resetMedia()`, `clearCurrentFile()`, or `shutdown()`.
  - When the one-shot scan finishes, advance only if `autoAdvance && isAtEnd && !replayPending && !isClosing && currentURL == eofURL`, and `playlist?.next` is now non-nil.
  - If no next item is found (or the scan fails), finish the EOF check and stay
    on the final frame. Subsequent directory updates may enable `canNext`, but
    must never start playback on their own.
- Preserve synchronous manual command/ack semantics (`next()`, `previous()`).
  Ordinary load errors remain visible if a file disappears before `open(url:)`.

### 4. Treat incomplete downloads explicitly

- Preserve video-type filtering and exclusion of hidden/non-regular entries.
  Add focused coverage for temporary suffixes such as `.part`, `.crdownload`,
  and `.!qB`; a renamed final `.mkv` or `.mp4` becomes discoverable.
- A directory watcher detects entry changes; it does not establish whether writes
  into an existing video have finished. Do not use a quiet period or unchanged
  file size as proof of download completion. Preallocation and paused downloads
  make these heuristics unreliable; successful probing is not proof either.
- A downloader publishing the final filename only after completion provides a
  useful completion boundary. If it writes directly into the final video file,
  Kinrox can discover the file but cannot guarantee completeness from directory
  metadata alone. Document this limitation without adding downloader integration.

## Scope and compatibility

Keep Swift 6 concurrency checking, natural sorting, flat folder scope, symlink
identity, final-frame behavior, and the existing recent-file semantics. Keep each
source file below 500 lines by placing monitor and coalescing logic in
`PlayerMac/PlayerMac/Library/FolderMonitor.swift`.

No new screens, translations, remote protocol version, iOS release requirement,
external requests, dependencies, download management, or recursive video discovery
are planned. External audio/subtitle discovery is a separate subsystem and remains
outside this correction. All filesystem work is read-only in production.

## Regression and verification plan

First add a regression demonstrating that a video added after the initial scan
remains absent from the current model, then run it against the existing behavior.
Prefer real temporary files for the initial failing scenario. Once `FolderMonitor`
exists, drive watcher events, scan errors, and coalescing deterministically
through injected `scan`, `watch`, and `sleep` closures without timing-dependent
sleeps. Record the pre-fix failure and post-fix result; do not substitute a
compilation error for a behavioral regression.

Cover the following behaviors through the existing suites in
`PlayerMac/PlayerMacTests/` and focused monitor tests:

1. Adding episode 2 updates `playlist`, `canNext`, and `playlistCaption` without
   an engine load, seek, pause command, or recent-file insertion.
2. A connected remote receives `canNext = true` immediately without a new
   playback tick; paused playback, final frame, and `NowPlayingController`
   (`.nextTrack` and folder artist) also update.
3. Natural ordering, canonical current-item identity across symlink transitions,
   deletion of a neighbor, and temporary-to-final renaming (`.!qB`, `.part`,
   `.crdownload`) behave correctly. A removed current item remains the playback
   anchor.
4. Event bursts and events arriving during enumeration converge to the latest
   directory contents with at most one scan in flight and one follow-up scan.
5. Stale scan completion after folder switch or `shutdown()` cannot overwrite
   state; cancelling the monitor invokes the `DispatchSource` cancel handler and
   closes its descriptor.
6. Normal EOF with an existing neighbor advances synchronously; EOF when `next`
   was absent (missed watcher event) performs a one-shot rescan and advances once,
   while replay, seek, open, failed scan, or late arrival after the EOF check
   cannot trigger unintended playback.
7. Transient read errors preserve the previous snapshot. Post-wake rescan,
   watcher invalidation (`.delete`/`.rename`), and fallback polling when
   `open(O_EVTONLY)` is unavailable recover without disrupting playback.

Retain existing synchronous assertions in `LibraryTests`, `PlayerCommandsTests`,
`NowPlayingControllerTests`, `RemoteServerTests`, and `RemoteStatePublisherTests`.
Run `./Scripts/generate.sh` after adding new source or test files, run the
focused regressions before and after the fix, then run the full `PlayerMac` test
suite and `xcrun swift-format lint --strict` per `AGENTS.md`, and verify all
touched files stay under 500 lines. Protocol/iOS suites are only required if
implementation changes their code or contracts.

Manually verify local copy, temporary-file rename, paused playback, EOF, wake,
folder replacement, and a connected physical iPhone. Keep Kinrox volume at zero;
do not change system volume. Test-owned temporary artifacts must be isolated from
user files. An actual downloader run is an additional check of that downloader's
publication behavior, not a guarantee for all download clients.

## Acceptance criteria and current results

- A completed file published into a healthy local watched folder appears without
  reopening media (~250 ms coalescing window plus enumeration time). Fallback
  discovery occurs on its 10-second interval when `O_EVTONLY` watching is
  unavailable.
- Mac, Now Playing, and iPhone navigation agree after the update, with unchanged
  current playback and no protocol migration.
- EOF advances immediately when `next` is already known, performs a one-shot
  rescan when `next` is absent or dirty, advances at most once, and never leaves
  a standing trigger that starts a later download unexpectedly.
- Read errors and obsolete asynchronous work cannot clear a valid list, move
  playback, or outlive the player session.
- The incomplete-file limitation is documented and covered by suffix tests.

### Implementation

- `FolderMonitor.swift` registers the vnode stream before enumeration, uses one
  serial scan worker, coalesces changes for 250 ms, retries unavailable watchers
  at 10 s, and rescans on the workspace wake notification. Descriptor closure is
  confined to the source cancellation handler; weak event-handler capture avoids
  retaining the source in its own handler.
- `FolderPlaylist.scanItems(in:)` distinguishes enumeration failure from an empty
  folder and supplies deterministic natural ordering. Existing synchronous
  `scan(for:)` callers retain their behavior.
- `PlayerViewModel` reconciles each successful snapshot against the latest current
  item in the same canonical folder. Folder generations reject obsolete work;
  failed background reads preserve the last valid list. Only changed snapshots
  notify playback observers. Legacy custom playlist providers remain compatible
  with virtual paths and can explicitly opt into an injected watcher.
- EOF keeps the synchronous path for a clean, reachable neighbor. Otherwise its
  one-shot request shares the monitor worker and returns that request's immutable
  snapshot. A newer publication cannot change the completed EOF decision. User
  playback commands, file changes, media reset, and shutdown cancel pending
  advancement. No iOS or protocol changes were needed.
- Added focused monitor, EOF, filesystem, and observer suites, plus a real libmpv
  playback scenario. Existing synchronous command assertions remain unchanged.
  Playlist test setup now awaits readiness rather than assuming that 200 yields
  are enough to complete an asynchronous directory read.

### Verification evidence

- Before the fix, `FolderPlaylistTests.discoversPublishedEpisode()` failed on
  `canNext`, the next URL, and the playlist caption after a real second file was
  created. Playback, position, pause, and recents assertions remained intact.
  Log: `/tmp/kinrox-live-folder-before-suite.log`. The preceding method-only
  xcodebuild filter selected zero tests; it is not counted as regression evidence.
- After the fix, the focused folder and command suites passed all 14 tests
  (`/tmp/kinrox-live-folder-after.log`). Deterministic monitor/EOF checks then passed.
- Integration checks passed for temporary suffix publication, current-item deletion,
  symlink identity, directory replacement, and connected encrypted remote delivery
  while paused or on the final frame. The first descriptor check compared raw
  Darwin paths with canonical Foundation paths and failed; canonicalizing both
  paths fixed the test, and the filesystem suite then passed all 6 tests
  (`/tmp/kinrox-live-folder-descriptors.log`).
- The real libmpv test copied and renamed an MKV during pause, verified unchanged
  position and zero Kinrox volume, advanced at EOF, then held the final frame when
  another episode appeared later. No Mac system volume changes were made.
- The first full run exposed the old fixed-yield symlink test setup described
  above. After replacing that wait, all 121 tests in 25 suites passed
  (`/tmp/kinrox-live-folder-full-final.log`). After the snapshot-isolation change,
  the final full run passed **122 tests in 25 suites** with exit status 0
  (`/tmp/kinrox-live-folder-verified.log`). Result bundle:
  `DerivedData/Logs/Test/Test-PlayerMac-2026.10.29_21-11-34-+0700.xcresult`.
- `./Scripts/generate.sh` completed successfully. Final verification commands:

  ```sh
  xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath DerivedData test
  xcrun swift-format lint --strict --recursive PlayerMac RemoteiOS Packages Shared
  git diff --check
  ```

  All exited successfully. The strict lint produced no diagnostics after fixing
  a new test's acronym capitalization. All files changed for this task are below
  500 lines (largest Swift file: `PlayerViewModel.swift`, 315 lines).
  Protocol and iOS suites were not rerun because their code and contracts did not
  change. The `DONE - ` prefix records completed implementation and automated
  verification; it does not imply a release or completion of the manual limits below.

### Remaining limits

- A physical iPhone is visible to `devicectl` but requires passcode unlock. Its
  screen and controls were not manually verified in this session. Automated
  tests did pair a real `TransportClient` with `RemoteServer` over the encrypted
  local connection and verify delivery without a playback tick.
- Wake handling was tested by posting `NSWorkspace.didWakeNotification`; an actual
  Mac sleep/wake cycle was not performed. Directory replacement and descriptor
  closure used real filesystem events. Fallback timing used the injected clock.
- No actual downloader was run. Direct writes to a final video filename still do
  not prove download completion. No downloader integration was added.
- Runtime checks used this Mac's macOS 26 environment and Homebrew libmpv. The
  existing warning about linking a macOS 26 library with a macOS 14 deployment
  target remains a development-environment limitation; release packaging is
  unchanged. No new macOS 14 hardware run, iOS build, or release was performed.
- Existing unrelated working-tree changes were preserved. No commit, deployment,
  independent review, or release was created.

## References

- [Apple: Dispatch Sources](https://developer.apple.com/library/archive/documentation/General/Conceptual/ConcurrencyProgrammingGuide/GCDWorkQueues/GCDWorkQueues.html)
  — filesystem monitoring, event coalescing, and descriptor cancellation.
- [Apple: Using the File System Events API](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)
  — directory rescanning and the advisory nature of notifications; architectural
  background, not a requirement to use FSEvents in this implementation.
- [qBittorrent: Explanation of Options](https://github.com/qbittorrent/qBittorrent/wiki/Explanation-of-Options-in-qBittorrent/82a236fd31adc6419eb1338f653cd9e57d0a05f0)
  — incomplete-file suffix and preallocation options. The owner's downloader and
  its settings have not been identified.
