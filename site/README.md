# Kinrox landing site

Static landing page published with GitHub Pages by
[`.github/workflows/pages.yml`](../.github/workflows/pages.yml). No build step,
no frameworks, no external fonts, scripts, analytics or cookies.

- `index.html` — English (default), `ru/index.html` — Russian.
- `privacy/index.html` — privacy policy; `support/index.html` — setup and support.
  Both are linked from the landing footers and iPhone Settings.
- `assets/css/` — `base.css` (tokens, nav, buttons), `hero.css` (first screen), `mockups.css` (iPhone frame,
  Mac window and pairing dialog), `sections.css` (page sections).
- `assets/js/main.js` — optional scroll reveal and sticky-nav state.
- `assets/img/` — artwork and screenshots, see below.

## Design source

Design lives in Figma file
[Kinrox — Design](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U) (AGENTS.md §3.5).
Colors match `Resources/Branding.xcassets`. The Mac window and pairing dialog on the page
are HTML recreations of Figma frames `Mac / Player — Playing` (5:23) and
`Pairing Dialog · Liquid Glass` (6:215); their text is real app strings from
`Resources/Localization`. Icons (`assets/img/icons`) and video stills (`assets/img/stills`)
are exported from the Figma component library, with only the canvas background removed.
`assets/img/scene.svg` (hero illustration) is drawn for the site; it has no text, so both
languages share it.

## Screenshots

iPhone screenshots in `assets/img/remote/<lang>/` come from the real app in demo mode.
To refresh them after UI changes, build RemoteiOS for the simulator, boot an iPhone
simulator and run:

```sh
./Scripts/capture-landing-screenshots.sh
```

The script swaps demo-only hints for the strings a real connection shows in a temporary
bundle copy, then restores the regular build on the simulator.

Social previews `assets/img/og-image.jpg` and `og-image-ru.jpg` are 1200 × 630 renders of
the hero; regenerate them by hand when the headline or screenshots change.

## Local preview

```sh
python3 -m http.server 8080 --directory site
open http://localhost:8080/
```

## Publishing

Mac download buttons point to the versioned GitHub Release asset
`releases/download/v0.1.0/Kinrox-0.1.0-arm64.dmg`. Publish and verify that asset
before deploying these pages. Update both languages, the visible version, and
the JSON-LD download/version fields together. The iPhone App Store release is
still planned separately. Distribution steps are in
[`RUNBOOK-RELEASE.md`](../docs/runbooks/RUNBOOK-RELEASE.md).

1. Push the repository to GitHub.
2. Settings → Pages → Source: **GitHub Actions**.
3. Every push to `main` that touches `site/` redeploys the page.

Absolute URLs assume the repository `github.com/awaik/Kinrox` and the address
`https://awaik.github.io/Kinrox/`. If the repository lives elsewhere, replace both strings in
`index.html`, `ru/index.html`, `privacy/index.html`, and `support/index.html`
(canonical, hreflang, Open Graph and GitHub links). Update App Store metadata and
the iPhone's support/privacy URLs at the same time.
