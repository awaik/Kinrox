# M2 Review Analysis — 2026-10-26

Review verified against the working tree, macOS 26.5 SDK, libmpv headers, and automated test suites. Existing modifications preserved; no commits created.

| No. | Decision and Verification |
|---|---|
| 1 | Resolved. `RecentFilesStore.noteOpened` is triggered after `.loaded`; it invokes the system recents handler forwarded from AppDelegate. Next/previous and auto-advance share the same code path. Loading failure clears active URL and playlist. Duration retrieved prior to `.loaded` is preserved. `currentURL` before confirmation represents the requested URL for loading UI and folder navigation. Verified with fake engine and real libmpv decode error. |
| 2 | Partially confirmed, resolved. Duplicate entries and missed duration updates reproduced. Assertion regarding writing upon **every** `refreshAvailability()` was too broad: `refresh` was already updating saved paths. Shared `VideoFiles.key` resolves symlinks in recents, playlist, and UI highlight. Re-opening preserves item ID and removes duplicate paths. |
| 3 | Resolved. Real symlink to temp folder reproduced dropped folder playlist. Fast path uses `FolderPlaylist.index(of:)` using the same key as constructor. |
| 4 | Resolved with refined approach. `setPaused(false)` restarts playback from start on EOF. Dedicated `requestedPause` and `replayPending` accommodate rapid inputs prior to event loop delivery. Resetting `endReached` alone was insufficient due to stale `paused` state. Displayed pause/EOF state reflects engine source of truth. |
| 5 | Test adjusted; `VideoLayer` logic preserved. Original test failed because window was occluded: `isVisible == true` but `occlusionState` lacked `.visible`. Passing test requires test window raised to floating level and visible in active Space. Explicit visibility assertion added; checks for four distinct dimensions and scale retained. Resize of hidden window during pause verified. |
| 6 | Resolved. Finder action resolves URL through `RecentFilesStore.resolve` on click. If file disappeared, availability is updated. Bookmark validation uses previous record immediately after rename, prior to `refreshAvailability`. |
| 7 | Resolved. `onChange(initial: true)` dismisses already expired prompt upon first display. Regression test embeds real `PairingCodeView` in `NSHostingView`. |
| 8 | Resolved. Panel presentation, mouse exit, and controller deallocation restore system cursor. Error, pairing, and EOF states inhibit auto-hiding controls. Test verifies hide timer, recovery upon pause, user interaction, cursor exit, and controller release. |

In Item 5, `isVisible` does not substitute for occlusion checks — documented in [Apple documentation on occlusionState](https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.property). Item 8 utilizes paired [`setHiddenUntilMouseMoves(false)`](https://developer.apple.com/documentation/appkit/nscursor/sethiddenuntilmousemoves(_:)) instead of `NSCursor.unhide()`.

## Verifications

- Prior to fixes: PlayerMac failed 3 resize tests; recents, symlinks, rapid replay, and expired PIN regressions reproduced failures.
- Following fixes: `xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData build test` — **39 tests passed, TEST SUCCEEDED**.
- `xcrun swift-format lint --strict --recursive PlayerMac RemoteiOS Packages Shared` passed cleanly.
- `bash -n` on all shell scripts, 500-line ceiling, and `git diff --check` passed.
- Single linker warning: known Homebrew libmpv deployment target discrepancy.
