# Release tooling review

Status: complete; all six findings addressed, with the research file preserved.
Scope: six external review findings about local release tooling and documentation.
No application playback, update UI, protocol, or publication changes are planned.

## Findings and decisions

1. **App Store submission metadata loss — fix.** `Scripts/prepare-app-store.py`
   writes a fresh manifest during documented regeneration. This resets the recorded
   submission status and drops the App Store ID, submitted version/build/time, and
   release type. Regeneration must refresh generated metadata while preserving
   delivery records. Reproduce in a temporary project seeded with a submitted
   manifest; also cover first generation and read-only `--check`.
2. **Release notes HTML — fix.** `Scripts/update-appcast.py` only converts absolute
   HTTP links, although `docs/releases/0.2.0.md` uses a relative verification link.
   Its successive substitutions also interpret Markdown inside code and do not
   escape quotes in href attributes. Resolve relative links against the matching
   repository tag, escape each HTML context, and keep code literal. Retain the
   existing small Markdown subset without introducing a rendering dependency.
3. **Release ordering and late validation — fix.** The appcast generator only
   rejects equal marketing versions and non-increasing builds. An older marketing
   version with a higher build is accepted, and an empty feed bypasses input
   validation. Add shared numeric version/build checks and a read-only CLI check.
   `Scripts/build-release.sh` must run that check before creating a release
   directory, preparing dependencies, generating projects, or calling Apple tools.
   Keep final validation as well, since the feed can change during a build.
   This is the repository's single stable release stream; separate maintenance
   channels and rereleasing the same marketing version are outside this change.
4. **Research documentation language — fix, preserve file.** The affected file is
   `docs/RESEARCHES/README.md`, not the English root README. Translate its existing
   workflow to English, correct `REVEIWED`, use a Kinrox example, and link the
   directory from the project layout and runbook index. Deleting or ignoring the
   user's research instructions is unnecessary. No regression test is needed for
   this editorial change.
5. **Incomplete review contact — fix.** `fastlane/verify_store.rb` uses `fetch` for
   each required field, raising before its aggregate JSON report is written.
   Missing or blank fields must produce report errors while verification continues.
   Extend the existing offline verification doubles; do not contact Apple.
6. **Missing project generation in iOS build — fix.** `fastlane/Fastfile` archives
   from ignored generated projects without invoking `Scripts/generate.sh`.
   Generate first and stop if generation fails. Exercise the actual lane with
   offline action doubles, including failure before provisioning or archiving.

## Validation and acceptance

Add behavioral regressions first and record their failures before applying fixes.
Then run all Python script tests, offline Ruby tests, metadata consistency checks,
Swift formatting, shell/Ruby syntax, and source length checks under the task
verification runbook. Existing user changes and release artifacts are preserved.
Do not run a real notarization, signed App Store archive, upload, or live API
verification for this local tooling review. No independent review is launched.

Completion requires all applicable fixes, passing focused checks, updated command
documentation, and explicit verification boundaries. Changes remain uncommitted;
no release or deployment is part of this task.

## Regression evidence before implementation

- Python suite: 28 tests, 16 failures including parameterized cases. Reproduced
  submission status reset, raw relative Markdown, interpreted Markdown inside code,
  unescaped href quotes, invalid values accepted on an empty feed, version downgrade
  acceptance, missing check mode, and late rejection in the release entry point.
- Ruby verification: four tests, one failure. Incomplete contact raised `KeyError`
  for `last_name` instead of writing the aggregate report.
- Ruby build lane: two tests, both failed. No project generation occurred and
  a simulated generation failure could not prevent provisioning/archive actions.
- Existing valid-input script tests continued to pass. These runs used only
  temporary fixtures and offline doubles, without signing or contacting Apple.

## Implementation and final verification

The generator now loads the existing manifest before regeneration and preserves
delivery fields, including unknown future record fields. Relative release-note
links use the matching repository tag; HTML attributes are escaped separately;
inline code stays literal. Appcast validation checks numeric marketing versions
and positive builds even for empty feeds and runs before release artifacts or
external build tools. Final generation rechecks the feed. Missing and blank review
contact fields join the report's error list. The iOS lane generates projects before
provisioning and aborts on generation failure. Documentation reflects these steps.

A follow-up self-check found delimiters inside code nested in bold text or link
labels were still interpreted. A new focused regression failed on that intermediate
implementation; treating code spans atomically in those contexts fixed it. This is
part of the same inline-code defect, not additional Markdown feature scope.

Final checks, all passing:

- `python3 -m unittest discover -s Scripts/tests -v`: 30 tests.
- `ruby -I fastlane -e 'Dir["fastlane/*_test.rb"].sort.each { |path| require_relative path }'`:
  six tests, 44 assertions; no live fastlane or Apple API calls.
- `python3 Scripts/prepare-app-store.py --check`: 30 app languages, 35 store locales.
- `python3 Scripts/update-appcast.py --check --appcast site/appcast.xml --version 0.3.0 --build 5`.
- `python3 Scripts/check-localization.py`: 30 locales, 239 UI keys.
- `xcrun swift-format lint --strict --recursive PlayerMac RemoteiOS Packages Shared`.
- `bash -n` on `check-env.sh`, `generate.sh`, `make-test-media.sh`, and `build-release.sh`.
- `ruby -c` on `fastlane/Fastfile` and `fastlane/verify_store.rb`.
- `git diff --check`; source file length check: 192 files, none over 500 lines.

No application source, project generator, or Xcode configuration was changed by
this review follow-up, so app builds, simulator tests, and protocol tests were not
rerun. The release script and Fastlane lane were exercised with offline tool/action
doubles. Real signed archives, notarization, live App Store Connect verification,
and publication were not run because they would create release artifacts or make
external service calls beyond this local correction task. Existing user changes
remain in place; the recorded App Store submission and live appcast were not changed.
All corrections remain uncommitted and unreleased.
