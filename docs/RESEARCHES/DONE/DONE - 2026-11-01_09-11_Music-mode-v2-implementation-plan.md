# Music mode v2 — implementation plan

Status: phases 0–6 implemented on 2026-11-01; final verification and release
boundaries are recorded in [Music Verification](../../runbooks/MUSIC-VERIFICATION.md).
D1–D3: opt-in Spotify on Mac, official Spotify Connect Web API, own Client ID in
Settings. Owner confirmed the physical iPhone music check. Changes remain
uncommitted and unreleased; no independent code review has taken place.

Date: 2026-11-01. Filename timestamp: Europe/Moscow.
Audience: the agent that implements the feature. Read [AGENTS.md](../../../AGENTS.md)
first; its rules override anything here.

## 1. Goal

Add a Music mode to the Mac player and the iPhone remote, following the approved
Figma design "v2 · three-column library" (Winamp clarity, Mercedes calm):

- One full window, three columns: Source → Albums → Tracks. No artwork anywhere.
- Every album row shows title, all artists and year; every track row shows title,
  all artists, album and length.
- ▶ in an album row plays the whole album immediately.
- ♥ is a one-click switch everywhere, with the owner's rules in section 4.
- A deck that never scrolls away: display (time, spectrum, title, artists, album,
  next track), transport, Shuffle and Repeat switches with LEDs, favorite, seek,
  output, queue and volume.
- iPhone remote: the same deck semantics, the queue and the ♥ sheet.

The music source is Spotify. Streaming happens on the Mac; the iPhone stays a LAN
remote and never talks to Spotify.

## 2. Design source of truth

Figma file [Kinrox — Design](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U),
page `08 · Music — Spotify` (page id `88:304`). Use the Figma MCP server
(`get_design_context`, `get_screenshot`) on these node ids. Demo names in the
mockups are illustrative.

| # | Frame | Node | Implement |
|---|---|---|---|
| 01 | Mac — All albums | `104:978` | Main layout, source column, album list, album header, track table, deck, status bar |
| 02 | Mac — Liked tracks | `105:1534` | Flat track list with an Album column; "All liked" row; silent ♥ removal |
| 03 | Mac — Search + ♥ popover | `105:2195` | ⌘F results in the same columns; the like popover |
| 04 | Mac — Queue | `110:2065` | Queue sections; grip and × on hover |
| 05 | Mac — Narrow window 1024 | `110:2673` | Below 1100 px: source picker, compact deck and title bar |
| 06 | iPhone — Remote | `111:2925` | Remote music screen |
| 07 | iPhone — Queue | `111:3063` | Queue; swipe to remove, hold to reorder |
| 08 | iPhone — ♥ sheet | `111:3177` | Bottom sheet after liking the current track |
| — | Components | `100:888` | All `v2 / …` components, variants and descriptions |
| — | Notes | `107:2557`, `107:2560`, `107:2563` | Interaction contract, layout and tokens, open questions |

Components: Heart, Play button, Toggle, Favorite button, Button, Checkbox, Check
row (Mac / iPhone), Like popover, Source row, Album row, Track row (Default /
Playing / Queue hover), Track header, Column header, Collection header, Deck
(+ compact), Title bar (+ compact), Status bar, Mobile track row. Heart, Play
button, Toggle, Favorite button and Checkbox are interactive in Present mode.

Layout numbers (note `107:2560`): window 1440 × 900 baseline; title bar 52, deck
124, status bar 28; columns 260 / 400 / fill; track table № 28 · title fill ·
artists 200 · album 190 (flat lists only) · ♥ 24 · time 56; rows 30 / 52 / 34;
radius 8 for controls, 6 for rows, 12 for the popover. Narrow window: albums 340
/ tracks fill. iPhone 402 × 874: rows 60, ♥ hit target 44 pt, check rows 52,
transport 68 / 92 / 68.

The Figma display time uses SF Pro Expanded because SF Mono is unavailable in
Figma. In code use `KinroxFont.monoDigits(_:)` or `.monospacedDigit()` for every
time and count. Mockup copy is Russian; source strings stay English (AGENTS.md
rule 1) and are translated through the existing `.strings` files (section 6.6).

## 3. Phase 0 — owner decisions and feasibility (blocking)

Do not write network, authentication or playback code until D1–D3 are recorded
in this document and, for D1, in AGENTS.md.

### D1. Internet exception to principle 4

Approved by the owner on 2026-11-01: Mac-only, opt-in Spotify access after account
connection, without a Kinrox server or analytics. Recorded in AGENTS.md.

The approved exception covers `accounts.spotify.com` and `api.spotify.com` only
for the connected Mac account. Spotify.app handles audio delivery. Privacy and
landing claims in all 30 locales now distinguish local playback from this optional
connection. The generated site has not been deployed.

### D2. Playback engine

Selected by the owner on 2026-11-01: option A, official Spotify Connect Web API.

| Option | How it plays | Pros | Cons |
|---|---|---|---|
| A. Spotify Connect control via Web API | Kinrox sends `/me/player` commands; audio plays in the official Spotify app or another Connect device | Official API; no audio code in Kinrox | Premium only; needs an active Spotify device; the Web API cannot remove or reorder queue items, so Kinrox must own the queue (6.3); state by polling |

Official Web API playback is the selected implementation; no librespot helper
or Apple Events automation is included.

### D3. Who can use it

Selected by the owner on 2026-11-01: option 2, each user supplies their own Client ID.

Development Mode imposes Premium and allowlist limits. A shared Client ID cannot
serve arbitrary public Kinrox users. Each user therefore supplies their own
Spotify developer app Client ID (PKCE needs no client secret).

### Phase 0 spike (after D1, before Phase 3)

A test-only spike, not shipped:
1. PKCE sign-in in the system browser with a loopback redirect
   `http://127.0.0.1:<port>/callback` (verify that Spotify currently accepts loopback
   IP redirects); refresh token stored in the Data Protection Keychain.
2. Read: liked tracks, saved albums, followed artists, owned and collaborative
   playlists, search.
3. Write: like/unlike a track, save/remove an album, follow/unfollow an artist via
   the consolidated `/me/library` endpoints; add and remove a playlist item.
4. Playback per D2: start an album at track 1, start an explicit ordered list of
   track URIs, pause, seek, next, volume, read position.
5. Measure request count and latency for "remove a track from all my playlists"
   with 50+ playlists, and behaviour under HTTP 429 `QUOTA_EXCEEDED`.

### Phase 0 evidence — 2026-11-01

The test-only `PlayerMacTests/SpotifySpike` target sources use the owner's public
Client ID via an environment variable. No credentials are included in source or
logs. OAuth PKCE with `127.0.0.1:43821/callback` succeeded after browser consent;
refresh credentials are stored in the Data Protection Keychain under a separate
Phase 0 service, not production settings.

- Read sweep: 760 liked tracks, 12 saved albums, 219 followed artists and 7
  editable playlists, with 282 playlist entries. 37 API requests including search
  and devices; indexing the editable playlists took 3.352 s.
- Confirmed `PUT` and `DELETE /v1/me/library?uris=spotify:<type>:<id>` for track,
  album and artist. Each previously saved item was restored immediately. The
  endpoint returns HTTP 200 with no JSON body.
- Confirmed `POST /v1/me/playlists` (201), `POST /v1/playlists/{id}/items` with
  `{"uris":[...],"position":0}` (201), and DELETE on the same path with
  `{"items":[{"uri":"..."}]}` (200). The empty private playlist
  **Kinrox Phase 0 verification** is intentionally retained.
- Playlist reads use `/items` and each entry's `item` field. Pagination is followed
  to completion; only owned/collaborative lists are indexed.
- Explicit `uris` playback reproducibly returns 204 but clears playback on the
  current Mac Spotify client; subsequent controls return 403 `Restriction violated`.
  This remains a failed feasibility check for the original ordered-URI design.
- Album context with `offset.position = 0` was verified against the observed first
  track URI. Seek to 10 seconds, pause, a private playlist context and next to its
  second ordered item were verified. `PUT /playlists/{id}/items` with `uris` replaces
  contents (200); the verification playlist was emptied after the test.
- The final playback test caught volume 82 rather than zero despite an earlier
  successful volume request. Spotify was subsequently muted and paused through its
  own UI, visibly confirmed. Do not treat a command acknowledgement as observed
  state. Future live tests must confirm volume immediately before play and retain
  the volume assertion while polling.
- A [first-person Spotify Community report](https://community.spotify.com/forum/en/discussion/7552922/web-api-me-player-play-returns-204-but-does-not-start-playback-and-clears-current-playback-desktop)
  independently describes this desktop URI-list regression. The supported
  [play endpoint](https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback)
  accepts album and playlist contexts. The proposed production workaround is one
  private **Kinrox Queue** playlist, explicitly approved by the owner on 2026-11-01.
  Phase 3 account/library and Phase 4 playback may proceed on the verified endpoints. This is an implementation adjustment, not a change of D2 API.
- Large-library fixture: 55 playlists, 11 containing two copies of the target.
  Warm index performs zero item reads; unlike produces 12 writes (one library,
  eleven playlists). Policy plus undo took 0.351 ms locally. This is a synthetic
  size test, not measured Spotify latency for a 55-playlist account.
- Stubbed HTTP 429 `QUOTA_EXCEEDED` preserves `Retry-After: 7` and makes one request.
  No quota exhaustion is intentionally induced on the real account.

### Implementation and design completion

All phases are implemented. The verification runbook holds final test counts,
visual artifacts, live observations and limitations rather than stale checkpoints.
The owner additionally approved:

- Official Spotify attribution on Mac and iPhone; the Mac logo opens Spotify.
- A single recovery line in column 3 with Settings or Retry. Figma component
  `116:3116` and variants `117:3098`, `117:3101`, `117:3104`, `117:3107`,
  `117:3110` cover disconnected, offline, re-auth, Premium, other-device and
  unavailable states. Favorites failures remain in the bottom status bar.

API shapes in the spike above were verified live; library contains uses
`GET /me/library/contains?uris=...`. Errors, quota cooldown and large-library
behaviour are covered with controlled fixtures, not forced on the live account.
Primary references checked on 2026-11-01:
[February migration guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide),
[July quota update](https://developer.spotify.com/blog/2026-07-23-web-api-quota-updates),
[library API](https://developer.spotify.com/documentation/web-api/reference/save-library-items),
[design guidelines](https://developer.spotify.com/documentation/design).

## 4. Behaviour contract

These rules are owner decisions of 2026-11-01 and are the acceptance criteria for
the favorites code. Test each one.

### ♥ on a track

- **Off → on.** Like the track immediately (optimistic UI). Then open the like
  popover anchored to the heart (Mac) or the ♥ sheet (iPhone):
  - "Add to playlist": playlists the user owns or collaborates on, each with a
    checkbox showing whether the track is already in it, plus "New playlist…".
  - "Follow": every artist of the track, checked when already followed.
  - Every tick applies immediately; there is no Save button. Esc, a click outside,
    or "Done" on iPhone closes. Closing never undoes anything.
- **On → off.** No popover, dialog, toast or status message. Remove the like and
  remove the track from every playlist the user owns or collaborates on. **Never
  unfollow artists**: unfollowing is a separate, manual ♥ on the artist. Only the
  heart turns off; the row stays in place until the list is reloaded or left.
- Other people's playlists are never changed.
- The deck's labelled Favorite button and the L key behave exactly like the heart
  of the current track (deck) or the focused row (L).

### ♥ on an album or artist

Album: save or remove the album. Artist: follow or unfollow. One click, silent. An
album heart does not like its tracks; a track heart does not save its album.

### Undo and errors

- ⌘Z silently undoes the last ♥ change: restore the like and re-add the track to
  the playlists it was removed from (at its previous position when the API allows),
  or revert an album or artist change. Keep it unless the owner removes it.
- A failed request reverts the optimistic state and shows one line in the status
  bar with Retry. This is the only message the ♥ flow may show. It is not drawn:
  use the status bar typography and keep the text short.

### Playback and navigation

- Selection flows left to right; nothing opens over the columns except the like
  popover and menus.
- ▶ in an album row plays the album from track 1. Enter or double-click plays a
  track in the context of its list. Space pauses. ⌘F focuses search; Esc leaves it.
- Search covers the whole Spotify catalogue and fills the same three columns.
- Queue order: now playing, added manually, then the source list. Dragging by the
  grip reorders; × or Delete removes from the queue only.
- Below 1100 px the source column becomes a picker above the albums, the deck
  drops the output label and queue button, and volume moves beside the seek bar.
  Below 760 px is out of scope.
- Video / Music only switches the view. Starting playback in one mode pauses the
  other engine first ("one sound at a time"). Browsing never interrupts playback.
- Switch labels never change; the LED or filled heart shows the state.

### Out of scope

iPhone album browser (hide its "Albums" button until designed), windows below
760 px, additional recovery dialogs (approved inline status text is implemented), downloads,
lyrics, Canvas, social features and artwork.

## 5. Existing code to build on

Verified on 2026-11-01. Paths are repository-relative.

| Area | Where | Relevance |
|---|---|---|
| App entry | `PlayerMac/PlayerMac/App/KinroxPlayerApp.swift` | No window scene; only `Settings { RemoteSettingsView }` and `.commands { PlayerCommands }`. Spotify settings go into the Settings scene |
| App lifetime | `App/AppDelegate.swift`, `App/PlayerSession.swift` | `AppDelegate.showPlayer()` builds the single `PlayerWindowController` and the `NowPlayingController`; `close(_:)` shuts the model down. `PlayerSession` (`@MainActor @Observable`) holds `model`, `remote`, `recents`, `pairing`, `updates` — the natural owner of app-lifetime music services |
| Window | `Player/PlayerWindowController.swift` | One 1120 × 630 `NSWindow` (min 640 × 360) hosting `PlayerView`; the only `MPVPlayer` is created here |
| Video UI root | `Player/PlayerView.swift` | `ZStack` of video, overlays, `WelcomeView`; forces dark scheme. There is **no Video / Music mode** today |
| Menus | `App/PlayerCommands.swift`, `App/TrackCommands.swift` | Playback menu keys are gated by `session.canControl` / `trackShortcutsAllowed` |
| Engine protocol | `Player/PlayerEngine.swift` | `@MainActor protocol PlayerEngine: AnyObject` with `events: AsyncStream<PlaybackEvent>`, `load`, `setPaused`, `seek(relative:)`, `seek(absolute:)`, `setVolume`, `stop`, `shutdown() async`. AGENTS.md §4.5 shows an older shape |
| Video model | `Player/PlayerViewModel.swift`, `+Commands.swift` | `@MainActor @Observable`; observers via `observePlayback(_:) -> UUID`; command methods return `Bool` |
| Now Playing | `NowPlaying/NowPlayingCenter.swift`, `NowPlayingController.swift` | `NowPlayingController.connect(to: PlayerViewModel)`; `SystemNowPlayingCenter` disables like, rating, shuffle and repeat |
| Theme | `Shared/Design/KinroxTheme.swift`, `Resources/Branding.xcassets` | Tokens in 6.4; `KinroxFont.monoDigits`, `overline`, `timeLarge`; `kinroxGlass(in:tint:interactive:)` |
| Remote server | `PlayerMac/PlayerMac/Remote/RemoteServer.swift`, `RemoteServer+Commands.swift`, `RemoteStatePublisher.swift` | `execute(_:) -> ProtocolError.Code?` switch over `Command`; `snapshot` builds `PlayerState`; position-only updates throttled to 2 Hz |
| Protocol | `Packages/RemoteProtocol/Sources/RemoteProtocol/` | `Command` + `Command.Kind` with manual coding; `PlayerState` with optional `screensaver`; `MessageType`; `Codec.maxMessageBytes = 64 * 1024`; `Version.current = 1` |
| Protocol tests | `Packages/RemoteProtocol/Tests/RemoteProtocolTests/` | `CodecFixtureTests.coverage` requires a byte-exact fixture in `Fixtures/v1/` for every `Command.Kind` and `MessageType`, declared in `FixtureSamples.swift` |
| iPhone | `RemoteiOS/RemoteiOS/App/RootView.swift`, `Connection/RemoteAppModel*.swift`, `Remote/RemoteView.swift`, `Demo/` | `RemoteAppModel.Screen`; `supportsScreensavers` is the additive-field pattern; `performDemo(_:)` is an exhaustive switch over `Command` |
| Localization | `Resources/Localization/<lang>.lproj/{Localizable,InfoPlist}.strings`, `Shared/Localization.swift`, `Scripts/check-localization.py`, `SharedTests/LocalizationTests.swift` | 30 locales; `L10n.text` / `L10n.format` with `%@` only; every used key must exist in all locales and no key may be unused |
| Dependencies | `PlayerMac/project.yml`, `RemoteiOS/project.yml`, `Config/Shared.xcconfig` | PlayerMac: local `RemoteProtocol`, Sparkle `exactVersion: 2.10.1`; macOS 14 / iOS 17; Swift 6, complete concurrency |
| Entitlements | `PlayerMac/PlayerMac/PlayerMac.entitlements`, `Config/PlayerMac.xcconfig` | Not sandboxed, Hardened Runtime on; outbound HTTPS needs no new entitlement |
| Test fakes | `PlayerMac/PlayerMacTests/FakePlayerEngine.swift`, `FakeNowPlayingCenter.swift`, `RemoteServerHarness.swift`; `RemoteiOS/RemoteiOSTests/RemoteTestSupport.swift` | Swift Testing only; copy these patterns for music fakes |

AGENTS.md §4.5, §6.3 and §6.5.1 were corrected to match the code on 2026-11-01.
`Palette.bgDeep`, `bgPanel`, `bgPill` and `textMuted` reference colour sets that do
not exist, so do not use them.

## 6. Architecture

### 6.1 Placement

| Piece | Location | Notes |
|---|---|---|
| Domain models, ♥ policy, queue, selection | new package `Packages/KinroxMusic`, target `MusicCore` | Foundation only, `Sendable` value types, fully unit tested |
| Spotify client | `Packages/KinroxMusic`, target `SpotifyWebAPI` | Linked into PlayerMac only, never into RemoteiOS |
| Mac services | `PlayerMac/PlayerMac/Music/` | `MusicLibraryStore`, `FavoritesService`, `PlaybackCoordinator`, engines |
| Mac UI | `PlayerMac/PlayerMac/Music/UI/` (subfolders per column and deck) | SwiftUI; files under 500 lines |
| Mode switch | `PlayerSession` + a new window root view | See 6.5 |
| Remote messages | `Packages/RemoteProtocol` | Additive v1 fields, commands and message types |
| iPhone UI | `RemoteiOS/RemoteiOS/Music/` | Demo store first, then the live connection |

Add `KinroxMusic` as a local package in `PlayerMac/project.yml` and to
`Kinrox.xcworkspace`; run `./Scripts/generate.sh`.

### 6.2 Engine protocol

Production protocol (async completion requires observed state):

```swift
@MainActor
protocol MusicEngine: AnyObject {
    var events: AsyncStream<MusicEngineEvent> { get }
    func play(queue: MusicQueue, position: Double) async throws
    func setPaused(_ paused: Bool) async throws
    func seek(absolute position: Double) async throws
    func setVolume(_ volume: Double) async throws
    func updateQueue(_ queue: MusicQueue, position: Double, paused: Bool) async throws
    func stop() async throws
    func shutdown() async
}
```

`MusicEngineEvent` (`Sendable`) carries position, duration, current track URI,
paused, end of track, device name and errors. Kinrox owns the queue
(`MusicQueue`); the coordinator hands the engine an ordered URI list, so queue
editing does not depend on Web API queue support. Owner-approved Phase 0 adjustment:
the Connect engine mirrors the ordered queue into its dedicated private **Kinrox
Queue** playlist and starts that context; raw `uris` playback is broken in the
current Spotify desktop client. The helper playlist is identified by its stored
id, never by name alone, and is excluded from user favorites membership operations. Add `FakeMusicEngine` in the
style of `FakePlayerEngine`.

### 6.3 Data flow

User action → `MusicViewModel` → `FavoritesService` or `PlaybackCoordinator` →
`SpotifyWebAPI` or `MusicEngine` → store update on `@MainActor` → SwiftUI, Now
Playing and remote state. The engine is the source of truth for playback, as mpv
is for video. Spotify is the source of truth for the library; the local
`LibrarySnapshot` is a cache.

`PlaybackCoordinator` (`@MainActor @Observable`, owned by `PlayerSession`):

- knows the active source (video or music) and pauses the other engine before
  starting one;
- owns media keys and Now Playing: generalise `NowPlayingController.connect(to:)`
  to a small `NowPlayingSource` protocol implemented by `PlayerViewModel` and the
  music model, so there is still exactly one Now Playing session;
- decides what happens when the window closes (default: stop music too, matching
  "window closure tears down Now Playing").

### 6.4 Tokens

Use only existing `Palette` tokens. Figma variable → `Palette`:

| Figma | Palette | Use |
|---|---|---|
| `bg/base` | `base` | Display background |
| `bg/canvas` | `canvas` | Columns |
| `bg/elevated` | `elevated` | Title bar, deck, status bar, popover |
| `surface/glass`, `surface/glass-strong` | `glass`, `glassStrong` | Controls, selected rows |
| `stroke/hairline`, `stroke/glass` | `hairline`, `strokeGlass` | Dividers, outlines |
| `text/primary`, `text/secondary`, `text/tertiary` | `textPrimary`, `textSecondary`, `textTertiary` | Text |
| `accent/ember` | `ember` | State: ♥, playing, LED, ticks |
| `accent/flame` | `flame` | Display time, playing title, links |
| `state/online` | `online` | Connected account dot |

### 6.5 Window and mode switch

There is no mode concept today. Add `enum AppMode { case video, music }` to
`PlayerSession` and a root view in `PlayerWindowController` that shows `PlayerView`
or `MusicView`, with the centred Video / Music segmented control from the Figma
title bar. Keep `PlayerView` untouched apart from the switch. When entering Music,
raise the window to at least 1024 × 768 and apply the music minimum size; restore
the video minimum (640 × 360) when leaving. Add View menu items "Video" (⌘1) and
"Music" (⌘2). Route the Playback menu (Space, arrows) to the active source through
`PlaybackCoordinator`, keeping the existing `canControl` gating for video.

### 6.6 Localization

New UI strings use English keys through `L10n.text` / `L10n.format` and must be
added to all 30 `Resources/Localization/<lang>.lproj/Localizable.strings` files.
Run
`python3 Scripts/check-localization.py`; `SharedTests/LocalizationTests.swift`
runs in both app test targets.

## 7. Phases

Each phase ends with its checks passing and this document updated. Phases 1–2 may
start before the Phase 0 decisions; Phases 3–5 may not.

### Phase 1 — music domain core (no network, no UI)

- `Packages/KinroxMusic` / `MusicCore` (swift-tools 6.0, macOS 14 / iOS 17,
  `swiftLanguageModes: [.v6]`, like `RemoteProtocol`):
  - Models: `MusicTrack`, `MusicAlbum`, `MusicArtist`, `MusicPlaylist` with
    Spotify ids/URIs, durations and full artist lists; playlist ownership and
    collaborative flag.
  - `LibrarySnapshot`: liked track ids, saved album ids, followed artist ids,
    editable playlists and their membership.
  - `FavoritesPolicy`: pure functions turning a ♥ action into `[LibraryMutation]`
    plus an undo record, implementing section 4 exactly.
  - `MusicQueue`: now playing, manual items, source context; add, remove, move,
    shuffle, repeat, next and previous.
  - `BrowserSelection`: source → album → track selection and derived column
    contents for library, liked tracks, playlists, artists, queue and search.
- Swift Testing suites covering every rule in section 4 — in particular "unlike
  never unfollows" and "never touch other people's playlists" — plus queue
  operations and selection derivation.
- Demo data matching the Figma names.

Done when `swift test --package-path Packages/KinroxMusic` passes.

### Phase 2 — Mac UI on demo data

- Mode switch (6.5) and `MusicView` with `MusicTitleBar`, `DeckView` (+ compact),
  `SourceColumn`, `AlbumColumn`, `TrackTable`, `CollectionHeader`, `LikePopover`,
  `MusicStatusBar`, `QueueView`.
- `@Observable @MainActor` `MusicViewModel` over a `MusicLibraryStore` protocol with
  a demo implementation (the approach M2 used for remote screens).
- Keyboard: Space, Enter, L, ⌘F, Esc, ⌘Z, Delete, arrows within a column, Tab
  between columns.
- Accessibility labels and values for every heart, checkbox and switch; the
  display is readable by VoiceOver.
- Localized strings (6.6).
- Compare with Figma frames 01–05 at 1440 × 900 and 1024 × 768.

Done when PlayerMac builds and tests pass and the owner has seen the demo build.

### Phase 3 — Spotify account, catalogue and library (after D1 and D3)

- `SpotifyWebAPI`: PKCE auth, token refresh, typed endpoints, paging, 429 handling
  with `Retry-After` and `QUOTA_EXCEEDED`. Tests use a stubbed `URLProtocol`; no
  live calls in automated tests.
- Settings: a Spotify section in the Settings scene (Connect, Disconnect, account
  name, and the Client ID field if D3 option 2). Tokens in the Data Protection
  Keychain, following `KeychainPairedDeviceStore`; never in logs or `UserDefaults`.
- `SpotifyLibraryStore` implements `MusicLibraryStore`: initial sync, incremental
  refresh, debounced search, and a playlist membership index keyed by
  `snapshot_id`, so "remove from all my playlists" does not re-read every playlist.
- `FavoritesService` executes `FavoritesPolicy` mutations in API-sized batches,
  applies them optimistically, rolls back on failure and keeps one undo record.

### Phase 4 — playback (after D2)

- `MusicEngine` implementation per D2 and `PlaybackCoordinator` (6.3).
- Deck state: position, duration, next track, shuffle, repeat, volume, output name.
- Now Playing and media keys for music through the same controller.

### Phase 5 — remote protocol and iPhone

- Additive extension of protocol v1 following the screensaver precedent:
  - `PlayerState`: optional `source` (video | music) and optional `music` block
    (title, artists, album, year, next track, liked, shuffle, repeat, queue count).
    A missing block means an older Mac; the remote hides music controls, like
    `supportsScreensavers`.
  - Reuse `togglePause`, `seekAbsolute`, `setVolume`, `next` and `previous`. Add
    commands: `setTrackLiked`, `setPlaylistMembership`, `setArtistFollowed`,
    `setShuffle`, `setRepeat`, `queueMove`, `queueRemove`, `createPlaylist`.
  - Add message types for paged replies: `requestQueue` / `queue` and
    `requestLikeOptions` / `likeOptions`. Every page must fit
    `Codec.maxMessageBytes` (64 KiB).
  - New fixtures in `Fixtures/v1/` and entries in `FixtureSamples.swift` for every
    new `Command.Kind` and `MessageType`; old-client and old-server compatibility
    tests as in `ScreensaverProtocolTests`.
- Mac: extend `RemoteServer.execute(_:)` and `snapshot`; publish music state
  through `RemoteStatePublisher`.
- iPhone: screens 06–08 under `RemoteiOS/RemoteiOS/Music/`, demo store first, and
  the new cases in `performDemo(_:)`. The ♥ sheet follows section 4; the remote
  shows a change only after the Mac confirms it.

### Phase 6 — states, documentation, release

- Recovery states in column 3 (not signed in, offline, re-auth, Premium required,
  empty search, playing on another device, service unavailable); ask the owner
  for Figma designs first (AGENTS.md 3.5).
- `docs/runbooks/MUSIC-VERIFICATION.md`.
- AGENTS.md: status line, principle 4 exception, Figma page row in 3.5, music
  modules in 3.1 and 3.2.
- Privacy page and landing claims in all 30 locales; release notes.

## 8. Verification

- `swift test --package-path Packages/KinroxMusic`
- `swift test --package-path Packages/RemoteProtocol`
- PlayerMac and RemoteiOS build and test, `xcrun swift-format lint --strict`, the
  500-line check and `python3 Scripts/check-localization.py`, as listed in
  [RUNBOOK-TASK-TESTS](../../runbooks/RUNBOOK-TASK-TESTS.md).
- Manual check with a Premium account: connect; browse; play an album from its
  row; like a track, tick a playlist and an artist; unlike it and confirm it left
  every editable playlist while the artist stays followed; ⌘Z; queue reorder and
  remove; narrow window; Video ↔ Music switching with one sound at a time; iPhone
  screens 06–08 on a physical device.
- Keep Kinrox playback volume at 0 for every playback check (AGENTS.md rule 7).
  With options A or C the audio plays in Spotify.app: lower it there, never the Mac
  system volume.

## 9. Risks

| Risk | Mitigation |
|---|---|
| Spotify platform requirements | Official Web API selected; no librespot or Apple Events |
| Access limits (allowlist, Premium owner, account quota) | D3; explain an access denial clearly in Settings |
| API churn (2026 endpoint removals) | All endpoints in one client target; fixture-based contract tests |
| "Remove from all playlists" is expensive and hard to reverse | Membership index, batching, undo record, tests |
| Duplicate copies of a track are removed together | Accept; mention it in the undo implementation |
| Spotify branding and attribution rules for displayed metadata | Official logo and Mac link implemented; public-release policy review remains explicit in the verification runbook |
| Principle 4 and privacy claims | D1; privacy update in Phase 6 |
| 64 KiB remote frame limit | Paged queue and like-options replies |
| 500-line file limit | Split views and stores from the start |

## 10. Rules for the implementing agent

- Follow AGENTS.md: English source, Swift 6 complete concurrency, `@Observable`
  `@MainActor` UI models, files under 500 lines, tests before handoff, no branches,
  commits or worktrees; leave changes uncommitted.
- Design changes go to Figma first; do not invent screens that are not drawn.
- Keep this document current: status line, decisions, spike results, checks.
