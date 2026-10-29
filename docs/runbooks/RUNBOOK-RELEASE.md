# Mac Release

Kinrox releases target Apple Silicon and macOS 14+. Development can use Homebrew;
distribution uses pinned IINA arm64 dependencies built with macOS 11 deployment
targets. Do not substitute the local Homebrew binaries: they require macOS 26.

## Preparation

Read the master specification and inspect the working tree. Preserve existing
changes. Installations and credentials are managed by the owner. This workflow
requires Xcode, XcodeGen, Python 3.12+, curl, a Developer ID Application
identity, an Xcode account with access to the team, and an existing notarytool
Keychain profile. No certificate or credential is stored in the repository.

```sh
python3 Scripts/prepare-release-dependencies.py
python3 -m unittest discover -s Scripts/tests -v
swift test --package-path Packages/RemoteProtocol
bash Scripts/make-test-media.sh
./Scripts/generate.sh
xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/PortableTests \
  "KINROX_MPV_INCLUDE_DIR=$PWD/Vendor/iina-1.5.0/include" \
  "KINROX_MPV_LIBRARY_DIR=$PWD/Vendor/iina-1.5.0/lib" \
  "LD_RUNPATH_SEARCH_PATHS=\$(inherited) $PWD/Vendor/iina-1.5.0/lib" test
```

`prepare-release-dependencies.py` verifies the binary archive and upstream
source hashes, preserves the upstream build scripts and patches, collects
licenses, and downloads pinned git submodules needed by the enabled features.
`Scripts/release-source-lock.json` fixes the libjxl/libplacebo revisions and all
13 included submodule revisions and archive hashes from the retained build-2
source manifest. A complete verified cache requires no network or GitHub login.
When updating upstream build recipes, review and update this lock explicitly.
Artifacts remain in ignored `Vendor/`. Existing mismatched files are rejected,
and incomplete downloads are preserved for inspection.

## Update Signing Key

Sparkle 2 verifies every update with an EdDSA key ([details](UPDATES-VERIFICATION.md)).
The owner creates it once; agents do not create or export credentials. After
`./Scripts/generate.sh` and any build that resolves packages:

```sh
DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys   # login Keychain
```

Put the printed public key into `KINROX_UPDATE_PUBLIC_KEY` in `Config/Updates.xcconfig`,
writing any `//` as `/$()/` (xcconfig comment syntax). The key was created on
2026-10-29. Its backup follows the owner's secret escrow policy: an age-encrypted copy in
the private `awaik/ops-secrets` repository (`secrets/kinrox-release.enc.env`, restore
steps in `restore/kinrox-release.md` there). Never write the private key to a plaintext
file; after a rotation, re-archive it in the same task. Losing the private key means installed players
can no longer accept updates; a changed key must ship in a release signed with the old one.
`build-release.sh` refuses to run without the public key and verifies that the Keychain
key matches it before notarization.

## Build, Sign, and Notarize

Set `APPLE_TEAM_ID`, `APPLE_SIGNING_IDENTITY` (the certificate's SHA-1 from
`security find-identity -v -p codesigning`), and `NOTARYTOOL_PROFILE` locally.
Then run:

```sh
./Scripts/build-release.sh 0.2.0 4
```

Write `docs/releases/<version>.md` first: it becomes the release notes in Sparkle's
window. Relative links resolve against `docs/releases/` at the matching `v<version>`
repository tag. Marketing versions (`major.minor.patch`) and positive integer build
numbers must both increase beyond every item in the appcast; Sparkle compares builds.
The script checks the feed before creating the release directory or invoking build
and notarization tools. To run only this local, read-only preflight:

```sh
python3 Scripts/update-appcast.py --check --appcast site/appcast.xml --version 0.3.0 --build 5
```

The script refuses to reuse an existing `dist/<version>-build<build>` directory. It archives
using automatic Apple Development signing with the explicit `APPLE_TEAM_ID`,
clearing local manual profile overrides. It exports with Developer ID signing so Xcode obtains
the distribution profile for Data Protection Keychain. It embeds the full libmpv
dependency graph, verifies architecture and deployment versions, removes external
load paths, and signs libraries before signing the app. Library validation remains
enabled. A real signed-app startup regression runs before submission and rejects
JIT/executable-memory exemptions or Homebrew libraries. The verifier sets
`KINROX_RELEASE_SMOKE_TEST=1`, which prevents Sparkle initialization and changes to
its saved update preferences while retaining framework loading checks. The bundled
third-party notice substitutes the requested release version into its title and
corresponding-source download links. Kinrox disables mpv's
built-in Lua scripts as well as user scripts: they are not used by the native UI.
Sparkle's Installer, Downloader, Autoupdate, and Updater helpers are re-signed
inside-out with the same identity, Hardened Runtime, and timestamp before the app.
Both the app and final DMG are notarized and stapled; Gatekeeper, signatures,
and the disk-image checksum are checked before the script reports success.
Finally `update-appcast.py` signs the DMG with `sign_update` (login Keychain) and
writes `dist/<version>-build<build>/appcast.xml`: `site/appcast.xml` plus the new item.

The startup check requires `KINROX_PLAYER_READY` on stderr after engine, render
context, and window initialization. A live process blocked in an initialization
error alert fails. Older binaries without this diagnostic must be rebuilt before
using the updated checker; a loaded libmpv alone is not a readiness signal.

Retain all logs, the archive, exported app, source archive, and notary receipts.
Never publish local signing files, Xcode archives, provisioning logs, or credentials.

## Final Verification and Publication

1. Mount the DMG read-only and verify the mounted app with `codesign`, `spctl`,
   `stapler`, and `bundle-libmpv.py --verify-only`.
2. Launch that app, set Kinrox's volume to zero, and verify MP4 and MKV playback,
   pause, seek, fullscreen, and remote pairing. Do not change system volume.
3. Document the macOS versions actually tested. Deployment metadata alone does
   not constitute a manual macOS 14 test.
4. Review the release source snapshot and publish its matching git revision.
   The project's no-commit rule requires an explicit owner exception for committing
   release files and website updates. Include other accumulated changes only when
   the owner explicitly authorizes them, as for the first release on 2026-10-28.
5. Publish `v0.2.0` to `awaik/Kinrox` with the DMG, dependency sources, and SHA256SUMS.
   Include a source snapshot if the release is not represented completely by its tag.
6. Publish both landing pages with the direct versioned asset URL. Check the live
   English and Russian pages and anonymously download the asset to verify its hash.
7. Only after the DMG is public, copy `dist/<version>-build<build>/appcast.xml` to
   `site/appcast.xml` and deploy Pages. Check that the live feed lists the new item
   and that its enclosure URL downloads the published DMG.
8. With the first release that contains the update checker (0.3.0), update the claims
   that Kinrox never connects to the internet: the FAQ and "No accounts, no telemetry"
   copy in `site/index.html` and `site/ru/index.html`, and `site/privacy/index.html`.
   The Mac player now requests `https://awaik.github.io/Kinrox/appcast.xml` once a day
   without identifiers; video and remote traffic stay on the local network.
   Users of 0.2.0 must download that release manually once.

When one commit contains both the release source and landing changes, use
`[skip ci]` in that commit to hold the Pages deployment until the release assets
are public. Then dispatch `pages.yml` manually for `main` and verify the successful
deployment references that same commit. Run all local checks before publishing.

No iPhone App Store upload is part of this release. Mac updates use Sparkle 2 from
release 0.3.0 on; earlier versions have no updater.
