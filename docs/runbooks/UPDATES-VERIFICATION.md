# Mac Player Update Reminders

Implemented 2026-10-29 after owner approval of
[Figma page 05](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox?node-id=48-304)
and of option A in [the updates task](../TODO/04-updates.md): Sparkle 2, a custom
"update available" reminder, and Sparkle's standard windows for everything after it.
Not released yet. 0.2.0 cannot detect updates, so the first build with the checker
(planned 0.3.0) must be installed manually once; reminders work from the next release on.

## Behavior

- Sparkle's scheduler checks the appcast in the background at most once per 24 hours
  (`SUScheduledCheckInterval`), counting from the last check across launches. No
  permission prompt is shown (`SUEnableAutomaticChecks`); updates are not installed
  silently unless the user ticks Sparkle's own checkbox (`SUAutomaticallyUpdate = NO`),
  and system profiling is off.
- A scheduled update goes to Kinrox instead of Sparkle's alert (gentle reminders):
  - welcome screen: the full banner above the logo, following the recent-files width;
  - player: the compact pill under the title, only while paused. Nothing appears
    over playing video, in a window or in full screen;
  - Kinrox menu: "Check for Updates…" with a "0.4.0 available" badge.
- "Update" opens Sparkle's standard window with release notes. Download, EdDSA and
  code-signature verification, "Install and Relaunch", install on quit, "Skip This
  Version", and errors are Sparkle's native UI. The approved Figma states Downloading,
  Ready, Error and the Ready pill are therefore not custom views.
- "What's New" opens the release page from the appcast (`fullReleaseNotesLink`).
  × hides the reminder; it does not cancel anything. Sparkle keeps the update session
  open, so the reminder returns with a later scheduled check after a relaunch, no sooner
  than 24 hours after the previous check. The menu badge stays while the update is pending.
- Builds without `SUPublicEDKey` create no updater, show no update UI, and make no
  requests. The owner's key is in `Config/Updates.xcconfig` since 2026-10-29, so local
  builds have an updater too, but Debug builds never run scheduled checks against the
  public feed; only a manual "Check for Updates…" contacts it.

## Implementation

- `Updates/UpdateCenter.swift` — `@Observable` reminder state shared by views and menu.
- `Updates/SparkleUpdater.swift` — `SPUStandardUpdaterController` with
  `SPUStandardUserDriverDelegate` gentle reminders; forwards `canCheckForUpdates`.
- `Updates/UpdateBanner.swift` — `UpdateBanner`, `UpdatePill`, and the pill button,
  matching components `Banner/Update`, `Banner/Update Compact`, and `Button/Pill`.
- `Config/Updates.xcconfig` — feed `https://awaik.github.io/Kinrox/appcast.xml`
  (published from `site/appcast.xml`) and the EdDSA public key.
- `Scripts/update-appcast.py` — adds a signed release item; `build-release.sh` signs
  Sparkle's helpers, embeds its license, and writes `dist/.../appcast.xml`.
- `Scripts/bundle-libmpv.py` — keeps Xcode-embedded frameworks (`@rpath/*.framework`)
  untouched and verifies their architecture and deployment target.

Sparkle 2.10.1 is pinned in `PlayerMac/project.yml` and
`Kinrox.xcworkspace/xcshareddata/swiftpm/Package.resolved` (MIT, compatible with GPL v3).

## Verification on 2026-10-29

Environment: macOS 26.5.2, Xcode 26.5, Debug builds signed with the local Apple
Development team.

| Check | Result |
|---|---|
| `xcodebuild … PlayerMac test` | 96 tests in 20 suites passed (7 new update tests) |
| `python3 -m unittest discover -s Scripts/tests` | 19 tests passed (6 new: appcast, embedded framework) |
| `python3 Scripts/check-localization.py` | 30 locales, 239 keys |
| `xcrun swift-format lint --strict …` | clean |

Local end-to-end run with a throwaway EdDSA key, never stored in the Keychain:
a test 0.3.0 build ran a background check (the Debug feed override starts one at launch)
against a local appcast on `127.0.0.1`, showed the Russian banner,
"Обновить" opened Sparkle's window and dismissed the banner, Sparkle downloaded the
0.4.0 zip, verified it, replaced the app in place, and relaunched it; the codesign
check stayed valid. With 0.5.0 in the feed, the pill was absent during playback,
appeared on pause, and × removed it while the menu badge remained. The menu showed
"Проверить обновления…" with the "есть 0.4.0" badge. Test media had no audio track.
Sparkle defaults and caches written by the test were removed afterwards.

To repeat it, build twice with `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, and
`KINROX_UPDATE_PUBLIC_KEY=<test public key>`, sign the newer zip with
`sign_update --ed-key-file`, serve the feed locally, and launch the older copy with
`KINROX_UPDATE_FEED_URL=http://127.0.0.1:<port>/appcast.xml` (Debug only).

## Not Yet Verified

- A Developer ID release: `build-release.sh` signing of Sparkle's helpers, notarization,
  and an update between two notarized DMGs. Runs with the first release (0.3.0); the
  signing key exists since 2026-10-29 (see [Mac Release](RUNBOOK-RELEASE.md#update-signing-key)).
- The public feed on GitHub Pages; nothing has been published.
- Scheduler timing across real launches (first launch, 24-hour interval); the local run
  started its check explicitly.
- macOS 14 and 15 rendering of the menu badge (the deployment target is macOS 14).

## Release status

Mac 0.3.0 (build 5) ships the first update checker on 2026-10-30.
Users of earlier versions install it manually once. Distribution checks and
validation boundaries are in [0.3.0 Verification](0.3.0-VERIFICATION.md).
