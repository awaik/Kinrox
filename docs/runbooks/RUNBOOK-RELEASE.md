# Mac Release

Kinrox 0.1.0 targets Apple Silicon and macOS 14+. Development can use Homebrew;
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

## Build, Sign, and Notarize

Set `APPLE_TEAM_ID`, `APPLE_SIGNING_IDENTITY` (the certificate's SHA-1 from
`security find-identity -v -p codesigning`), and `NOTARYTOOL_PROFILE` locally.
Then run:

```sh
./Scripts/build-release.sh 0.1.0 3
```

The script refuses to reuse an existing `dist/<version>-build<build>` directory. It archives
using automatic Apple Development signing with the explicit `APPLE_TEAM_ID`,
clearing local manual profile overrides. It exports with Developer ID signing so Xcode obtains
the distribution profile for Data Protection Keychain. It embeds the full libmpv
dependency graph, verifies architecture and deployment versions, removes external
load paths, and signs libraries before signing the app. Library validation remains
enabled. A real signed-app startup regression runs before submission and rejects
JIT/executable-memory exemptions or Homebrew libraries. Kinrox disables mpv's
built-in Lua scripts as well as user scripts: they are not used by the native UI.
Both the app and final DMG are notarized and stapled; Gatekeeper, signatures,
and the disk-image checksum are checked before the script reports success.

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
5. Publish `v0.1.0` to `awaik/Kinrox` with the DMG, dependency sources, and SHA256SUMS.
   Include a source snapshot if the release is not represented completely by its tag.
6. Publish both landing pages with the direct versioned asset URL. Check the live
   English and Russian pages and anonymously download the asset to verify its hash.

When one commit contains both the release source and landing changes, use
`[skip ci]` in that commit to hold the Pages deployment until the release assets
are public. Then dispatch `pages.yml` manually for `main` and verify the successful
deployment references that same commit. Run all local checks before publishing.

No iPhone App Store upload or automatic Mac update mechanism is part of this release.
