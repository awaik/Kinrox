# Kinrox Remote — launch kit

Open `index.html` directly in a browser, or run:

```sh
python3 -m http.server 8898 --bind 127.0.0.1 --directory AppStore
```

The gallery is offline-capable: all metadata is embedded and all screenshots are local. Select a locale and image size, then click a screenshot to inspect its full-resolution PNG.

## Contents

- `copy/`: 30 authored language packs, including five screenshot headlines/descriptions per language.
- `localized-copy.json`: generated regional copy shared by screenshot rendering,
  the gallery and SRT guides. Regenerate it with metadata after editing copy.
- `metadata/`: 35 App Store localizations, ready to paste or import field by field. `manifest.json` maps each store locale to its UI language.
- `screenshots/export-20261028-regional/`: 350 upload PNGs for 35 store locales plus ten Persian PNGs for non-App Store use. Each locale has five images at both 1206×2622 and 1320×2868. The manifest records `screenshots_per_locale_per_size: 5` and `screenshots_per_locale: 10`. The previous export is preserved locally.
- `screenshots/raw/`: 90 real localized UI captures and provenance. Demo content uses fictional titles; helper strings were changed only in a copied capture bundle.
- `screenshots/overview-ru.jpg` and `overview-en.jpg`: quick contact sheets, not upload files.
- `preview/STORYBOARD.md`: 27-second App Preview script, production specification and references.
- `preview/captions/`: 36 localized SRT timing guides, including Persian; script assets only.
- `review/notes.txt`: finalized reviewer instructions used by fastlane, including the public Mac 0.1.0 download. `review/REVIEW-NOTES.md` retains the original preparation draft.
- `RELEASE-CHECKLIST.md`: current readiness, release steps, account decisions and Apple references.
- [Editable Figma masters](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U?node-id=23-304): English and Russian plus a Settings/About link specification. Other language artwork is rendered reproducibly with native font fallback from the same geometry and design tokens; it is not a set of individual Figma text frames.

## Regeneration

```sh
python3 Scripts/prepare-app-store.py
python3 Scripts/prepare-app-store.py --check
swift -swift-version 6 Scripts/render-app-store.swift \
  AppStore/screenshots/raw /absolute/path/to/a-new-output-directory "$PWD"
python3 Scripts/build-app-store-gallery.py
```

Metadata regeneration preserves the manifest's recorded submission status and
delivery fields; it does not query or update App Store Connect.

The renderer refuses an existing output directory and writes opaque RGB PNGs. If a new export directory is used, update the gallery's export path after reviewing it. Do not remove existing exports automatically.

`screenshots/` is ignored by Git: retain captures and exports locally or in release
asset storage. A fresh clone needs local captures and a rendered export to display
the gallery images; metadata, copy, scripts and review documents remain in Git.
The current export has its own `SHA256SUMS`. Earlier exports and the older
top-level checksum file remain preserved and do not describe the current export.

To recapture UI, build Debug for the simulator, create a dedicated simulator, then use `Scripts/capture-app-store.py --device <UDID> --output <new-directory>`. This changes only that simulator and a copied app bundle; it restores the original build and clears the status bar even after capture failure. It never patches app source or deletes previous output. Keep the capture app, simulator and logs until the owner decides whether to archive or remove them.

## Submission status

**Submitted for App Review on October 28, 2026 at 09:53 UTC.** Apple's API confirmed
`WAITING_FOR_REVIEW` for [Kinrox Remote](https://appstoreconnect.apple.com/apps/6827926471/distribution/ios/version/inflight),
Apple ID `6827926471`, version `0.1.0 (1)`. All 35 localizations and 350 screenshots
were uploaded through fastlane and verified against local text, image order and
MD5 checksums. All screenshots are COMPLETE and the build is VALID. Fastlane
precheck passed, including public URLs. Release remains manual after approval.

Privacy is published as Data Not Collected following explicit owner confirmation.
The Mac download, privacy page and support page are public. No App Preview video
has been made; the requested deliverable remains a script. Native-language
editorial review and a physical-device TestFlight test of this exact processed
build remain unperformed by this task. See `submission-20261028.json` for the
delivery record and local evidence paths.

## Fastlane

Copy `fastlane/.env.example` to the ignored `fastlane/.env` and supply the existing
App Store Connect key path. Never commit the key. The ignored
`fastlane/.env.review.json` contains the review contact with keys `first_name`,
`last_name`, `email_address`, and `phone_number`.

```sh
fastlane ios build             # Signed archive and IPA
fastlane ios export            # Re-export the existing archive if needed
fastlane ios metadata          # Stage and upload the reviewed 35-locale kit
fastlane ios screenshots       # Resume missing screenshots without replacing matches
fastlane ios binary            # Upload IPA and wait for Apple processing
fastlane ios verify            # Read back text, screenshot order/checksums and build state
fastlane ios submit            # Submit build 1; release remains manual
fastlane ios status
```

The Gemfile pins fastlane 2.236.1. Generated files and delivery logs remain under
`DerivedData/AppStoreDelivery` and `DerivedData/fastlane-*.log`. Both build and export
run `Scripts/generate.sh` before inspecting the workspace, requiring XcodeGen
even on a clean clone. Both place Apple's command-line tools first in PATH to prevent
a Homebrew rsync incompatibility during IPA export. It does not change the system installation.
Metadata upload requires all four review contact fields to contain non-whitespace
text. Submit validates the local contact but uses the metadata already uploaded;
after changing the contact, upload metadata again and run verify before submitting.
Verify stages screenshots locally and checks the processed candidate build. The
submit lane attaches that build to the App Store version. Staging rejects broken
links, unexpected files and extra locale directories without removing them.
The age-rating configuration includes Apple's newly required `socialMedia`
answer. Encryption is declared exempt because all cryptographic primitives are
provided by Apple's CryptoKit; the app is not declared to use no encryption.
