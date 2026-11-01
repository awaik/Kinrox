# Spotify document localization

Status: implemented locally and prepared for publication; not deployed.

## Scope and evidence

The owner requested complete translations of the Spotify connection terms and
privacy supplement and preparation for publication. The previous interface and
consent task bundled an English document and localized only the short disclosure.
`SpotifyDocuments` and the website renderer both selected that English document
unconditionally. All 30 app languages must have the same eight terms sections and
six privacy sections, with the same version and external destinations.

## Plan

1. Translate all 14 sections into the remaining 29 supported languages, preserving
   the approved meaning, permissions, retention details and exceptions.
2. Use the app language for offline documents and each website route's language
   for generated documents. Retain fail-closed consent validation.
3. Validate completeness, locale matching, URLs, version and RTL output. Build and
   test the Mac loader and regenerate/check all website pages.
4. Update publication instructions and current verification records. Do not deploy,
   publish a release, change the connection model, or accept terms for the owner.

## Implementation

- Added 29 complete translations to the existing English document: all 30 locales
  have eight terms sections and six privacy sections (420 sections in total).
  English remains the source; the approved meaning and consent version
  `2026-11-01` are unchanged. Each section has a stable identifier.
- `SpotifyDocuments` selects the app language through Foundation localization
  matching, including regional forms and Chinese scripts. Unsupported languages
  use English. A supported translation that is missing, incomplete, blank,
  mismatched or stale fails closed instead of silently allowing consent.
- The settings label shows the document's native language name. Documents remain
  available offline. The existing scrollable sheet displays all paragraphs.
- Full localized terms and privacy supplements use the same JSON files on the
  website. Each privacy route also includes the complete supplement. Links are
  clickable and isolated from surrounding RTL prose.
- Arabic Mac visual verification exposed reversed version segments and URL wrapping
  in RTL text. Display-only Unicode isolates preserve their order without changing
  the stored legal text. A regression test covers all four RTL locales.
- Updated the existing Figma consent annotation (`128:3540`, page `88:304`) through
  the figma-use skill; inspected the resulting annotation screenshot.
- Pages CI now watches Spotify resources and runs the document publication checks.
  Updated the music verification runbook, release notes, master specification and
  site publication instructions. Earlier reports remain historical records.

## Validation

| Check | Result |
|---|---|
| Mac build | Passed, including the final translation wording |
| Mac document, consent and localization suites | 12 tests passed |
| Website structure, navigation, assets and routes | 8 tests passed |
| Full document publication checks | 5 tests passed |
| Generated output | 120 pages in 30 languages verified current |
| App strings | 30 locales, 348 keys, permission prompts and formatting verified |
| Bundled resources | All 30 documents match the source JSON byte for byte |
| Strict Swift formatting and diff whitespace | Passed for changed Swift files; no whitespace errors |
| Visual/interactive checks | Russian Mac terms and privacy, complete scrolling; Arabic Mac and browser RTL |

The document tests verify all section IDs and paragraphs, language sets, version
consistency, per-section external URL parity, no English body substitution,
HTML escaping and RTL isolation. Mac tests also exercise regional fallback,
missing resources and invalid consent documents. Existing consent tests confirm
that connection cannot start before acceptance. No acceptance or live Spotify
operation was performed during this task.

Evidence logs: `/tmp/kinrox-spotify-document-tests-final.log`,
`/tmp/kinrox-spotify-doc-build-final.log`; the Xcode result bundle is under
`/tmp/kinrox-music-final-mac/Logs/Test/`. Screens were inspected through computer
use. A browser-host outage required the native Chrome interface for the local
preview; rendering was verified successfully there.

## Publication handoff and boundaries

Publish the 30 localized `/spotify-terms/` and `/privacy/` routes with the music
release before enabling its download. English uses root routes; other languages
use their locale prefix. Verify HTTP success, document version, language, all
sections and language navigation after deployment. Commands and rollout details
are in `site/README.md` and `docs/releases/UNRELEASED-MUSIC.md`.

This task prepares files, app resources and validation for publication. It does
not deploy the site, create a release/archive, change the Client ID model or
resolve unrelated Spotify approval questions. No independent native-speaker or
legal review was performed. No iOS code or runtime behavior changed; all public
document routes remain available to iPhone browsers. Existing licensing edits and build
artifacts were preserved; no commits, branches or worktrees were created.
