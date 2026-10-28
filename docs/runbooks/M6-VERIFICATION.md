# M6 Verification — Mac 0.1.0

Date: 2026-10-28. Public release candidate: **0.1.0, build 3**, Apple Silicon,
macOS 14 minimum. The iPhone App Store release is outside this task.

## Distribution

- Pinned IINA dependency release `iina-1.5.0-release`, build recipe commit
  `f86d54276547df6d14104583ea604af67433f1e1`.
- Binary archive SHA256:
  `ec7266468a297b907eadbb473c7b3d2992cd274c40d379d8e0e8910caedfae50`.
- libmpv 0.41.0, FFmpeg 9.0.1, 44 bundled arm64 dylibs total.
- Every Mach-O dependency is an Apple system library or resolves within the app.
  The verifier rejects external rpaths, missing libraries, non-arm64 binaries,
  and libraries requiring a newer OS than the application's declared minimum.
- Developer ID signing, Hardened Runtime, and Data Protection Keychain distribution
  provisioning. Library validation remains enabled; no JIT or unsigned executable
  memory entitlement is granted.
- 43 corresponding source archives with pinned revisions/checksums, build recipes,
  patches, and 71 license text files. Dependency source material accompanies the DMG.

## Automated Checks

- Protocol/transport: **118 tests passed**.
- Mac application: **69 tests passed**, including a repeat after the startup fix
  against the exact vendored library versions. Coverage includes MP4, MKV, HEVC,
  VideoToolbox, Core Audio with Kinrox volume zero, rendering, seek, fullscreen,
  teardown, Bonjour, pairing, reconnection, revocation, and real Keychain access.
- Packaging: **3 tests passed** using real compiled Mach-O fixtures. They verify
  transitive relocation and execution, preservation of inputs, refusal to overwrite,
  missing dependency rejection, and minimum-OS enforcement.
- Localization validation: 30 locales, 183 UI keys and permission prompts passed
  after adding Privacy Policy and Support during App Store preparation.
- Swift formatting for the changed source, shell syntax, Python compilation, and
  `git diff --check` passed.
- English and Russian site links and JSON-LD versions match the installer asset;
  the pages were inspected in Chrome.

## Signed Startup Regression

Build 1 passed Apple notarization and static signature checks but failed real
launch with `SIGKILL`, `CODESIGNING / Invalid Page`. The crash stack contained
mpv `load_builtin` and LuaJIT: `load-scripts=no` only disables user scripts.

`Scripts/check-release-launch.py` reproduced the crash before the fix. The player
now explicitly disables unused built-in console, statistics, selection, commands,
positioning, context-menu, and automatic-profile scripts before initialization.
The release pipeline runs the startup check after signing and before notarization.
It also rejects executable-memory exemptions and loaded Homebrew dependencies.
Build 1 is retained in ignored `dist/0.1.0/` with `DO-NOT-PUBLISH.txt`.

## Validation Boundaries

Runtime tests ran on macOS 26.5.2 (Apple Silicon). macOS 14 is the application
deployment target and all bundled library deployment targets fit within it;
no separate macOS 14 machine was available for manual testing. Intel, multi-monitor
HDR, and an App Store iPhone installation were not verified in this task.

Release artifacts and detailed logs are retained in `dist/0.1.0-build3/` and
`dist/release-preparation/`. Never upload the export logs or signing material.

## Final Installer Verification

- App notarization: Accepted, submission `1e25b12a-8880-42eb-9915-35e6cbe0486e`.
- DMG notarization: Accepted, submission `c61b11e6-2544-42c3-83c9-d80fdada6158`.
- App and DMG tickets stapled and validated; disk image checksum verified.
- Signed build 3 passed the updated real startup check with no runtime exemptions,
  including the explicit engine/render/window readiness diagnostic.
- Build 2 paired with a temporary local test client, persisted its token in
  Data Protection Keychain, and authenticated a new connection using that token.
- Verified remote volume zero, MP4 playback, pause, seek, fullscreen enter/exit,
  resume, automatic advance to HEVC MKV, and video rendering. The temporary
  verification device was revoked in Settings; existing paired devices were preserved.
- Mounted the final DMG read-only and repeated startup, signature, Gatekeeper,
  stapled-ticket, and portable-dependency verification.

Final asset checksums:

```text
bc7be6d912c035bdbcd2a3a54bc370afec3925817ab596a63a19030255cebaf7  Kinrox-0.1.0-arm64.dmg
6b0cab0c76ba61bbef382b4b02128f436a2d94ca15f6e3320568712544e53be0  Kinrox-0.1.0-dependency-sources.tar.gz
```

## Review Follow-up — 2026-10-28

- Archive signing explicitly selects the requested team and automatic Apple
  Development identity, clearing local manual provisioning profile settings.
- All 43 source archives passed verification with subprocess network/API calls
  disabled. The source lock pins 15 GitHub archives (two roots and 13 submodules).
- Ten workflow regressions and the three existing Mach-O packaging tests passed.
  Eight failure cases were reproduced before their fixes, including false startup
  success, corrupted caches, regional copy bypass and failed-capture restoration.
- The supported Debug Mac suite passed all 69 tests against portable libraries.
  An initial Release test attempt could not use `@testable` modules; the separate
  Release application build succeeded.
- A fresh locally Developer ID-signed app with all 44 bundled libraries passed
  the updated startup checker with Hardened Runtime and library validation enabled.
  This local smoke copy has no timestamp/notarization submission and is not a
  distribution artifact. Logs are in `DerivedData/ReviewFix-q7oij238/`.
- Existing build-2 DMG, notarization receipts and checksums above were preserved.
  The reviewed source was subsequently rebuilt as build 3, signed and notarized
  again. Its final DMG passed the mounted-app checks above. All 13 packaging and
  workflow tests passed again before publication.
