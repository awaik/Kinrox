# Task M3 — System Media Keys and "Now Playing"

> **Status:** Implemented 2026-10-26, changes ready for review. Automated test results and remaining manual checks — [M3 Report](../runbooks/M3-VERIFICATION.md).
> **Assignee:** External agent. **Review & commit:** Owner.
> **Scope:** Compact milestone, 1 logical step.

## Prerequisites

1. Read [AGENTS.md](../../AGENTS.md) in full. Specifically: Section 5 "System Media Keys", Section 3.1 (data flow), Section 4.5 (`PlayerEngine`), Milestone M3 in Section 7, and development guidelines in Section 9.
2. Read [verification runbook](../runbooks/RUNBOOK-TASK-TESTS.md) and [build/signing runbook](../runbooks/RUNBOOK-BUILD-AND-SIGNING.md).
3. Check `git status --short`. Do not touch uncommitted work.

Standard rules: Work strictly on `main`, no git commits or auxiliary branches; Swift 6 strict concurrency; files under 500 lines; comments explain "why"; verify APIs against the SDK, marking unverified items with `// UNVERIFIED:`.

## Objective

The ⏯︎ keyboard media key and macOS Control Center "Now Playing" widget control Kinrox identically to on-screen overlay controls. The widget accurately displays title, duration, and playback position.

**Acceptance Criteria** (from AGENTS.md, M3):

- ⏯︎ on keyboard and in Control Center toggles pause and resume;
- Control Center widget displays title, duration, and elapsed position;
- Position scrubber in Control Center functions properly;
- ⏭︎/⏮︎ switch playlist files in the same folder; disabled at boundary items;
- Without an open file, commands return `.noActionableNowPlayingItem` and widget clears;
- Window closure clears Now Playing (`nowPlayingInfo = nil`, `.stopped`);
- Clean compilation without new warnings, all tests pass.

## Design

No custom screens: widget and media keys adhere to macOS system interface.
Artwork and metadata references:

- Figma: [Kinrox — Design](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U).
- Widget artwork: `KinroxLogo` from `Resources/Branding.xcassets`.
- Title: `PlayerViewModel.displayTitle`; subtitle: folder name from `playlist.folderName` when folder has multiple videos, otherwise "Kinrox".

## Code Organization

| Component | Location |
|---|---|
| Model & State | `PlayerMac/PlayerMac/Player/PlayerViewModel.swift` |
| Commands (pause, seek, next/previous) | `PlayerMac/PlayerMac/Player/PlayerViewModel+Commands.swift` |
| Window & Model Lifecycle | `PlayerMac/PlayerMac/App/AppDelegate.swift`, `App/PlayerSession.swift` |
| Folder Playlist | `PlayerMac/PlayerMac/Library/FolderPlaylist.swift` |
| M3 Implementation | `PlayerMac/PlayerMac/NowPlaying/` |
| Tests | `PlayerMac/PlayerMacTests/` (`FakePlayerEngine`, `FakeNowPlayingCenter`) |

`input-media-keys=no` is configured in libmpv so mpv does not intercept media keys.
