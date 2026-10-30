# Website localization verification — 2026-10-30

## Scope

Owner request: localize the entire website into every app language and remove the
mixed English/Russian support page. Implemented 90 static pages: landing, support
and privacy in all 30 locales from `Resources/Localization`.

English remains at the root routes. Russian support now lives at `/ru/support/`;
the English support and privacy pages no longer embed a second Russian article.
Each page has a native-name language menu, localized metadata and image descriptions,
reciprocal language alternatives, and a canonical URL on `https://kinrox.app/`.
Arabic, Persian, Hebrew and Urdu use RTL; PINs and playback timelines remain LTR.

Shared templates/catalogs live in `Website/`. Generated pages remain in `site/` and
work without JavaScript. The Python standard-library generator performs no network
requests. Deployment checks committed output before publishing. See `site/README.md`
for maintenance and publishing instructions.

## Automated checks

Passed:

```sh
python3 Scripts/build-site.py
python3 Scripts/build-site.py --check
python3 -m unittest discover -s Scripts/tests -p 'test_site_localization.py'
node --check site/assets/js/main.js
bash -n Scripts/capture-landing-screenshots.sh
git diff --check
```

Eight test cases cover language parity, complete nonempty catalogs, markup slots,
HTML escaping, current generated output, document structure, translated titles,
90 routes, canonical/alternate URLs, language menus retaining the current page,
all local links/anchors/assets, locale-specific screenshots and sitemap coverage.
No generated/source website file exceeds the project's 500-line limit.

## Browser and screenshot checks

Local preview: `http://127.0.0.1:8087/`.

- All 90 pages rendered in Chromium at widths 320, 768 and 1440 px in a sandboxed
  iframe with scripts disabled. No document overflow, offscreen language menu or
  hidden reveal content was detected.
- Manually inspected the German mobile landing and Arabic mobile support page.
- Opened the language menu at 320 px and switched Arabic support to Traditional
  Chinese. The route remained `/support/` under the selected locale.
- Checked that a language link on `/de/?ref=qa#how` retained the query and section
  as `/fr/?ref=qa#how`. Normal-page console had no warnings or errors.
- Captured four real iPhone app images for each of the 28 added languages using a
  dedicated iPhone 17 Pro simulator, iOS 26.5. Existing English/Russian assets were
  retained. Every locale now has remote, pairing, recents and discovery images.
- Spot-checked Arabic playback and German discovery captures. Raw new captures and
  the temporary app bundle are preserved in `DerivedData/LandingShots.0k2q9n/`.
  The first simulator launch stalled; its work directory remains preserved at
  `DerivedData/LandingShots.lTM2iQ/`. Restarting only the dedicated QA simulator
  resolved this. Other simulators and user app data were not changed.

## Boundaries

New translations began as a one-time machine-assisted draft of public website copy.
Existing app terminology and Russian landing copy were reused. Manual corrections
cover major headings, video-player terminology, controls, download links and privacy
wording, including clearing the recent-files list rather than deleting video files.
All locales have complete translations; exhaustive native-speaker editorial review
has not been performed.

The initial implementation was left local for review. The owner explicitly authorized
deployment on 2026-10-30, including the website commit and push needed by GitHub Pages.
Local generation and all eight tests were rechecked before publication. Existing App
Store work in the working tree is excluded from this deployment and preserved.
