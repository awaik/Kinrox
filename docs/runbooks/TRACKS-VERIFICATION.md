# Mac Audio and Subtitle Selection

Implemented 2026-10-29 following owner approval of
[Figma page 04](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox?node-id=30-304).
This change is included in Mac release 0.2.0 (build 4). The previous 0.1.0 DMG is unchanged.

## Behavior

- The caption-bubble control opens Audio & Subtitles. Embedded tracks show language,
  title, codec, channels, and default/forced flags when supplied by libmpv.
  External tracks show their relative paths. Subtitles can be turned Off.
- Native Audio and Subtitles menus expose the same choices, manual file loading,
  full browser, search scope, and remembering. Control-Command-A/S cycle loaded
  tracks and matching external files; the subtitle cycle includes Off.
- Opening a video indexes recognized audio/subtitle files throughout its directory,
  recursively and off the main actor. A common ancestor folder can be selected when
  companion files live beside the video's directory. Scope and recursion are saved
  per video directory. Discovery never scans outside the selected root.
- The quick list prioritizes the current episode using filename/title/episode/season
  matching. The full browser retains every discovered file, including unmatched files
  and other episodes, with path search, type filters, and folder navigation.
- Discovery reports progress, supports cancellation and refresh, and reports unreadable
  folders. Hidden files, application packages, and symbolic links are skipped.
  A VobSub `.idx`/`.sub` pair is shown once through its index file.
- Discovered files are attached only when selected or when restoring a unique saved
  preference. mpv's automatic sidecar loading is disabled to avoid duplicates.
  Failed sidecars leave playback and the prior selection intact.
- Remembering stores language/title and an external folder/filename pattern, rather
  than ephemeral mpv IDs. Episode numbers may change while language/release labels
  remain stable. A multi-track external file restores the matching stream. Ambiguous
  or missing preferences keep the default track and show an explanation. Off persists;
  disabling remembering clears saved choices for that video directory.
- Playback remains the selection source of truth. Command replies, scan generations,
  and cancellation prevent old requests from selecting a track in a new video.
  File dialogs also reject results belonging to an earlier video.

Recognized extensions are listed in `TrackFileScanner.swift`. Common cases include
MKA, FLAC, AAC, AC3, DTS, M4A, WAV, MP3, SRT, ASS, SSA, VTT, IDX/SUB, and SUP.
File discovery identifies candidates by extension; libmpv validates contents when
the user opens a candidate. Arbitrary filenames cannot always be matched to episodes;
they remain available in the full browser and through Add File.

## Implementation

`TrackController` coordinates discovery, preferences, and commands through
`PlayerEngine`. `MPVTracks` copies the event-owned `track-list` node into Swift values.
Selection uses `aid` / `sid`; external tracks use `audio-add` / `sub-add` in `auto`
mode followed by explicit selection after the corresponding reply and track list.
All asynchronous track commands use nonzero request IDs; unrelated playback commands
retain request ID zero. libmpv 0.41.0 ties track-add commands to playback and aborts
them when playback ends; Kinrox also calls `mpv_abort_async_command` on cancellation.

References: [mpv track manipulation](https://mpv.io/manual/stable/#track-manipulation)
and [mpv 0.41.0 command implementation](https://github.com/mpv-player/mpv/blob/v0.41.0/player/command.c).

UI uses the existing Kinrox palette, fonts, and buttons. Panels scroll at small heights;
the full browser switches from a folder sidebar to a picker at narrow widths.
These responsive adaptations extend the desktop Figma frames. Media shortcuts are
disabled while panels or their file dialogs are open, so search editing does not seek
or resume playback. The obscured playback controls are hidden from accessibility.
All 48 new strings are translated in the existing 30 locale resources.

## Verification

On macOS 26.5.2, Swift 6 complete concurrency checking, Homebrew libmpv 0.41.0:

- PlayerMac build succeeded.
- Full PlayerMac test run: **81 tests in 16 suites passed**. This includes 12 new
  track tests; episode matching additionally covers 9 parameterized examples.
- Real libmpv tests selected two embedded audio languages, embedded subtitles, Off,
  audio three levels deep, and subtitles four levels deep. They verified failed-file
  recovery, no generic playback error, and clean track state after changing videos.
  Playback volume was zero throughout these tests.
- Controller tests cover engine-confirmed selection, new track IDs in the next episode,
  persistence of Off, disabled remembering, reply/list ordering, repeated clicks,
  cancellation, stale scan/load results, failed commands, external multi-stream
  preferences, filename language/release identity, and cycling external subtitles.
- Scanner tests cover recursion disabled/enabled, hidden files, packages, symlink
  cycles, VobSub pairing, and filename/season boundaries.
- Resource validator passed: **30 locales, 231 UI keys**, permission prompts,
  source coverage, and placeholder counts. Shared localization tests passed in the
  Mac app. Whole-tree strict Swift formatting and `git diff --check` passed.
- A built-app UI check used silent synthetic media, muted Kinrox, and paused playback:
  audio/subtitle selection, nested external subtitle loading, native Audio menu,
  full browser, path search, empty search results, Escape, and scope settings.
  Layouts were inspected at 1120×630 and approximately 640×472 points.

Commands (from repository root; generate the base test media first on a fresh clone):

```sh
bash Scripts/make-test-media.sh
xcodegen generate --spec PlayerMac/project.yml
xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData test
python3 Scripts/check-localization.py
xcrun swift-format lint --strict --recursive PlayerMac RemoteiOS Packages Shared
```

The full test result is retained under
`DerivedData/Logs/Test/Test-PlayerMac-2026.10.29_13-50-36-+0700.xcresult`.
The silent manual fixture is in `DerivedData/TracksUI-_zc8h0sn`.

### Review follow-up (2026-10-29)

All seven reported issues were confirmed in the relevant code paths and fixed.
The implementation deliberately narrows two proposed changes: metadata replaces
only explicit episode markers (preserving identities such as `Studio 1` versus
`Studio 2` and channel layouts), and enabling remembering saves only successful
manual choices, rather than all automatically selected defaults.

- Track title signatures retain bracket labels and ignore explicit episode numbers,
  including stream metadata in external multi-track files.
- Missing preferences can be restored after refresh, changing the search root, or
  enabling recursion. Failed restore commands may retry on refresh; successful and
  manual choices are retained. Stop resets per-media restoration state.
- Enabling remembering retains confirmed manual audio/subtitle choices and Off even
  when the selection was completed while remembering was disabled.
- Settings, loaded-media identity, external track identity, and relative paths use
  resolved file paths. Existing settings saved through the original symlink path
  remain readable when that path is opened.
- The controller owns its native file panel, cancels it on stop/media changes/close,
  rejects overlapping sheets, and ignores obsolete callbacks. Opening a video with
  Command-O dismisses the track overlay.
- The folder picker keeps its selected tag during discovery and resets to the root
  when the selected folder is absent from the completed scan.
- The App Store verifier records a missing `fastlane/.env.review.json` in its error
  report instead of failing at `File.read`. Verification remains unsuccessful when
  the contact cannot be checked; no App Store API calls were made for these tests.

Regressions for title identity, external stream restoration, retrying discovery,
remembering, stop/reload, symlinks, and missing review contact failed before the
fixes. After the fixes, the full PlayerMac build/test passed **89 tests in 18 suites**,
including native-panel lifecycle tests and muted real-libmpv integration tests.
Result: `DerivedData/Logs/Test/Run-PlayerMac-2026.10.29_14-48-06-+0700.xcresult`.
The two offline Ruby verifier tests and four existing App Store workflow tests passed.
Environment checks, localization validation, strict whole-tree Swift formatting,
Ruby/shell syntax, the 500-line ceiling, and `git diff --check` passed.

Manual verification used silent media in `DerivedData/ReviewTracksUI-c1znud23`, with
Kinrox volume set to zero. Command-O dismissed the track overlay; in a narrow window,
refresh preserved an existing folder filter and reset it after the fixture folder
was renamed. Advancing to the next episode dismissed the outstanding subtitle-file
panel; controls and a new file panel remained usable afterward. Fixtures were retained.
RemoteiOS and RemoteProtocol were unchanged and their suites were not rerun for this
follow-up. No release build, distribution, or App Store submission was performed.

## Validation boundaries

The new controls are Mac-only; the remote wire protocol and iPhone controls are unchanged.
macOS 14 runtime, network/removable-volume performance, every supported sidecar codec,
and exhaustive visual/native-speaker review of all translations were not checked in
this session. Existing Homebrew macOS deployment-target warnings remain. A release
build, signing, notarization, and a new published DMG are separate from this source change.
