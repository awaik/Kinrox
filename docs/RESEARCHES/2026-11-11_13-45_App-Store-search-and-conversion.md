# Kinrox Remote — App Store search and conversion

Status: approved by the owner on 2026-11-11 (all proposals, no Spotify in the listing, no
ratings prompt, Mac QR code and link). Metadata kit updated for all 35 localizations;
eight-screen set rendered for all locales from Figma `229:304`
(`AppStore/screenshots/export-20261111-v2`); Mac QR implemented locally. Not yet in App
Store Connect: name, subtitle, keywords and screenshots ship with the next version
(Remote 0.2.2).

## Starting point

- Kinrox Remote 0.1.0 is live (App Store ID `6827926471`, released 2026-11-10), 0 ratings,
  categories Utilities + Entertainment, 35 localizations.
- The listing describes the October 0.1.0 scope only: video remote, recents, pairing.
  It does not mention music mode, favorites and queue, Similar, the Matrix screensaver
  or the Lock Screen controls (0.2.2 candidate).
- Name "Kinrox Remote" uses 13 of 30 characters; the subtitle "Your Mac movie remote"
  repeats "remote"; the en-US keyword field uses 61 of 100 bytes and spends space on weak
  terms (`local`, `playback`, `controller`). en-GB is a copy of en-US, so the widely
  cross-indexed en-GB keyword field adds nothing.
- Screenshots: the first three show the same remote screen with different captions;
  none shows the Mac, music, the Lock Screen or the fact that the Mac player is free.
- The Mac app has no link or QR code to the remote; only the website links to it.

## Evidence

### Search suggestions (App Store hints endpoint, 2026-11-11)

Suggestions exist only for queries people type; competitors' names show what ranks.

| Query (US) | Suggestions returned |
|---|---|
| mac remote | mac remote, couchpad: mac remote, bridgekit: mac remote control, control my mac: remote, helm: mac remote controller |
| remote for mac | remote for mac, **remote for macbook**, fullcontrol: remote for mac, airnest, commanddeck |
| mac remote control | mac remote control, remouse, rimote |
| media remote | media remote, media remote – player control |
| vlc remote / iina | vlc remote, remote for vlc; **iina remote**, remote for iina |
| mkv player | mkv player, mkv video player (iPhone playback intent) |
| now playing / live activity | many apps; generic |
| computer remote / laptop remote | computer remote, phonepad – computer remote; laptop remote |
| spotify remote / spotify controller | **no suggestions** |
| movie remote / video player remote / mac media remote | none or TV-remote noise |

| Query (RU) | Suggestions |
|---|---|
| пульт для mac | **пульт для mac** |
| пульт для компьютера / ноутбука | both exist |
| управление компьютером / управление mac | both exist (touchnow – управление mac) |
| плеер mkv, плеер для фильмов, видеоплеер | exist (iPhone playback intent) |
| пульт для видео / фильмов / макбука | none |

DE: "fernbedienung mac", "mac remote", "remote for mac". FR: "télécommande macbook",
"telecommande mac". JP: "mac リモコン". ES/BR: no Mac remote suggestions.

### Competition (iTunes Search API top results, rating counts)

- "mac remote", "remote for mac": Remote Mouse (18.8k), Remote, Mouse and Keyboard (14.5k),
  then small apps — Control – Mac Remote Control (5), Rimote (1), FullControl (220).
- "mac remote control": the #1 result has 5 ratings. "iina remote": two apps with 0–1
  ratings. Exact-match names rank highly with almost no ratings, so a name containing
  "Mac Remote Control" can compete.
- RU "пульт для mac" / "пульт для компьютера": Remote Mouse (2.6k), "Пульт, мышь и
  клавиатура" (844), otherwise TV remotes — weak relevant competition.
- Kinrox Remote ranks only for "kinrox" today.

### Rules (sources in the research report, fetched 2026-11-11)

- Indexed: name (30), subtitle (30), keywords (100 bytes, commas, no repeats of name /
  subtitle / category words, plurals treated as duplicates), primary and secondary category,
  developer name. Not indexed: description, promotional text. Screenshot-caption OCR is
  claimed by some vendors but unproven (ConsultMyApp test, June 2025: no evidence).
- Cross-localization (AppTweak 2025-11, MobileAction 2026-04): the US storefront also
  indexes es-MX, ru, zh-Hans, ar, fr, pt-BR, zh-Hant, vi, ko; most other storefronts
  (DE, FR, ES, MX, BR, RU, IT, NL, KR, IN, CN) also index **en-GB**; Russia indexes ru +
  en-GB + uk; Japan indexes ja + en-US. Words are not combined across localizations.
- App Review: 2.3.7 (no trademarks or other app names in metadata; subtitles must not
  reference other apps), 4.1(c) (no other brand in the name), 5.2.1 (third-party
  marks and artwork; screenshot rejections with album art are documented), 5.2.2/5.2.3
  (authorization for third-party content and streaming "must be provided upon request").
  The keyword help page: "Names of other apps or companies aren't allowed."
- Spotify: the name must not contain "Spotify"; "for Spotify" is tolerated by its design
  guidelines; no co-branding or implied endorsement; content must be attributed. Its
  terms do not explicitly cover playback outside Spotify's own SDKs, which is how the Mac
  plays music through Soloist.
- Custom Product Pages can now be tied to keywords and appear in organic search (WWDC25;
  up to 70 pages). In-App Events have a "Major Update" type. Ratings prompts: at most three
  a year, after a completed action.

## Spotify in the listing

Recommendation: **do not mention Spotify anywhere in the App Store listing.**

- Name, subtitle and keywords: prohibited or high risk (4.1(c), 2.3.7, keyword rules).
- Description: allowed as one factual line, but the description is not indexed, so it
  brings no search traffic. It mainly invites a 5.2.2/5.2.3 request for authorization,
  where the Soloist playback path is the weak point.
- Screenshots: only Kinrox UI, demo mode, fictional titles, no album art or logos — as
  the current demo already does.
- Describe the feature generically: "Music mode: play, skip, like, queue and Similar for
  the music playing on your Mac." The website and the Mac app already explain Spotify,
  with its attribution, to people who want the details.
- The same applies to VLC, IINA, mpv, Plex, Netflix and YouTube: no names in metadata.
  "iina remote" has demand but the term is another app's name.

## Positioning

The remote is useless without the Mac player, and most searchers ("mac remote",
"пульт для компьютера") expect a generic mouse/keyboard remote. The listing should
therefore sell the pair and qualify the intent in the first screen:

> Free Mac video & music player + iPhone remote. Pause from the couch or the Lock Screen.

This turns a requirement into an offer (the Mac player is free and open source) and
filters out people who want a mouse remote, protecting ratings.

## Proposed metadata (0.2.2)

All lengths checked against the kit's limits (name/subtitle 30 characters, keywords
100 bytes). The other 32 localizations follow the same pattern in a second pass.

| Locale | Name | Subtitle | Keywords |
|---|---|---|---|
| en-US | Kinrox: Mac Remote Control | Movies & music from your couch | `macbook,video,player,media,film,laptop,computer,projector,pause,volume,lockscreen,widget,wifi,sofa` (98) |
| en-GB | Kinrox: Remote for MacBook | Video & music player control | `mac,movie,film,media,laptop,computer,couch,sofa,projector,pause,volume,lockscreen,wifi,home,cinema` (98) |
| ru | Kinrox: пульт для Mac | Управление кино и музыкой | `компьютера,ноутбука,макбука,видео,плеер,фильмов,wifi` (94) |

- en-GB is indexed by most non-English storefronts, so it carries a different English set
  from en-US instead of a copy.
- The US storefront also indexes ru, es-MX, fr, pt-BR, zh, ar, vi and ko; their own
  keyword fields stay in their language, but none should waste bytes on words already in
  their name or subtitle.
- Deliberately excluded: `mkv`, `mkv player`, `видеоплеер` (iPhone-playback intent; would
  bring installs that expect video on the phone), `tv`, `mouse`, `keyboard` (false),
  other app and company names.
- Promotional text (not indexed, editable without review): "New: control your Mac from
  the Lock Screen. Music mode with favorites, queue and Similar. Free Kinrox player for Mac."

## Screenshots (proposed order)

Up to ten are allowed; the first three appear in search results. Captions are short
outcomes; they also contain search words in case OCR indexing is real.

1. **Hero:** iPhone Lock Screen card next to a Mac/projector scene — "Pause your Mac from
   the Lock Screen". Requirement line rewritten as an offer: "Free Kinrox player for Mac".
2. **Video remote:** "Your Mac movie remote" — play, ±10/30 s, scrub, volume.
3. **Music:** music deck with demo track — "Your music on the Mac, in your hand".
4. **Similar:** "Keep the music going with similar tracks" (+ Not interested).
5. **Favorites & queue.**
6. **Free Mac player:** Mac window screenshot — "Free player for Mac: MKV, MP4, AVI and more.
   Open source."
7. **Privacy:** "No account. Local network. Encrypted."
8. **Matrix screensaver** (fun, memorable).

Requires Figma frames before rendering (project rule); the existing renderer and demo
capture pipeline can produce all localized sizes.

## Other levers

1. **QR code / link in the Mac app's "Connect iPhone" window and Welcome screen** — every
   Mac user is a qualified remote user; likely the largest single source of installs.
   Needs Figma and a Mac change.
2. **Ratings prompt** (`RequestReviewAction`) after a successful pairing and a few sessions,
   never during playback. The listing has 0 ratings; ratings weigh on ranking and
   conversion.
3. **In-App Event "Major Update"** for 0.2.2: "Lock Screen controls".
4. **Custom Product Pages tied to keywords:** one for movie/video intent, one for music intent.
5. **App Preview (15–20 s):** pause on the couch → seek → Lock Screen. Test with Product
   Page Optimization; it replaces screenshots in search results.
6. **Website SEO** (Google, not the App Store): comparison and "IINA/VLC alternative with
   iPhone remote" pages belong on kinrox.app, where naming other players is factual
   comparison, not App Store metadata.

## Risks

- Generic "mac remote" traffic expects mouse/keyboard control; mitigated by the first
  screenshot and subtitle stating the pair.
- Keyword changes are measurable only after release; track ranks for the queries above
  weekly (hints endpoint and Search API, or an ASO tool).
- A localized name in Russian ("Kinrox: пульт для Mac") changes the home-screen label only
  if the bundle display name changes; the App Store name and the bundle name are separate.

## Decisions and implementation (2026-11-11)

- Owner approved all proposals and the rule "no Spotify (or other third-party names) in the
  listing"; the ratings prompt is declined.
- `AppStore/copy/*.json` rewritten for 30 languages (name, subtitle, keywords, promotional
  text, description); en-GB, es-MX, fr-CA and pt-PT carry their own name/subtitle/keywords
  through a `locales` object. `Scripts/prepare-app-store.py` now takes the name from the
  copy, applies these overrides, rejects third-party names in any field and keywords that
  repeat name or subtitle words, and uses `https://kinrox.app` URLs. Metadata regenerated:
  30 languages, 35 localizations validated. Translations have no native-speaker review.
- Screenshot mockups: Figma `14 · App Store — Screenshots v2` (`229:304`), English and Russian.
  The renderer still produces the previous five-screen layout; rendering the new set for all
  locales is the next step. Screenshot 1 sells the Lock Screen card, so upload it only with
  Remote 0.2.2.
- Mac: QR code (generated locally with CoreImage) and "Open in App Store" in the Connect
  iPhone sheet and Settings → Remote, Help → "Kinrox Remote for iPhone…" (Figma `237:304`).
  Ships with the next Mac release.

- Screenshots rendered 2026-11-11 for 35 store localizations plus Persian (576 PNGs): English
  and Russian from their masters, the rest from localized copies of the English row with the
  app's own UI strings, Noto fonts for non-Latin scripts and right-aligned RTL headers. Device
  layouts stay left-to-right in RTL locales. Headlines in es, fr, it, nl, cs, el and ro were
  shortened ("pause without unlocking") to keep 86 px on two lines.

## Remaining

1. Release Mac (QR, Similar) and Remote 0.2.2 (Lock Screen, Similar) and submit the new
   metadata and screenshots with 0.2.2 (`AppStore/RELEASE-CHECKLIST.md`).
2. Native-speaker review of the new copy and screenshot texts.
