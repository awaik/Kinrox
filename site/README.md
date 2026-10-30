# Kinrox website

Static landing, support and privacy pages in all 30 app languages, published with
GitHub Pages by [`.github/workflows/pages.yml`](../.github/workflows/pages.yml).
No runtime framework, translation service, external fonts, analytics or cookies.
All copy and navigation work without JavaScript.

## Languages and sources

English is the default at `/`, `/support/` and `/privacy/`. Every other language
has equivalent routes under its app locale, such as `/ru/support/`, `/ar/privacy/`
and `/zh-Hant/`. The language menu uses native language names and stays on the
current page. Optional JavaScript also preserves section anchors and query parameters.
Explicit URLs determine the language; there is no automatic redirect or browser storage.

- `../Website/templates/` — shared page templates, following the existing design.
- `../Website/locales/<locale>.json` — English source and complete translation catalogs.
- `../Website/languages.json` — native names for exactly the locales in
  `Resources/Localization`; the build rejects language or translation gaps.
- `../Website/markup.json` — trusted inline markup. Numbered slots in translations
  preserve links, icons, keyboard keys and emphasis; translated text is HTML-escaped.
- `assets/css/localization.css` — language menu, document-page styles, text expansion
  and right-to-left layout for Arabic, Persian, Hebrew and Urdu. PINs, timelines,
  keyboard keys and shell commands retain left-to-right ordering.
- `assets/js/main.js` — optional reveal, sticky navigation and language-menu enhancement.

Generated HTML is committed so previews and hosting remain fully static. Do not edit
generated pages directly: edit templates/catalogs, then regenerate offline:

```sh
python3 Scripts/build-site.py
python3 Scripts/build-site.py --check
python3 -m unittest discover -s Scripts/tests -p 'test_site_localization.py'
python3 -m http.server 8080 --directory site
```

The deployment workflow runs the same verification before uploading `site/`.
Checks cover all page routes, internal links and fragments, images, document structure,
translated metadata, canonical/hreflang links, language menus and sitemap coverage.

Existing English/Russian landing copy was retained. New translations started from a
one-time machine-assisted draft of public site copy, with existing app strings reused
and contextual corrections for headings, controls, links and privacy terminology.
No translation endpoint, key or network dependency is part of the generator or site.
Native-speaker editorial review of all locales remains recommended.

## Design and images

Design lives in [Kinrox — Design](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U)
(AGENTS.md §3.5). Colors match `Resources/Branding.xcassets`. Mac screens remain HTML
recreations of Figma frames 5:23 and 6:215. The illustration `assets/img/scene.svg`
contains no text and is shared by all languages. `og-scene.png` is its text-free social
preview; each page supplies a translated social title and description.

Every locale uses real app screenshots in `assets/img/remote/<locale>/`. To refresh,
build RemoteiOS for an iPhone 17 Pro simulator (1206 × 2622), boot a dedicated simulator,
and run from the repository root:

```sh
./Scripts/capture-landing-screenshots.sh <simulator-udid>
# Or update selected locales:
./Scripts/capture-landing-screenshots.sh <simulator-udid> de ar zh-Hans
```

The script uses a unique work directory, preserves raw captures, and adjusts demo-only
hints in a temporary app copy. It reinstalls the regular build at the end. Existing
work directories are not deleted. ImageMagick and cwebp must already be installed.

## Publishing

The canonical address is `https://kinrox.app/` (`CNAME`). `sitemap.xml`, `robots.txt`
and all 30 reciprocal language alternatives are generated together.

Mac download buttons and JSON-LD currently target the existing, versioned GitHub Release
asset `releases/download/v0.3.0/Kinrox-0.3.0-arm64.dmg`. For a release, publish and verify
the asset before updating the template, catalog version labels and generator metadata.
The iPhone App Store release remains separately planned. See
[`RUNBOOK-RELEASE.md`](../docs/runbooks/RUNBOOK-RELEASE.md).

Repository Settings → Pages → Source must be **GitHub Actions**. Pushes to `main`
touching the website, localization sources or validation scripts trigger verification
and deployment. The owner authorized publication of the 30-language website on
2026-10-30. Future changes follow the repository's owner-review workflow.
