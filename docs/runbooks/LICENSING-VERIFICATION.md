# Licensing policy verification — November 1, 2026

## Authorized scope

The owner requested branding protection, preservation of attribution and clear
modified-build notices, and a prohibition on commercial use of the iPhone remote.
The owner explicitly selected free forks with corresponding source and change
notices. Dependency composition and the Mac player's GPL license are unchanged.

Policy documents:

- [Component scope and transition](../../LICENSING.md)
- [Remote Personal Use License 1.0](../../RemoteiOS/LICENSE.txt)
- [GPL shared-code exception](../../SHARED-LICENSE-EXCEPTION.md)
- [Attribution and origin notice](../../NOTICE)
- [Trademark policy](../../TRADEMARKS.md)

The root GPL text is unchanged. The new restrictions do not revoke earlier GPL
grants, apply to the Mac player, or alter third-party licenses. The shared-code
exception is limited to Kinrox-owned material at the listed paths and preserves
independent GPL rights to those components. Contributor requirements now reflect
that permission and the remote license.

The inspected Git history listed one author, `awaik`. No conflicting third-party
license notice was found in the remote/shared Swift source during the targeted
inspection. This is provenance evidence, not proof of ownership or a complete
legal audit of every asset. No trademark registration is asserted.

## Implementation

- The shared link catalog selects a GPL description and licensing overview on
  Mac, and a personal-use description and direct remote-license link on iPhone.
- Both Debug and Release builds bundle GPL, attribution, branding, scope, and
  shared-permission documents. Remote builds also bundle their own license.
- App summaries and landing-page licensing copy cover all 30 existing locales.
  The website no longer describes both apps as GPL/open-source; its JSON-LD GPL
  record is scoped to the existing downloadable Mac 0.3.0 DMG.
- Earlier release reports and the already submitted App Store build retain their
  historical record. The next store release has a [separate rollout checklist](../../AppStore/LICENSE-ROLLOUT.md).

## Checks completed

| Check | Result |
| --- | --- |
| XcodeGen regeneration | Both projects generated successfully |
| Mac Debug build and tests | 142 tests in 31 suites passed |
| iPhone Debug build and tests, iOS 26.5 simulator | 55 tests in 11 suites passed |
| Mac Release build | Passed |
| iPhone Release simulator build | Passed |
| Runtime license selection and bundled-document tests | Passed on both platforms |
| Bundled document comparison against source | All four build/configuration combinations matched |
| `python3 Scripts/check-localization.py` | 30 locales, 320 UI keys at verification time |
| `python3 -m unittest discover -s Scripts/tests -p test_site_localization.py` | 8 tests passed |
| Offline website generation and `--check` | 90 pages verified; only the 30 landing pages changed |
| Swift formatting for touched Swift files | Passed |
| `git diff --check` and local documentation links | Passed |

Visual inspection: Russian iPhone Settings in demo mode shows the complete
noncommercial-use description and the personal-use license row without clipping.
English desktop and Russian/Arabic mobile landing layouts were inspected;
390-pixel mobile pages had no horizontal overflow, including RTL Arabic.

The first iOS test attempt stalled during initial simulator startup and was
interrupted. The task-created simulator was restarted without erasing it; the
complete retry passed. An existing Mac About test was updated to the renamed
license-description property before the successful full test run.

Logs and Xcode result bundles are retained in the ignored task directory
`DerivedData/Licensing-20261101-n3pt037f/`; the dedicated simulator is
`DC2B57F1-E9E8-4817-BEE1-491F39626D99`. Existing unrelated music-mode and research
changes were preserved.

## Release boundaries

Follow-up review on November 1 found that RemoteiOS also links `MusicCore`.
Its Kinrox-owned source path, `Packages/KinroxMusic/Sources/MusicCore/`, is now
included in the existing shared-code permission, scope table and contributor
terms. The Mac-only `SpotifyWebAPI` path is explicitly excluded. This follows the
already authorized shared-component policy and the additional-permission
mechanism in [GPL v3 section 7](https://www.gnu.org/licenses/gpl.en.html#section7).
The new bundled-scope regression failed before the correction and passed in
both app suites afterward (169 Mac tests, 59 iPhone simulator tests). Logs and
remaining verification limits are in the [music review record](MUSIC-VERIFICATION.md#external-review-corrections--november-1-2026).

No commit, push, live website deployment, App Store change, archive upload, or
release publication was performed. Version/build values were not advanced.
Before shipping a new remote, review the custom license and exact code/asset
rights, configure a compatible custom App Store EULA with the actual developer
details, and verify the new archive under the normal release workflow. The
repository license alone does not replace Apple's store agreement. Translated
summaries are explanatory; the English license is the legal document.
