# About and Help project links

Status: implemented; verification results and environment limitations recorded below.

## Request and evidence

The owner requested active website, GitHub, open-source, license, and customary
project links in the Mac and iPhone apps. The Mac screenshot shows the default
"Help isn't available for Kinrox" alert. `PlayerCommands` supplies no Help group
and no About customization. The iPhone screenshot predates the Privacy Policy and
Support links already present in `SettingsView`; those links must be retained.

## Design and implementation plan

Figma page [06 · About — Project links](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U?node-id=60-304)
specifies the additions before implementation. The local Kinrox colors and text
styles are reused; no suitable reusable native About/list component exists in the
file or its library search results. Keep the standard macOS About panel, including
the app icon and version/build supplied by AppKit. Add attributed, clickable credits
and replace the unavailable Help command with native project link menu items.

The iPhone keeps its existing Settings list and adds open-source information and
the same six links: website, GitHub source, GPL-3.0-only license, support, issues,
and privacy. Use one shared destination catalog and localized labels in all 30
supported locales. External pages open only on explicit activation in the browser.
No automatic requests, analytics, new backend, or license changes are introduced.

## Verification plan and limits

Verify all destinations over HTTPS, preserve text/link attributes in an AppKit
unit test, run both application test suites, localization validation, Swift format,
and source-length checks. Inspect the native About panel and Help menu on Mac and
the Settings section in an iPhone simulator. Do not publish, upload, commit, or
replace an installed physical-device app as part of this source change.
The existing unavailable Help behavior is reproduced by the owner's screenshot
and confirmed by the absent Help command override; this feature extension does
not require a synthetic failing test for unchanged framework behavior.

## Implementation

- `Shared/ProjectLink.swift` owns the six HTTPS destinations and localized labels.
- The Mac About command supplies attributed credits to AppKit's standard panel.
  Help menu buttons open the same destinations with `NSWorkspace.shared.open`.
- iPhone Settings retains its version, protocol, network information, support,
  and privacy destinations, and adds the source, license, website, and issue links
  with a localized open-source explanation. Native `Link` rows open the browser.
- Six new source strings are translated in all 30 supported locales. The exact
  license identifier remains `GPL-3.0-only` in every locale.
- `AboutPanelTests` verifies clickable URL attributes, localized label ranges,
  HTTPS destinations, and nonlinked explanatory text in the generated credits.

## Verification results

- Project generation completed successfully. All six public destinations returned
  HTTP 200. Localization validation passed: 30 locales and 245 UI keys.
- Recursive strict Swift formatting lint and `git diff --check` passed. Each
  changed Swift source is below the 500-line limit.
- Both full Mac test attempts executed 97 tests across 21 suites. The first had
  three failures in `FolderPlaylistTests.symlinkPlaylistSwitch`; the final run had
  five failures in `PlayerCommandsTests.nextPrevious`. Both cases observed a nil
  playlist after a bounded asynchronous fixture wait. Their source was unchanged.
  Focused reruns passed: four tests in FolderPlaylist/About suites and eleven tests
  in PlayerCommands/About suites. The new About test passed in every run. A fully
  green single full-suite run is therefore not claimed.
- Native Mac UI inspection confirmed the About icon, version, description, and
  link elements, plus all six Help entries. End-to-end browser activation could
  not be confirmed through automation: accessibility clicks dismissed the menu
  without an observed browser tab, while coordinate fallback reported a window
  mapping error. Link attributes are covered by the test; actual browser handoff
  remains a manual check.
- iOS test builds compiled, signed, and validated, but two simulator test attempts
  stalled before executing tests. Only this task's hung processes were interrupted;
  their logs include simulator IPC/server errors. A new task-owned iPhone 17
  simulator booted and accepted installation, but launch also stalled and its Home
  screen retained placeholder icons. iPhone visual verification and iOS test
  execution remain unverified because of this simulator limitation.
- A separate iOS simulator build completed with `BUILD SUCCEEDED` using
  `xcodebuild -workspace Kinrox.xcworkspace -scheme RemoteiOS -configuration Debug
  -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData build`.
  Its log is `ios-build.log`; this confirms compilation independently of the
  simulator launch problem.

Detailed build and test logs are preserved in
`DerivedData/AboutLinks-baDg33bw/`. The task-created `Kinrox About Links QA`
simulator (`E94BEFDD-0000-461F-BB48-E8B98A01D905`) is also preserved. No release was
published, no physical-device app was replaced, and no changes were committed.
