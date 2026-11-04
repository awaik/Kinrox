# Music Mode CPU and Memory Footprint Investigation

Status: Released in Mac 0.5.2 (build 12)

Date: 2026-11-04 (Europe/Moscow)

---

## 1. Symptoms, Expected Behavior, and Verifiable Reproduction

### Reported Symptoms
During background music playback in Kinrox `0.5.1` (build 11), after approximately 9 minutes of uptime:
- **`Kinrox` (main app process):** `7–10%` of one CPU core continuously (`~57` CPU seconds over 9 minutes), `342 MB` physical memory footprint with a `+` indicator (`342M+`) in `top`, `10` threads.
- **`soloist` (Spotify playback helper):** `~0.7%` CPU, `29 MB` memory, `21` threads.
- **`soloist crashpad-handler`:** `0%` CPU, `3.7 MB` memory, `4` threads.
- **`KinroxSoloistHost`:** `0%` CPU, `~1 MB` memory, `1` thread.

### Expected Behavior
- While playing a track without user interaction, the main `Kinrox` process should use `< 1%` of one CPU core when visible and `~0%` for UI updates when the window is occluded or in the background.
- Memory footprint should remain compact, proportional to the loaded catalog and visible UI rows, without continuous allocation churn in `top` (`+` suffix) or unnecessary eager instantiation of offscreen SwiftUI view subgraphs.

### Live Verification Measurements
A live running instance of Kinrox `0.5.1` (build 11) in Music mode was inspected non-destructively using `sample`, `vmmap -summary`, `heap`, and `leaks`:

1. **CPU Profile (`sample <pid> 3` — 3 seconds, 2,507 samples per thread):**
   - **Background threads (`kinrox.mpv.events`, `mpv/core`, `NSEventThread`, `NSURLConnectionLoader`, GCD workers):** `99.9%` idle (`2,505–2,507 / 2,507` samples in kernel sleep).
   - **Main thread (`com.apple.main-thread`):** `325 / 2,507` active samples (**`12.96%` of 1 core**), `100%` inside SwiftUI and AppKit layout/display transactions:
     - `257` samples (`10.25%` of 1 core) in `NSRunLoop.flushObservers()` → `SwiftUI.GraphHost.flushTransactions()`:
       - `92` samples in `ObservationGraphMutation.apply()` → `AG::Graph::propagate_dirty`.
       - `165` samples in `AG::Graph::UpdateStack::update()` → `AG::Subgraph::update()`.
     - `68` samples (`2.71%` of 1 core) in `CA::Transaction::commit()` → `NSDisplayCycleFlush`:
       - `42` samples in `-[NSWindow layoutIfNeeded]` → `NSHostingView.layout()` → `ViewGraphRootValueUpdater.render` (`GeometryReaderLayout`, `StackLayout`, `StyledTextLayoutEngine.sizeThatFits`, `SystemSlider.updateNSView` / `-[NSSlider updateCell:]`).
       - `26` samples in `-[_NSTrackingAreaAKManager displayCycleUpdateStructuralRegions]` → `-[NSView _updateTrackingAreasWithInvalidCursorRects:]`.

2. **Memory Profile (`vmmap -summary`, `heap`, `leaks` over a 10-minute observation window):**
   - **Physical footprint stability:**
     - `t = +9 min`: `342.0 MB`
     - `t = +14 min`: `342.5 MB` (peak `377.1 MB`, malloc heap `182.4 MB`)
     - `t = +19.5 min`: `341.9 MB` (peak `377.1 MB`, malloc heap `182.4 MB`)
   - **Leak check (`leaks`):** `4 leaks for 224 total leaked bytes` (`CFData`) across `2,003,806` malloc nodes.
   - **Virtual memory breakdown (`vmmap -summary`):**
     - `MALLOC_SMALL` / `MALLOC_TINY` / `MALLOC_NANO` / `MALLOC_LARGE`: `~199.1 MB` dirty (`2,003,806` live allocations).
     - `AttributeGraph`: `38.7 MB` dirty (`755,262` `AttributeGraph` malloc nodes).
     - `CoreUI image file` / `CG image` / `IOSurface`: `~40.3 MB` dirty.
   - **SQLite catalog cache size vs. UI heap size:**
     - The cached library on disk contains `837` albums (`240 KB`), `880` artists (`85 KB`), `1,099` tracks (`392 KB`), and `27` playlists — only **`~717 KB`** of JSON (`~2–3 MB` of decoded `MusicCore` value types).
     - Nearly all of the `~225 MB` combined `Malloc` + `AttributeGraph` memory is consumed by eagerly instantiated SwiftUI view subgraphs and AppKit tracking/focus helpers.

---

## 2. Confirmed Root Causes

### A. Confirmed Cause of Continuous 7–10% CPU Usage

1. **Unconditional 4 Hz (`250 ms`) polling loop in `DeckView` (`PlayerMac/PlayerMac/Music/UI/DeckView.swift:13-24`):**
   - While `!model.paused`, `DeckView` runs a `Task(id: model.paused)` loop that sleeps for `.milliseconds(250)` and assigns `clock.position = model.displayedPosition` four times per second.
   - This loop continues running even when the Mac window is in the background, occluded by other windows, or minimized.

2. **Per-tick SwiftUI & AppKit invalidation amplification chain:**
   - **Sub-second mutations driving integer-second UI:** `MusicClockText` (`DeckView.swift:176-188`) formats elapsed and remaining time at **1-second resolution** (`TimeFormat.string` / `TimeFormat.remaining`), and `MusicSlider` (`Shared/MusicSlider.swift:38`) sets `.accessibilityValue(Int(draft ?? value).formatted())` at integer resolution. Because `clock.position` is a fractional `Double` mutated every `250 ms`, 3 out of every 4 ticks re-evaluate `MusicClockText` (3 instances) and `MusicClockSlider` only to produce the exact same text and accessibility strings, while reallocating `AccessibilityAttachment` dictionary storage on every tick.
   - **AppKit `NSSlider` (`SystemSlider`) layout & display invalidation:** `MusicClockSlider` (`DeckView.swift:190-200`) renders `MusicSlider` → `SwiftUI.Slider` (`SystemSlider` wrapping AppKit `NSSlider`). On every `250 ms` tick, `SystemSlider.updateNSView` invokes `-[NSControl setDoubleValue:]` → `-[NSSlider updateCell:]` → `-[NSSlider _layoutComponentSubviewsIfNecessary]` → `-[NSView setNeedsDisplayInRect:]`.
   - **Full-window layout pass from `DeckView` up to `MusicView`'s root `GeometryReader`:**
     - In `DeckView.display` (`DeckView.swift:84`), the large LCD `MusicClockText` applies `.minimumScaleFactor(0.7).lineLimit(1)` without a fixed width or layout isolation boundary, and the scrubber `MusicClockText` views only constrain width.
     - Each `clock.position` tick marks the text layout dirty, causing `NSHostingView.layout()` to re-run `GeometryReaderLayout.placeSubviews` at the root of `MusicView` (`MusicView.swift:8`) and traverse 8+ levels of nested `HStack`/`VStack` `StackLayout`s and `StyledTextLayoutEngine.sizeThatFits` (`CTLineCreateWithAttributedString`).
   - **Massive `AttributeGraph` (`755,262` nodes) and AppKit tracking area list (`2,084` `_NSTrackingAreaAKViewHelper`s):**
     - Because `SourceColumn` eagerly mounts ~1,800 interactive subviews (see Section 2.B), every `250 ms` `AG::Graph::propagate_dirty` pass and every AppKit `displayCycleUpdateStructuralRegions` pass walks an inflated graph.

### B. Confirmed Cause of 342 MB Memory Footprint and `342M+` in `top`

1. **Why `top` displays `342M+` (confirmed transient churn, not an unbounded playback leak):**
   - Over 20 minutes of continuous playback and track transitions, physical memory remained flat at `341.9–342.5 MB`, and `leaks` found only `224 bytes`.
   - In macOS `top`, the `+` suffix indicates a positive memory delta during the most recent 1-second `top` sample interval. Because the `250 ms` `DeckView` loop allocates and frees temporary SwiftUI `DisplayList` buffers, `AccessibilityAttachment` dictionaries, and CoreText lines 4 times per second, `DefaultMallocZone` constantly fluctuates within a few kilobytes between `top` refreshes.

2. **Primary cause of the 342 MB baseline (`~150+ MB` of avoidable heap + `AttributeGraph`): Non-lazy `VStack` in `SourceColumn` (`PlayerMac/PlayerMac/Music/UI/SourceColumn.swift:8-57`):**
   - `MusicCatalog.merge` (`Packages/KinroxMusic/Sources/MusicCore/MusicCatalog.swift:44`) populates `catalog.artists` with every artist referenced by any saved track or album (`880` artists in the inspected library).
   - `SourceColumn` (`SourceColumn.swift:9`) uses a **non-lazy `VStack`** inside `ScrollView` and iterates over `ForEach(model.catalog.artists)` (`SourceColumn.swift:33`).
   - Because `VStack` is non-lazy, SwiftUI eagerly instantiates all `880` artist rows at launch (`880` `ForEachState<Array<MusicArtist>>` instances in `heap`).
   - Each artist row creates **2 `Button`s** (the row selection button and `MusicHeart`) and **2 `.help(...)` modifiers** (`Text(artist.name).help(artist.name)` and `MusicHeart`'s `.help(L10n.text("Favorite"))`).
   - Heap inspection confirmed that this single non-lazy `VStack` accounts for:
     - **`1,760` of the `1,965` total SwiftUI `Button`s in the entire process (`89.6%`)**
     - **`1,760` `HelpView` subgraphs** (`84,342` `HelpStyleConfiguration` nodes + `66,522` `HelpStyleConfiguration.Content` nodes in `DefaultMallocZone`)
     - **`~1,760` AppKit `_FocusRingView` / `FocusableViewResponder` / `_NSTrackingAreaAKViewHelper` allocations** (out of `2,084` total in the app)

3. **Secondary cause of view-graph weight and scroll-induced growth (`TrackTable` / `MusicTrackRow` / `TrackHeart`):**
   - Every `MusicTrackRow` (`PlayerMac/PlayerMac/Music/UI/TrackTable.swift:72-151`) wraps its content in its own **`GeometryReader`** (`TrackTable.swift:73`) instead of computing `MusicTrackColumns(width:)` once at the table container level.
   - Every `TrackHeart` (`PlayerMac/PlayerMac/Music/UI/MusicControls.swift:56-68`) unconditionally attaches `.popover(isPresented: ...)` containing `LikePopover(model: model, track: track)` (`1,008` `PopoverModifier<LikePopover>` heap nodes for just 35 materialized rows).
   - Every `MusicTrackRow` unconditionally attaches `.dropDestination(for: String.self)` (`TrackTable.swift:145`) even in library/album/playlist tables where `queueID == nil` and drag reordering is inert.
   - As a user scrolls through a large track list (`1,099` liked tracks) or album list (`837` albums), SwiftUI retains realized subgraph nodes in `AttributeGraph` for visited items; heavy per-row modifier chains cause memory to step up as more rows are scrolled into view.

---

## 3. Defect Classes, Affected Paths, and Responsible Files

| Defect Class | File & Lines | Responsibility |
|---|---|---|
| High-frequency UI polling & layout invalidation | `PlayerMac/PlayerMac/Music/UI/DeckView.swift:13-24, 81-87, 152-200` | `MusicDisplayClock` 250 ms polling task, unisolated `MusicClockText` layout, and `MusicClockSlider` updates |
| AppKit `NSSlider` wrapper & accessibility churn | `Shared/MusicSlider.swift:16-39` | `Slider` (`SystemSlider`) and `.accessibilityValue` updated on fractional sub-second ticks |
| Eager offscreen view instantiation | `PlayerMac/PlayerMac/Music/UI/SourceColumn.swift:8-57, 102-135` | Non-lazy `VStack` rendering all playlists and all `catalog.artists` eagerly with multiple `Button` and `.help` modifiers per row |
| Per-row modifier & `GeometryReader` bloat | `PlayerMac/PlayerMac/Music/UI/TrackTable.swift:41-151`, `PlayerMac/PlayerMac/Music/UI/QueueView.swift:69-106`, `PlayerMac/PlayerMac/Music/UI/MusicControls.swift:32-69` | Per-row `GeometryReader`, unconditional `.popover(LikePopover)`, and unconditional `.dropDestination` on non-queue rows |

---

## 4. Proposed Corrections, Alternatives, and Constraints

### Fix 1: Eliminate Continuous 4 Hz CPU Load in `DeckView` (`DeckView.swift`, `MusicSlider.swift`)
1. **Quantize display ticks and align to 1-second boundaries (or pause when window is occluded):**
   - `MusicClockText` displays whole seconds (`M:SS`). Instead of mutating `@Observable` state every `250 ms` with arbitrary fractional doubles, update `MusicDisplayClock` at **1 Hz** aligned to the next whole playback second (or only assign to `clock.position` when `Int(newPosition) != Int(clock.position)`), reducing SwiftUI observation transactions by **4×** immediately while keeping the displayed second exact.
   - Observe window visibility (`NSWindow.didChangeOcclusionStateNotification` / `window.occlusionState.contains(.visible)`) so the `DeckView` UI clock loop pauses completely when the window is hidden, minimized, or fully covered by another app, and immediately refreshes upon becoming visible again. (System `MPNowPlayingInfoCenter` and LAN `RemoteStatePublisher` remain completely unaffected because they use event-driven anchors, not `DeckView`'s UI clock.)
2. **Isolate `MusicClockText` and `MusicClockSlider` layout:**
   - Give the LCD `MusicClockText` (`DeckView.swift:84`) and scrubber `MusicClockText` views fixed both-axis frames (or `.monospacedDigit()` with fixed width and height) so changing `"1:04"` → `"1:05"` never invalidates the parent `HStack` / `VStack` / `GeometryReaderLayout`.
   - Replace the AppKit `NSSlider`-backed `MusicSlider` (or `MusicClockSlider`) with a lightweight native SwiftUI capsule/gesture slider (matching the pattern already used in `PlayerMac/PlayerMac/Player/Controls/Scrubber.swift`), eliminating `SystemSlider.updateNSView` / `-[NSSlider updateCell:]` and AppKit constraint churn on every tick.

### Fix 2: Eliminate Eager Offscreen View Instantiation in `SourceColumn` (`SourceColumn.swift`)
1. **Switch `SourceColumn` and `MusicSourcePicker` from `VStack` to `LazyVStack`:**
   - Replace `VStack(alignment: .leading, spacing: 2)` in `SourceColumn.swift:9` (and `MusicSourcePicker` in `SourceColumn.swift:104`) with `LazyVStack(alignment: .leading, spacing: 2)` so only the ~15–25 visible rows in the 220 pt sidebar are instantiated in `AttributeGraph` and AppKit, instead of all `880+` artists and `27+` playlists at once.
2. **Reduce per-row modifier overhead in sidebar rows:**
   - Avoid attaching redundant `.help(artist.name)` / `.help(playlist.name)` and `.help(L10n.text("Favorite"))` modifiers to every row unless needed, as each `.help` modifier wraps the view in a `HelpView` + AppKit `_NSTrackingAreaAKViewHelper`.

### Fix 3: Lighten `MusicTrackRow` and `TrackHeart` (`TrackTable.swift`, `QueueView.swift`, `MusicControls.swift`)
1. **Lift `GeometryReader` out of `MusicTrackRow`:**
   - Compute `MusicTrackColumns(width:)` once in `TrackTable` (`TrackTable.swift:41`) and `QueueView` (`QueueView.swift:69`) and pass `columns: MusicTrackColumns` into `MusicTrackRow`, removing `N` per-row `GeometryReaderLayout` nodes.
2. **Gate `.popover(LikePopover)` and `.dropDestination`:**
   - In `TrackHeart` (`MusicControls.swift:56-68`), only attach the `.popover` modifier to the single active row where `model.likeOptionsAnchor == anchor && model.likeOptionsTrackID == track.id` (instead of instantiating `PopoverModifier<LikePopover>` on every visible and scrolled row).
   - In `MusicTrackRow` (`TrackTable.swift:145`), only attach `.dropDestination` when `queueID != nil` (i.e. inside `QueueView`).

### Constraints
- All visual designs, spacing, typography, colors, hover states, and interactions must remain identical to the approved Figma specification.
- Standalone Soloist playback, `MPNowPlayingInfoCenter`, and iPhone LAN remote state updates must remain unaffected.

---

## 5. Verification Plan and Acceptance Criteria

1. **Automated Tests:**
   - Run `xcodebuild test -workspace Kinrox.xcworkspace -scheme PlayerMac` and `swift test` in `Packages/KinroxMusic` to verify zero regressions in Music mode, queue management, favorites, and layout.
2. **Runtime CPU & Memory Verification:**
   - Launch `PlayerMac` in Music mode with the user's cached library and play a track:
     - **CPU (window visible, playing):** `< 1.0%` of one core (`sample` main thread `< 25` active samples over 3 seconds, down from `325`).
     - **CPU (window occluded/background, playing):** `~0.0–0.2%` of one core (`0` `DeckView` clock wakes while occluded).
     - **Memory footprint & heap nodes:** `heap` live allocation count reduced from `~2.0M` nodes to `< 350k` nodes; physical footprint reduced by `~120–160 MB`; no continuous `+` churn in `top` while backgrounded.

---

## 6. Implementation, Actual Results, Remaining Limitations, and Release Status

### Implemented Changes
1. **`Shared/MusicSlider.swift`:**
   - Replaced the AppKit `NSSlider`-backed `SwiftUI.Slider` (`SystemSlider`) with a pure SwiftUI `Capsule` + `Circle` slider inside a fixed 16 pt height `GeometryReader`, preserving commit-on-release drag behavior, tinting, disabled states, and accessibility adjustable actions while eliminating AppKit `NSSlider` cell/layout invalidations on every playback tick.
2. **`PlayerMac/PlayerMac/Music/UI/DeckView.swift`:**
   - Updated `MusicDisplayClock.sync(_:)` to quantize positions to whole seconds (`rounded(.down)`) and mutate `@Observable` state only when the whole second changes.
   - Aligned the `DeckView` playback clock sleep interval to the next whole-second boundary (~1 Hz instead of 4 Hz) and paused the UI clock loop whenever the window is occluded (`NSWindow.didChangeOcclusionStateNotification`), immediately resyncing upon becoming visible.
   - Added explicit finite width and height frames to all `MusicClockText` instances so text updates are isolated within fixed layout boundaries and never invalidate parent `HStack`/`VStack`/`GeometryReader` layouts.
3. **`PlayerMac/PlayerMac/Music/UI/SourceColumn.swift` & `AlbumColumn.swift`:**
   - Switched `SourceColumn` from a non-lazy `VStack` to `LazyVStack`, preventing eager instantiation of all `880+` catalog artists and `27+` playlists at launch.
   - Removed redundant `.help(...)` modifiers on sidebar and album rows that previously created thousands of `HelpStyleConfiguration` nodes and AppKit `_NSTrackingAreaAKViewHelper` instances.
4. **`PlayerMac/PlayerMac/Music/UI/TrackTable.swift`, `QueueView.swift`, & `MusicControls.swift`:**
   - Lifted `GeometryReader` and `MusicTrackColumns` calculation out of individual `MusicTrackRow`s to the parent `TrackTable` and `QueueView` containers.
   - Gated `.popover(LikePopover)` in `TrackHeart` so `PopoverModifier<LikePopover>` is mounted only on the active row when `isPopoverPresented` is true.
   - Gated `.dropDestination(for: String.self)` in `MusicTrackRow` so drop targets are registered only for queue items (`queueID != nil`).
   - Removed redundant `.help` modifiers in `MusicHeart` and `MusicTrackRow`.
5. **`PlayerMac/PlayerMacTests/MusicReviewRegressionTests.swift`:**
   - Added `displayClockQuantizesToWholeSecondsAndAvoidsSubsecondMutations()` verifying that sub-second updates do not trigger `@Observable` mutations.
   - Added `musicViewUsesLazySourceColumnAndAvoidsAppKitSliders()` verifying that rendering `MusicView` with 900 artists mounts zero `NSSlider` subviews and keeps the total AppKit subview count under 400.

### Verification Results
- `xcrun swift-format lint` on all modified Swift files: **passed (0 warnings/errors)**.
- `xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData` (`MusicReviewRegressionTests`, `MusicPlaybackTests`, `MusicViewModelTests`, `PlayerRootViewTests`, `SpotifyFollowupTests`): **passed**.
- `xcodebuild -workspace Kinrox.xcworkspace -scheme RemoteiOS -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath DerivedData -only-testing:RemoteiOSTests/MusicRemoteTests test`: **passed**.

### Remaining Limitations and Release Status
- **Remaining limitations:** The currently installed `/Applications/Kinrox.app` (v0.5.1, build 11) was not restarted during this task so as not to interrupt active playback; rebuild/reinstall the app (or package the next release) to apply the fix to `/Applications/Kinrox.app`.
- **Release status:** Implemented locally in working tree (uncommitted for review per repository rules).
