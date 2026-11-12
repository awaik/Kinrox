# General release, stage 3: version, checks, signed build, publication

Make the release: Kinrox Mac {{VERSION}} (build {{BUILD}}), tag `{{TAG}}`, Apple Silicon, macOS 14+.
Release all accumulated changes: every local commit and everything uncommitted in the main checkout.

Repository (main checkout on `main`): {{REPO}}
`origin/main` at review: `{{ORIGIN_SHA}}`; package base: `{{BASE_SHA}}`; `HEAD` checked by the orchestrator: `{{HEAD_SHA}}`.
Run directory: {{RUN_DIR}} - `review.md` (review), `apply-*.last.md` (applied findings), `{{CONTROL_FILE}}` (the orchestrator's control: verdict and release notes), `{{STATUS_RELEASE_FILE}}` (package contents when the release started).
Release directory of the build: `{{DIST_DIR}}`.
Release state file: `{{RELEASE_FILE}}` - maintain it yourself (lines `NAME=value`): `VERSION`, `BUILD`, `PACKAGE_FINGERPRINT`, `CHECKS_DONE`, `BUILD_DONE`, `NOTARIZED`, `DMG_SHA256`, `SOURCE_SHA`, `TAGGED`, `SOURCE_PUSHED`, `RELEASE_PUBLISHED`, `SITE_SHA`, `SITE_PUSHED`, `PAGES_VERIFIED`, `FINALIZED`. On continuation start from it: a finished build, commit, tag, push, or publication is not repeated.

The package passed review, application of findings, and the orchestrator's control. The owner invoked `general-release` for this package; per the skill that is the command to release `{{VERSION}}`: commit, tag, push, public GitHub Release, website, and update feed. The rules in `AGENTS.md` outrank this prompt. Write all documents, commit messages, and diagnostics in English.

## Read first

1. `AGENTS.md` is already in your context (critical requirements, rules for agents, sections 3.3, 3.6, 6, 9, 10) - do not re-read it. Read `docs/runbooks/RUNBOOK-RELEASE.md` in full, `docs/runbooks/RUNBOOK-TASK-TESTS.md`, `docs/runbooks/SOLOIST-VERIFICATION.md` (accepted limits).
2. The previous release as the pattern: `docs/releases/` (latest `*.md`), the latest `docs/runbooks/*-VERIFICATION.md` of a release, `git show --stat` of the previous two release commits (`Release Mac ... [skip ci]` and `Publish Mac ... download pages and signed update feed`).
3. `{{CONTROL_FILE}}` - the orchestrator's notes: excluded files, items for the release notes, limits to record.

## Authority

Allowed in this run:

- in the main checkout: checks, `./Scripts/generate.sh`, `Scripts/build-release.sh {{VERSION}} {{BUILD}}`, `git add`, `git commit` in `main`, `git merge origin/main`, an annotated tag `{{TAG}}`, `git push origin main` and `git push origin {{TAG}}`;
- on GitHub through `gh`: create the release `{{TAG}}` in `awaik/Kinrox` with the DMG, the dependency-sources archive, and `SHA256SUMS.txt`; read workflow runs; `gh workflow run pages.yml --ref main` only when a run for the final commit is missing; anonymous downloads with `curl`;
- reading the live site and feed with `curl`.

Not allowed: `git push --force`, amend, rebase, rewriting published commits or tags; `git reset --hard`, `git clean`, `git stash`, `git restore`/`checkout` of other people's edits; `--no-verify`; new branches or worktrees; deleting or editing an existing release or tag; creating, exporting, printing, or rotating credentials, the Sparkle EdDSA key, certificates, profiles, or notary credentials (the owner manages them; `build-release.sh` reads them from the Keychain); installing the app over the user's copy; the iOS Simulator (rule 11); launching Spotify.app (rule 10); changing Mac system volume; uploading anything to the App Store or TestFlight; touching other repositories; printing secret values into commands, logs, or the answer.

Long commands (checks, `build-release.sh` with notarization) run with a log file in the run directory; wait for completion. If waiting is interrupted, check whether the process is alive and what the log says; never restart blindly - `build-release.sh` refuses to reuse `{{DIST_DIR}}`.

## 1. Check before changing anything

1. Main checkout on `main`, `HEAD` = `{{HEAD_SHA}}`, `git worktree list` shows only the main checkout, no local branches other than `main`, tag `{{TAG}}` absent locally and on origin.
2. The working tree is what the orchestrator checked: `{{FINGERPRINT_CMD}}`. Paths changed after the release started (absent from `{{STATUS_RELEASE_FILE}}` or modified) are unchecked - stop with a question; do not include them silently.
3. Review the package for what must not be committed: credentials, `.env*`, `*.p12`, `*.mobileprovision`, `*.pem`, notary or Sparkle key material, `Config/Signing.local.xcconfig`, `AppStore/` local credential files, `dist/`, `DerivedData/`, `Vendor/`, `.tmp/`, `.build/`, logs, test media, `.DS_Store`, large binaries, and what `{{CONTROL_FILE}}` excluded. Do not commit or delete such files: add masks to `.gitignore` (obvious debris) or ask. Everything else ships - the end state is a clean tree.
4. Signing prerequisites by name only: `APPLE_TEAM_ID`, `APPLE_SIGNING_IDENTITY`, `NOTARYTOOL_PROFILE` are set; `gh auth status` succeeds. A missing one is a question before any build.

## 2. Version and release documents

1. Set `MARKETING_VERSION = {{VERSION}}` and `CURRENT_PROJECT_VERSION = {{BUILD}}` in `Config/PlayerMac.xcconfig`. Run `python3 Scripts/update-appcast.py --check --appcast site/appcast.xml --version {{VERSION}} --build {{BUILD}}`.
2. Write `docs/releases/{{VERSION}}.md` in the format of the previous notes (`What's New`, `Requirements and Notes`). It is shown in Sparkle's window, so describe what a user gains, not file names. Cover every user-visible change of the package (from the commits, the diff, `review.md`, and `{{CONTROL_FILE}}`), including changes to the remote protocol and compatibility with older remotes. Keep the standing notes accurate: macOS 14.0+ on Apple Silicon; runtime verification is limited to the macOS version actually tested and no separate macOS 14 runtime test was performed; standalone Spotify uses separately downloaded Soloist (not bundled); links to the verification runbook, `Kinrox-{{VERSION}}-arm64.dmg`, `Kinrox-{{VERSION}}-dependency-sources.tar.gz`, `SHA256SUMS.txt`. Claims must match shipped behavior.
3. Create `docs/runbooks/{{VERSION}}-VERIFICATION.md` after the previous release's report: release authorization (the owner's command to the orchestrator; quote it from the answers if present, otherwise say "invoked through general-release"), contents, automated checks with real counts, signed distribution, verification boundaries, publication. Fill it with facts as you obtain them; never record a check you did not run.
4. Append the entry for `Mac {{VERSION}} (build {{BUILD}})` to the end of `docs/releases/HISTORY.md` in the style of the previous entries (released at the owner's request on `<today>`, what it brings, signed/notarized app and DMG, source tag, links to the release notes and verification, relative to `docs/releases/`). In `AGENTS.md`, change only the version and build in the `Current release:` line of the status block; never add history there. Update other places that name the current version only if the previous release did so in its source commit; website and README links change in step 6, after the DMG is public.

## 3. Checks of the release tree

Run once on the final tree (the green ones from the apply stage are not repeated unless files changed after them); record real counts for the verification report:

```sh
python3 Scripts/prepare-release-dependencies.py
python3 -m unittest discover -s Scripts/tests -v
swift test --package-path Packages/RemoteProtocol
swift test --package-path Packages/KinroxMusic
bash Scripts/make-test-media.sh
./Scripts/generate.sh
xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/PortableTests-{{VERSION}} \
  "KINROX_MPV_INCLUDE_DIR=$PWD/Vendor/iina-1.5.0/include" \
  "KINROX_MPV_LIBRARY_DIR=$PWD/Vendor/iina-1.5.0/lib" \
  "LD_RUNPATH_SEARCH_PATHS=\$(inherited) $PWD/Vendor/iina-1.5.0/lib" test
xcrun swift-format lint --strict --recursive PlayerMac RemoteiOS Packages Shared
python3 Scripts/check-localization.py
python3 Scripts/build-site.py --check
bash -n Scripts/*.sh
```

Add the 500-line check from `RUNBOOK-TASK-TESTS.md`. If `AppStore/` or `fastlane/` changed, run their test suites too. RemoteiOS tests run only on a physical iPhone connected by the owner; if RemoteiOS changed and no device is connected, record "not run" in the report - never use the Simulator. A failed check: a stale test caused by an intentional package change - fix the expectation and rerun that suite; a runtime-code or behavior fix - prepare it without committing, rerun the failing suite, and ask with diagnosis and diff; an infrastructure failure - one retry. Record `CHECKS_DONE=1` and `PACKAGE_FINGERPRINT` (a hash of `git status --porcelain` plus `git diff` of the tree) right after the last successful check.

## 4. Signed, notarized build

1. Before the build, the tree must still match `PACKAGE_FINGERPRINT`. After the build, compare again: the DMG must correspond to exactly the tree you commit. If it changed, stop and report; never rebuild over `{{DIST_DIR}}`.
2. Run `./Scripts/build-release.sh {{VERSION}} {{BUILD}}` with a log in the run directory. It prepares dependencies, archives, exports with Developer ID, bundles libmpv, verifies the Soloist bundle, runs the signed-app startup check, notarizes and staples the app and the DMG, writes the dependency-sources archive and `SHA256SUMS.txt`, and signs the appcast entry. Its failure message is the diagnosis; fix the cause that belongs to the package and ask about anything touching credentials. Record `BUILD_DONE=1`, `NOTARIZED=1`, and `DMG_SHA256`.
3. Verify the product as `RUNBOOK-RELEASE.md` requires, with real commands and real output: mount the DMG read-only; `codesign --verify --deep --strict`, `spctl --assess`, `xcrun stapler validate`, and `python3 Scripts/bundle-libmpv.py --verify-only` on the mounted app; `Info.plist` shows `{{VERSION}}` (`{{BUILD}}`); `check-soloist-bundle.py` passes; no Homebrew paths, no JIT or executable-memory exemption. Detach the image. The mounted-app interactive playback and phone-pairing checks are performed only if you can do them without guessing; otherwise write them under "Verification boundaries" - do not claim them. Runtime verification is limited to the macOS version actually tested; do not request a macOS 14 runtime test; keep the owner's sleep/reboot waiver wording ("waived, not passed").

## 5. Source commit, tag, push, public release

1. Questions are possible only until the first push. Resolve open ones before this step.
2. `git add -A`; check `git diff --cached --name-only` against the list from step 1.3. Remove extras with `git rm --cached <path>` (the file stays on disk) and add a mask to `.gitignore`.
3. Commit to `main` in English in the history's style: `Release Mac {{VERSION}} with <short list of headline changes> [skip ci]`; the body lists main changes by subsystem. `[skip ci]` keeps Pages from deploying before the DMG is public. If the package splits into independent tasks, you may use several logical commits, with `[skip ci]` on the last. Fix the cause of a failing Git hook; never bypass it.
4. `git fetch origin main`. If `origin/main` moved ahead, `git merge --no-edit origin/main` (resolve mechanical conflicts keeping both sides; a substantive conflict is a question before push) and repeat the checks of step 3 for the merged tree; because the merged tree is not the built tree, rebuild is needed only if app, packaging, or dependency files changed - otherwise say so in the report. Record `SOURCE_SHA` (`git rev-parse HEAD`).
5. `git tag -a {{TAG}} -m "Kinrox {{VERSION}}" "$SOURCE_SHA"`, then `git push origin main` (no `--force`) and `git push origin {{TAG}}`. A rejected push because of new `origin/main` commits - repeat 4. Record `TAGGED=1`, `SOURCE_PUSHED=1`.
6. Create the public release from `{{DIST_DIR}}`: `gh release create {{TAG}} --repo awaik/Kinrox --title "Kinrox {{VERSION}}" --notes-file docs/releases/{{VERSION}}.md "{{DIST_DIR}}/Kinrox-{{VERSION}}-arm64.dmg" "{{DIST_DIR}}/Kinrox-{{VERSION}}-dependency-sources.tar.gz" "{{DIST_DIR}}/SHA256SUMS.txt"`. Verify through `gh release view {{TAG}} --json assets,isDraft,tagName`: not a draft, three assets, GitHub's SHA-256 digests equal the local files; download the public DMG anonymously (`curl -fL` into the run directory) and compare its hash. Record `RELEASE_PUBLISHED=1`.

After the first push, ask no questions: finish to the end or to a blocker and describe the problem in the answer.

## 6. Website, README, and update feed

Only after the DMG is public and verified:

1. Move the download links and version text from the previous version to `{{VERSION}}` everywhere the previous release did (see its `Publish Mac ... download pages and signed update feed` commit): `README.md`, `Scripts/build-site.py` (`softwareVersion`, `downloadUrl`), `Website/templates/`, `Website/locales/*.json` (the version string inside the "signed and notarized DMG" entries; keep the key unless the code requires otherwise), the verification report's publication section. Use a targeted search for the previous version string and change only download/version references - not release history, notes of older releases, or tests of older behavior.
2. Regenerate the site with `python3 Scripts/build-site.py`, then `python3 Scripts/build-site.py --check` and `python3 -m unittest discover -s Scripts/tests -p 'test_site_localization.py'` and `-p 'test_spotify_documents.py'`.
3. Copy `{{DIST_DIR}}/appcast.xml` to `site/appcast.xml`. It must differ from the current feed by exactly the new item (`git diff site/appcast.xml`: one added `<item>`, version `{{VERSION}}`, build `{{BUILD}}`, an enclosure URL equal to the public DMG URL, a length equal to the DMG size, a non-empty `sparkle:edSignature`).
4. Commit `Publish Mac {{VERSION}} download pages and signed update feed` and `git push origin main`. This push touches `site/**`, so it triggers the Pages workflow. Record `SITE_SHA`, `SITE_PUSHED=1`.

## 7. Verify publication

Read-only; record every result:

1. `gh run list --workflow pages.yml --branch main --limit 5 --json databaseId,headSha,status,conclusion`: find the run for `SITE_SHA`, wait for it (`gh run watch <id> --exit-status`). If no run exists, `gh workflow run pages.yml --ref main` once and verify the deployment references `SITE_SHA`.
2. The live feed `https://awaik.github.io/Kinrox/appcast.xml` lists `{{VERSION}}` (build `{{BUILD}}`); its enclosure URL downloads the published DMG anonymously and the SHA-256 matches `DMG_SHA256`.
3. The live landing pages in English and Russian (and a few other locales) show the new version and the direct `{{TAG}}` DMG URL; links return 200.
4. Fill the publication section of `docs/runbooks/{{VERSION}}-VERIFICATION.md` with these results and commit it with `docs: record Mac {{VERSION}} publication verification` (plain push; the site paths are unchanged, so no new Pages run is needed - if the commit touches `site/**`, verify that run too). Record `PAGES_VERIFIED=1`.

## 8. Final state

In the main checkout: `git status --porcelain` is empty; `git worktree list` shows only the main checkout; `git branch` shows only `main`; `git rev-parse HEAD origin/main` are equal; the tag `{{TAG}}` points to `SOURCE_SHA` on origin. If `git status` is not empty, find where the paths came from (a parallel session, a build artifact outside `.tmp/`, `dist/` or `DerivedData/` missing from `.gitignore`) and describe it; never delete other people's files. Record `FINALIZED=1`.

## Questions for the orchestrator

The agent that launched you is the orchestrator; it answers by itself or asks the owner.

- Questions are possible only **before the first push**. First do everything that does not depend on the question; write the questions to `{{QUESTIONS_FILE}}`: number, the question in one sentence, what depends on it, options with consequences, your recommendation, where you stopped. Do not push; end with `RESULT: QUESTIONS - ...`.
- After the first push ask nothing: finish publication, verification, and the final state, or stop at a blocker and describe it.

## Answer

Briefly: commits (SHA and subject), what shipped and what was excluded; merge with `origin/main`; the checks with real counts and the boundaries you could not cover; notarization submission ids and the DMG/archive SHA-256; the tag; the release URL and asset digests; the website and feed commit; Pages run id and live-feed results; the final Git state; what needs an owner decision. The last line is exactly one line:

`RESULT: RELEASED | PARTIAL | QUESTIONS | BLOCKED - <one sentence>`

`RELEASED` - the source and site commits are pushed, the tag and the GitHub Release exist with verified assets, the live feed and pages show `{{VERSION}}`, and the tree is clean. `PARTIAL` - the release is public but part of the verification or the final state is incomplete (say exactly what).
