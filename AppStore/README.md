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
- `screenshots/export-20261028-regional/`: 350 upload PNGs for 35 store locales plus ten Persian PNGs for non-App Store use. Each locale has five images at both 1206×2622 and 1320×2868. The previous export is preserved locally.
- `screenshots/raw/`: 90 real localized UI captures and provenance. Demo content uses fictional titles; helper strings were changed only in a copied capture bundle.
- `screenshots/overview-ru.jpg` and `overview-en.jpg`: quick contact sheets, not upload files.
- `preview/STORYBOARD.md`: 27-second App Preview script, production specification and references.
- `preview/captions/`: 36 localized SRT timing guides, including Persian; script assets only.
- `review/REVIEW-NOTES.md`: draft reviewer instructions and missing owner fields.
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

The renderer refuses an existing output directory and writes opaque RGB PNGs. If a new export directory is used, update the gallery's export path after reviewing it. Do not remove existing exports automatically.

`screenshots/` is ignored by Git: retain captures and exports locally or in release
asset storage. A fresh clone needs local captures and a rendered export to display
the gallery images; metadata, copy, scripts and review documents remain in Git.
The current export has its own `SHA256SUMS`. Earlier exports and the older
top-level checksum file remain preserved and do not describe the current export.

To recapture UI, build Debug for the simulator, create a dedicated simulator, then use `Scripts/capture-app-store.py --device <UDID> --output <new-directory>`. This changes only that simulator and a copied app bundle; it restores the original build and clears the status bar even after capture failure. It never patches app source or deletes previous output. Keep the capture app, simulator and logs until the owner decides whether to archive or remove them.

## Submission status

Prepared locally, not uploaded or published. The Chrome App Store Connect tab is at login. The iPhone app now has Privacy Policy and Support links and a required-reason privacy manifest; the corresponding website pages still need normal deployment. A signed upload archive, final physical-device release test, account decisions, license decision and encryption declaration remain. No video has been made. Native-language editorial review is pending.
