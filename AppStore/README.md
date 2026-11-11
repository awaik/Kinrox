# Kinrox Remote — launch kit

Open `index.html` directly in a browser, or run:

```sh
python3 -m http.server 8898 --bind 127.0.0.1 --directory AppStore
```

The gallery is offline-capable: all metadata is embedded and all screenshots are local. Select a locale and image size, then click a screenshot to inspect its full-resolution PNG.

## Contents

- `copy/`: 30 authored language packs: store fields, eight screenshot headlines/details, the footer
  offer (`requirement`) and `screenshot_ui`, mock-only device strings that have no app key.
- `localized-copy.json`: generated regional copy shared by screenshot rendering,
  the gallery and SRT guides. Regenerate it with metadata after editing copy.
- `metadata/`: 35 App Store localizations, ready to paste or import field by field. `manifest.json` maps each store locale to its UI language.
- `screenshot-strings.json`: per-locale text replacements for the screenshot set v2, generated
  by `Scripts/app-store/screenshot-strings.py`.
- `screenshots/export-20261111-v2/`: set v2 for Remote 0.2.2 — eight images per locale at both
  1206×2622 and 1320×2868 (560 upload PNGs for 35 store locales plus 16 Persian PNGs), with
  `SHA256SUMS`, `provenance.json` and a `contact-sheet.png` per locale (not an upload file).
  The manifest records `screenshots_per_locale_per_size: 8`.
- `screenshots/export-20261028-regional/`: the five-screen 0.1.0 set, preserved locally; it was
  rendered by `Scripts/render-app-store.swift` from the simulator captures in `screenshots/raw/`.
- `screenshots/overview-ru.jpg` and `overview-en.jpg`: 0.1.0 contact sheets, not upload files.
- `preview/STORYBOARD.md`: 27-second App Preview script, production specification and references.
- `preview/captions/`: 36 localized SRT timing guides, including Persian; script assets only.
- `review/notes.txt`: finalized reviewer instructions used by fastlane, including the public Mac 0.1.0 download. `review/REVIEW-NOTES.md` retains the original preparation draft.
- `RELEASE-CHECKLIST.md`: current readiness, release steps, account decisions and Apple references.
- [Editable Figma masters v2](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U?node-id=229-304): English and Russian rows for Remote 0.2.2. Other languages are temporary copies rendered by the scripts below and removed after export; they are not kept as Figma frames. The 0.1.0 masters are on [page 03](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U?node-id=23-304).

## Regeneration

```sh
python3 Scripts/prepare-app-store.py              # metadata + localized-copy.json
python3 Scripts/prepare-app-store.py --check
python3 Scripts/app-store/screenshot-strings.py   # AppStore/screenshot-strings.json
python3 Scripts/build-app-store-gallery.py
```

Screenshots v2 come from Figma page `14 · App Store — Screenshots v2` (`229:304`). English
and Russian are the editable masters; every other locale is a temporary copy of the English
row whose texts are replaced and fitted by `Scripts/app-store/figma-localize-screenshots.js`:

1. Create a hidden text node on page `229:304` for the script (the 2026-11-11 export used
   `246:1539`; update `ENGINE_NODE` in `figma-row-call.py` if it changes).
2. For each locale, run the output of
   `python3 Scripts/app-store/figma-row-call.py <locale> [--engine]` with the Figma MCP
   `use_figma` tool (`--engine` stores the current script first). It builds a
   `TMP export <locale>` row and reports shrunk or overflowing labels.
3. Export that row with `get_screenshot` at `maxDimension` 10560 and split it:
   `swift Scripts/app-store/split-screenshots.swift <row.png> AppStore/screenshots/<export> <locale>`.
   The splitter refuses to overwrite files.
4. Review the contact sheet, then delete the `TMP` nodes from Figma.

Regional variants with identical strings reuse a row: en-CA = en-US, en-AU = en-GB,
fr-CA = fr-FR. es-MX and pt-PT differ only in header copy. Headline copy must fit two lines
at 86 px; shorten the copy rather than shrinking the whole row.

The 0.1.0 pipeline (`Scripts/capture-app-store.py` simulator captures and
`Scripts/render-app-store.swift`) is kept for that export only. Do not run the simulator for
screenshots without the owner's explicit permission (AGENTS.md §9 rule 11).

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
