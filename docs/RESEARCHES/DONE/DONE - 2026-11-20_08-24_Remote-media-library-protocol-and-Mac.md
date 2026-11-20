# Remote Media Library — Part A: Protocol and Mac Server

- **Date:** 2026-11-20 08:24 (Europe/Moscow)
- **Figma page:** `18 · Remote — Медиатека на пульте` (`node-id=334-304` in
  [Kinrox — Design](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox?node-id=334-304)).
  Screens `R18 · 01`–`R18 · 08`, edge states `R18 · 09`, notes frame
  `Notes / R18 · Правила, протокол и вопросы` (`342:664`). Mockup copy is Russian; source strings
  stay English.
- **Part B (separate document, later):** the RemoteiOS user interface. This document must
  leave RemoteiOS runtime behavior unchanged and keep it compiling cleanly.
- **Affected targets:** `RemoteProtocol` and `RemoteTransport` (`Packages/RemoteProtocol`,
  including `Crypto/SessionFailure.swift`, `Crypto/ServerHandshake.swift`,
  `RemoteTransport/ServerSession.swift`, `RemoteTransport/TransportClient.swift`,
  `RemoteProtocolTests`, `RemoteTransportTests`), `PlayerMac` (`Remote/`, `MediaLibrary/`,
  `LocalAudio/`, `App/`), `PlayerMacTests`, `kinrox-cli` and `RemoteiOS` only for compile
  fixes, `AGENTS.md` Sections 3.5 and 6.3.
- **Suggested implementation model:** agy `Gemini 4 Neon (XHigh)`, `EXEC_EFFORT=xhigh`
  (protocol and concurrency work, `AGENTS.md` Section 11).

Status: Implemented locally; not released.

---

## 1. Owner decisions (2026-11-20)

1. The remote's `Video | Music` control becomes a real tab switcher. The selected tab is the
   phone's choice; ember bars mark the source the Mac is actually playing. Switching a tab never
   starts or pauses playback.
2. Video tab: when a video is the active loaded source, show the video remote; otherwise show
   the Mac media library (Continue Watching, movies and series, filters, search).
3. Music tab has a bottom source switch `Music on Mac | Spotify`. Spotify shows the existing
   Spotify remote. Music on Mac shows the local-track remote when a local track is loaded, and
   the local library (albums, album tracks, shuffle all, search) otherwise. The switch opens on
   the source playing on the Mac; when nothing plays, on the last selected source.
4. Tapping a movie or an unstarted item opens a details card first (`R18 · 02`). Continue
   Watching items resume immediately on tap.
5. Starting from the iPhone equals starting from Home on the Mac: the playback coordinator
   pauses the other source. The video opens in the normal player window, **not fullscreen**.
6. Real posters and album covers are sent from the Mac; if one cannot be loaded, the remote
   shows a colored placeholder.
7. Search is part of version 1.
8. Offline (disconnected drive) items stay visible but cannot be started; tapping one explains
   which drive/folder needs to be connected (`R18 · 09` State 3).
9. No filesystem paths cross the network (`AGENTS.md` Sections 3.4 and 6.3): only opaque
   identifiers, titles, metadata, the file name and the watched folder's display name.

## 2. Verified codebase facts

| Area | Path | Fact relevant to this plan |
|---|---|---|
| Message envelope | `Packages/RemoteProtocol/Sources/RemoteProtocol/Message.swift` | `MessageType` is `CaseIterable`; `requestState` currently decodes `EmptyBody` (lines 131–137, 198–211), ignoring unknown keys so old Macs accept `requestState` with extra fields. Adding `public static func requestState(_ header: Header) -> Self` alongside `case requestState(Header, StateRequest)` preserves existing `.requestState(.init())` call sites and `Fixtures/v1/requestState.json`. |
| Channel & transport gates | `Crypto/SessionFailure.swift:54–62`, `Crypto/ServerHandshake.swift:96–102`, `RemoteTransport/ServerSession.swift:46–51`, `RemoteTransport/TransportClient.swift:94–99` | Four non-exhaustive `switch` statements with `default:` branches gate application messages: `isApplicationMessage` (`SecureChannel.seal`/`open`), pre-auth `.notPaired` (`ServerHandshake.receive`), client→server delivery (`ServerSession.receive`), and server→client delivery (`TransportClient.receive`). All four must include the new message types or connections close with `.invalidPayload` / `.invalidMessage`. |
| Paging & validation | `MusicState.swift` (`QueueRequest`, `QueuePage`), `Message+MusicValidation.swift:49` | Pages carry `replyTo`, `revision`, `offset`, `total`, `nextOffset`, at most 50 items. `validPage` is currently `private static` in `Message+MusicValidation.swift` and must become `internal` for reuse in `Message+LibraryValidation.swift`. `RemoteMusicBridge.queuePage` (lines 88–115) halves `count` until `Codec.encode` fits `Codec.maxMessageBytes - 28`. |
| Identifier rule | `Command.swift:174` `validMusicID` | Alphanumerics, `-`, `_`, non-empty, at most 128 UTF-8 bytes. Use the same rule for all library and artwork identifiers. |
| Error codes | `ProtocolError.swift`, `RemoteServer+Commands.swift:79–85`, `RemoteAppModel+Connection.swift:366–379` | `RemoteServer+Commands.message(for:)` emits unlocalized English wire strings (not `L10n.text`); `RemoteiOS` localizes by `error.code` with a `default:` fallback. `Scripts/check-localization.py` rejects both missing and unused `L10n` keys across all 30 `.lproj` catalogs. |
| Publisher & outbox | `RemoteStatePublisher.swift:28–37`, `RemoteOutbox.swift:18–25` | `RemoteStatePublisher` checks `positionOnly` by reconstructing `PlayerState` manually; copying `var candidate = state; candidate.position = previous.position` is required so non-nil `library`/`sources` do not bypass the 2 Hz throttle. `RemoteOutbox` disconnects at `messages.count >= 32`; warm-cache artwork bursts must drain with backpressure rather than synchronously enqueuing > 32 replies. |
| Snapshot & observers | `RemoteServer.swift:235–250, 297–341, 352–376` | `.authenticated` sends `.state` before the client can send `requestState`. `localAudioObserver` currently guards on `activeLocalAudio != nil` (missing background pause/shutdown updates for `sources.localMusic`), and `.requestQueue`/`.requestLikeOptions` currently route unconditionally to `musicBridge` (Spotify). Existing tests (`RemoteServerTests.swift:198`, `LocalAudioPlaybackTests.swift:88–89`) construct `RemoteServer` without a library bridge and assert `state == server.snapshot` and `source == .video, music == nil`. |
| Local audio model | `LocalAudio/LocalAudioViewModel.swift` (461 lines) | Stores raw POSIX paths in `MusicTrack.id` and `artist + "\u{1f}" + album` in `albumID` (lines 441–448), both invalid under `validMusicID`. Only exposes `move(_:by: Int)`, `toggleShuffle()`, `cycleRepeat()`, and `Void`-returning `remove(_:)` (lines 201–223). Keep under 500 lines by placing explicit remote queue helpers in `LocalAudioViewModel+Queue.swift`. |
| Playback & coordinator | `AppDelegate.swift:73–82, 156–212`, `PlaybackCoordinator.swift:47–117, 164–187`, `PlayerViewModel+Commands.swift:28–54`, `PlayerViewModel+WatchProgress.swift:83–96` | `PlayerViewModel.resume`/`open`/`setPaused(false)`, `LocalAudioViewModel.play`/`setPaused(false)`, and `MusicViewModel.setPaused(false)` already serialize through `PlaybackCoordinator` internally; wrapping them in an outer `PlaybackCoordinator.start` double-runs transitions. `setPaused(false)` on video or local audio returns `false` while `isScreensaverEngaged` is true unless `stopScreensaver()` runs first. Window close (`⌘W`) nils `session.model` and disconnects `NowPlaying` until `showPlayer()` recreates the window. |
| Catalog & folders | `MediaLibraryStore.swift`, `MediaLibraryStore+Catalog.swift`, `MediaLibraryStore+Enrichment.swift:79`, `MediaLibraryDatabase+Queries.swift:199–227`, `HomeOverviewView.swift:20–34` | `MediaLibraryStore` has no observer callbacks yet (`reload()`, `enrich()`, `scan()`, and `record(_:)` mutate `@Observable` properties). `MediaLibraryFile` has no `folderId` in memory; match `WatchedFolder.displayName` by longest canonical `folder.path` prefix. `LocalSeriesGroup.next` returns `nil` when all episodes are completed (`HomeVideoLibraryView.swift:104` falls back to `episodes.first`). Mac Home `Continue Watching` appends non-indexed `RecentFilesStore` videos that have unfinished `WatchProgress`. |
| Artwork | `MediaLibrary/ArtworkCache.swift` | `actor ArtworkCache` stores 480 px JPEGs keyed `<sha256>.jpg` (content-addressed by SHA-256 of source bytes); `thumbnail(_:)` returns cached data. Posters come from `MediaEnrichment.posterPath`, local covers from `LocalAudioTags.artworkPath` (or album/enrichment fallback in `LocalAudioTrack.artworkPath`). |
| Frame budget | `AGENTS.md` 6.2 / 6.5.1, `Codec.swift`, `SecureChannel.swift` | 65,536-byte WebSocket frames, 28 bytes of ChaCha20-Poly1305 AEAD overhead (`SecureChannel.maxPlaintextBytes = 65,508`); JSON encodes `Data` as canonical Base64 (+33%). Oversized outbound frames close `SecureChannel`. |

## 3. Protocol design (additive v1, backward compatible)

All new fields are optional and all new server-initiated behaviors preserve older clients.
Envelope version stays `1`.

### 3.1. Feature declaration and per-connection projection

- `requestState` gains an optional body `StateRequest { features: [String]? }`
  (when non-nil: at most 16 entries, each non-empty and at most 64 UTF-8 bytes). When `features`
  is `nil`, `StateRequest` encodes `{}` so wire bytes match legacy `EmptyBody`. Provide
  `public static func requestState(_ header: Header) -> Message { .requestState(header, .init()) }`
  so existing `.requestState(.init())` callers compile unchanged. Old Macs ignore `features`.
- A new remote sends `requestState { features: ["library.v1"] }` right after `connected` / `authOk`
  (Part B), and the Mac stores the declared feature set per `connectionId` and immediately
  enqueues a projected `.state` for that connection.
- **Projection rule (no "Update Mac" flash, full 0.2.2 compatibility):**
  - When `RemoteLibraryBridge` is attached (`libraryBridge != nil`), `PlayerState.library` and
    `PlayerState.sources` are included on all `state` messages, including the initial `.state`
    sent on `.authenticated` before `requestState` arrives. Old `RemoteiOS` (`0.2.2`) ignores
    unknown JSON keys `library` and `sources`, while new `RemoteiOS` (and Lock Screen background
    sessions) see `state.library != nil` on the very first frame without flashing the older-Mac
    warning (`R18 · 09` State 5). When `libraryBridge == nil` (isolated unit harnesses), both
    fields remain `nil`.
  - Active local-audio representation IS gated on `features.contains("library.v1")`: connections
    with `"library.v1"` receive `source: .music` and `music: MusicState(origin: .local, ...)`
    (Section 3.5); connections without `"library.v1"` receive today's exact representation
    (`source: .video`, `music: nil`, `title: track.title`, `position`, `duration`, `paused`,
    `volume`, `canNext`, `canPrevious`).
  - Keep a single `RemoteStatePublisher` fed with the canonical (`library.v1`) snapshot. At send
    time, project `PlayerState` per connection and track `lastSentState[connectionId]` so
    connections without `"library.v1"` do not receive duplicate `state` frames when only
    local-audio queue metadata changes (explicit `requestState` always replies).

### 3.2. State additions (`PlayerState` and `MusicState`)

- `PlayerState.library: RemoteLibraryState?` — `nil` identifies a Mac without library support.
  `{ revision: UUID, progressRevision: UUID, folders: Int, videos: Int, series: Int, albums: Int,
  tracks: Int, scanning: Bool }` (all counts `0...1_000_000`; `folders` is `watched_folders` count
  for `R18 · 09` State 4; `videos` is top-level video catalog count = movies + series, matching
  `R18 · 01`; `series` is series count; `albums` is album count; `tracks` is `audioTracks` count).
  - `revision` changes only when indexed files, watched folders (`displayName` / `isOffline`),
    `offlinePaths`, or `metadata` (including `posterPath`) change — **never** on intermediate
    32-file `FolderScanState.scanning(count)` progress updates (`scanning` only triggers a
    `PlayerState` update when the boolean flips `false <-> true`).
  - `progressRevision` changes when watch progress is recorded: coalesced via a one-shot
    cancellable `Task` to at most once per 10 s during active playback (no repeating idle timer),
    and immediately when an item becomes completed or playback pauses/stops.
- `PlayerState.sources: RemoteSources?` — what is currently loaded on the Mac regardless of which
  source is active, so Part B can choose between remote controls and library views per tab and
  render "Now on Mac" / "Paused on Mac" banners (`R18 · 01`):
  `{ video: RemoteSourceSummary?, localMusic: RemoteSourceSummary?, spotify: RemoteSourceSummary? }`,
  `RemoteSourceSummary { title: String, subtitle: String?, paused: Bool, artwork: String? }`.
  `title` and `subtitle` at most 2048 UTF-8 bytes; `artwork`, when non-nil, is an opaque
  `RemoteLibraryIDs` identifier (`validMusicID`) accepted by `requestArtwork` (`nil` for Spotify;
  supports both indexed items and ad-hoc `LocalAudioViewModel` tracks that have cached artwork).
- `MusicState.origin: RemoteMusicOrigin?` (`spotify | local`); `nil` means Spotify (older Macs).
- `RemoteMusicTrack.format: String?` (at most 64 UTF-8 bytes, e.g. `"FLAC · 24/96"` or `"MP3"`,
  formatted like `HomeLocalMusicView`); `nil` for Spotify tracks, populated for local audio so
  Part B renders the format badge in `R18 · 07` (`341:691`).

### 3.3. Library browsing and item details

`requestLibrary` → `library` (page):

```text
LibraryRequest {
  section: continueWatching | videos | series | albums | tracks | children
  parentId: String?                            // required iff section == .children (series or album id)
  videoKind: all | movies | series | unwatched // videos only, default .all
  sort: title | rating | recent                // optional, default .title (R18 · 01 also uses .rating)
  query: String?                               // ≤ 200 UTF-8 bytes; localized match like HomeFilterState.query
  offset: Int, revision: UUID?
}
LibraryPage {
  replyTo: UUID, revision: UUID, section: RemoteLibrarySection, parentId: String?,
  offset: Int, total: Int, nextOffset: Int?, items: [RemoteLibraryItem]
}
```

```text
RemoteLibraryItem {
  id: String                 // opaque, Command.validMusicID rule
  kind: movie | series | episode | album | track
  title: String              // ≤ 2048 UTF-8 bytes
  subtitle: String?          // ≤ 2048 UTF-8 bytes, e.g. "2024 · Science Fiction", "Yaima · Ambient"
  episodeLabel: String?      // ≤ 64 UTF-8 bytes, e.g. "S01E07" (unlocalized code; remote formats UI)
  season: Int?, episode: Int?, trackNumber: Int?
  year: Int?
  rating: Double?, ratingScale: Int?   // 10 for video (IMDb/TVMaze), 5 for audio; nil together when unrated
  genres: [String]           // ≤ 5 items, each ≤ 128 UTF-8 bytes
  badges: [String]           // ≤ 4 items, each ≤ 64 UTF-8 bytes, e.g. "4K HDR", "MKV", "FLAC 24-bit"
  duration: Double?          // seconds; for album, sum of known track durations (R18 · 06)
  progress: RemoteWatchProgress?   // { position: Double, duration: Double, completed: Bool }
  childCount: Int?           // episodes in a series, tracks in an album
  folderName: String?        // ≤ 512 UTF-8 bytes; watched folder displayName (for offline prompt R18 · 09)
  offline: Bool
  artwork: Bool              // true when an artwork cache key exists on the model (no disk stat on MainActor)
}
```

Section semantics, mirroring Mac Home:

| Section | Source on Mac | Notes |
|---|---|---|
| `continueWatching` | `continueWatching()` + available non-indexed `RecentFilesStore` videos with unfinished `WatchProgress` (`HomeOverviewView.swift:20–34`) | Movies in progress and the next episode of each series, sorted most-recently-updated first; filtered by `query` when present. |
| `videos` | movies plus one `series` item per `LocalSeriesGroup` (`videoCards` rule) | Filtered by `videoKind` and `query`; sorted by `sort` (`.title` default, `.rating`, `.recent`) like `filteredVideo`. A series item is `offline` only when all of its episodes are offline. |
| `series` | `series(in:)` | Series only, filtered by `query` and sorted by `sort`. |
| `albums` | `albums(in:)` | Albums with `childCount`, summed `duration`, format/lossless badge, `offline` when all tracks are offline; filtered by `query` and sorted by `sort`. |
| `tracks` | `filteredTracks` (`audioTracks`) | Used for music search; sorted by `sort` (album/disc/track order for `.title`). |
| `children` | episodes of a series (`(season, episode)` order) or album tracks (`(disc, track)` order) | Requires `parentId`; returns `.error(..., code: .itemNotFound)` for an unknown `parentId` or non-container item. |

`requestLibraryItem { id }` → `libraryItem { replyTo, revision, item, details }`:

```text
LibraryItemDetails {
  overview: String?              // ≤ 4096 UTF-8 bytes (MediaEnrichment.summary)
  ratingSource: String?          // ≤ 64 UTF-8 bytes, e.g. "IMDb", "TVMaze", "MusicBrainz" (R18 · 02)
  fileName: String?              // ≤ 1024 UTF-8 bytes, url.lastPathComponent only (never contains "/")
  folderName: String?            // ≤ 512 UTF-8 bytes, WatchedFolder.displayName only (never folder.path)
  audioLanguages: [String]       // ≤ 32 items, each ≤ 64 UTF-8 bytes
  subtitleLanguages: [String]    // ≤ 64 items, each ≤ 64 UTF-8 bytes
  seasons: [Int]                 // ≤ 200 sorted season numbers for series (R18 · 03), empty otherwise
  watchedCount: Int?             // completed episode count for series (R18 · 03)
  nextEpisodeId: String?         // opaque episode id of series next/restart target
}
```

Language lists come only from data Kinrox already has in memory without opening or probing the
media file (for example, `model.trackController.tracks` when the inspected item is currently loaded
in `PlayerViewModel`); otherwise return empty arrays (`[]`), hiding the Figma "Audio" row.

**Materialized index & paging:** `RemoteLibraryBridge` caches its grouped catalog and
`id <-> entity` lookup per `library.revision` so 2 Hz `PlayerState` snapshots read counts in
`O(1)` and `progressRevision` changes do not rebuild the 7,000-item catalog; `WatchProgress` is
read by path for the sliced page items. Pages contain at most 50 items and halve `count` until
`Codec.encode` fits `SecureChannel.maxPlaintextBytes` (`Codec.maxMessageBytes - 28`), matching
`RemoteMusicBridge.queuePage`. If `count == 1` still exceeds the limit after UTF-8 field
truncation, reply with `.error(replyTo:, code: .internal, message: ...)`. A non-nil `request.revision`
that differs from the current `library.revision` restarts at `offset = 0` (note: `progressRevision`
changes do **not** invalidate `library.revision` or reset page offsets).

### 3.4. Artwork

`requestArtwork { id, maxPixel }` (`maxPixel` in `64...360`) → `artwork { replyTo, id, jpeg: Data? }`.

- `RemoteLibraryBridge` resolves `id` on `@MainActor` (checking indexed movies, series, episodes,
  albums, tracks, and `localAudio.currentTrack` for ad-hoc audio) to an internal `<sha256>.jpg`
  key (`posterPath` / `artworkPath`). If unknown or uncached, reply immediately with `jpeg: nil`.
- Off the main actor, read raw bytes via `await artworkCache.thumbnail(key)` and downsample with
  ImageIO (`CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize = maxPixel`),
  stepping JPEG compression quality (`0.75`, `0.58`, `0.42`, `0.28`, `0.18`) — and halving pixel
  dimension once if still needed — until `jpeg.count <= 40_000` (Base64 ~53.3 KiB keeps the sealed
  frame well below `65,508` bytes). If encoding fails or still exceeds 40,000 bytes, return
  `jpeg: nil` so `SecureChannel.seal` never closes the connection; the remote shows its placeholder.
- Cache encoded remote thumbnails in an `NSCache` keyed internally by `"\(artworkKey)|\(maxPixel)"`
  (deduplicating shared series posters and album covers across episodes/tracks and automatically
  invalidating if `artworkKey` changes), capped at `totalCostLimit = 4 * 1024 * 1024` (4 MiB) and
  `countLimit = 200`. The `<sha256>.jpg` key never leaves the Mac.
- **Per-connection scheduling & outbox safety:** At most 4 concurrent artwork encodings and at most
  64 queued `requestArtwork` items per connection (if a connection exceeds 64 queued artwork
  requests, reply to the excess request with `artwork { replyTo, id, jpeg: nil }` or `.error`
  without disconnecting). Drain completed `artwork` replies onto the connection's `RemoteOutbox`
  with backpressure (waiting while `outbox.pendingCount >= 16` before enqueuing more artwork) so
  warm-cache bursts never trip `RemoteOutbox`'s 32-message disconnect guard. Cancel all queued and
  in-flight artwork tasks for a connection on `.disconnected` and `stopListening()`.

### 3.5. Local music as a music source

- Add `LocalAudioViewModel+Queue.swift` (keeping `LocalAudioViewModel.swift` ≤ 500 lines) with
  remote-exact mutations on `LocalAudioViewModel`:
  - `setShuffle(_ value: Bool)` (no-op when `queue.shuffled == value`, otherwise `queue.setShuffle(value, using: &random)` + `notify()`);
  - `setRepeat(_ mode: MusicRepeat)` (`queue.repeatMode = mode` + `notify()`);
  - `moveQueue(_ id: UUID, before target: UUID) -> Bool` (`queue.move(id, before: target)`, notifying on change);
  - `removeFromQueue(_ id: UUID) -> Bool` (`queue.remove(id)`, notifying on change);
  - static `formatBadge(for track: LocalAudioTrack) -> String` (e.g. `"FLAC · 24/96"` when `bitDepth` and `sampleRate` exist, else `track.format`, ≤ 64 UTF-8 bytes).
- `RemoteLocalMusicBridge` (`@MainActor`) observes `LocalAudioViewModel` (without filtering out
  inactive observations so `sources.localMusic` and `shutdownPlayback()` stay live), tracks
  `queueRevision` whenever `localAudio.queue` changes, maps every `MusicTrack` (including ad-hoc
  files opened outside watched folders) to `RemoteMusicTrack` using `RemoteLibraryIDs` (`t_<hex>`
  for `id`, `a_<hex>` for non-empty `albumKey` or `nil`, `year`, `format`), and builds:
  - `MusicState` with `liked: false`, `shuffle`, `repeatMode`, `queueCount`, `queueRevision`,
    `libraryRevision` (from `RemoteLibraryBridge`), `outputName: serverName`, `positionAge: 0`,
    `volumeKnown: true`, `origin: .local`, `similar: nil`, and `disallowedActions` containing
    `"like"`, `"similar"`, plus `"skipping_next"` / `"skipping_prev"` when unavailable and
    `"resuming"` / `"seeking"` / `"skipping_next"` / `"skipping_prev"` when `isScreensaverEngaged`
    blocks transport.
  - `queuePage(_ request: QueueRequest, replyTo: UUID) -> Message` with the same 20-item /
    halving frame-fit loop and stale-revision restart at `offset = 0` as `RemoteMusicBridge`.
- In `RemoteServer`:
  - When `activeLocalAudio != nil`, route `.requestQueue` to `localMusicBridge.queuePage(...)` and
    reply to `.requestLikeOptions` with `.error(..., code: .invalidPayload, message: ...)` (never
    forwarding to Spotify `musicBridge`).
  - Route `setShuffle`, `setRepeat`, `queueMove` (returning `.itemNotFound` when `moveQueue`
    returns `false`), `queueRemove` (returning `.itemNotFound` when `removeFromQueue` returns
    `false`), transport and volume commands to `LocalAudioViewModel`; reject Spotify-only commands
    (`setTrackLiked`, `setPlaylistMembership`, `setArtistFollowed`, `createPlaylist`, `setSimilar`,
    `setNotInterested`) with `.invalidPayload`.

### 3.6. Commands

- `playLibrary { itemId: String, from: RemotePlaybackStart (resume | start), shuffle: Bool? }`:
  - **Pre-flight availability check (before calling engines):**
    - Unknown `itemId` (or empty library / album with 0 tracks) → `.itemNotFound`.
    - Target movie, episode, or track has `isOffline == true`, or target series/album/`all-music`
      has items but every item is offline, or the item's `WatchedFolder` volume is no longer
      mounted → trigger `mediaLibrary.rescanAll()` if folder state changed and return `.unavailable`.
    - Folder is mounted, but `FileManager.default.fileExists(atPath: url.path) == false` (file was
      moved or deleted since the last scan, `R18 · 09` State 2) → trigger `mediaLibrary.rescanAll()`
      and return `.itemNotFound` (do **not** submit a doomed async `loadfile` to `mpv` and reply
      `ack`).
  - **Target resolution & playback:**
    - `movie` or `episode` (including non-indexed `continueWatching` items): `showPlayer()`, set
      `session.mode = .video`, never toggle fullscreen; `from == .resume` calls
      `model.resume(url, from: progress)`, `from == .start` calls `model.resume(url, from: nil)`
      (if the same URL is already loaded on `from == .start`, seek to `0` and unpause). Note that
      `model.resume` / `model.open` already stops Matrix screensaver and serializes via
      `PlaybackCoordinator` — **do not** wrap in a second `PlaybackCoordinator.start`.
    - `series`: choose `(from == .start ? group.episodes.first(where: { !$0.video.isOffline }) : (group.next ?? group.episodes.first))`; if nil return `.itemNotFound`, if `isOffline` return `.unavailable`; open as `episode` above (`from == .start` passes `nil` progress).
    - `album`: `showPlayer()` if `playerWindow == nil` (so `session.model` and `NowPlaying` exist)
      and set `session.mode = .video`; call `localAudio.play(album.tracks, at: 0, shuffled: shuffle == true)`
      (which already stops Matrix screensaver, pauses video/Spotify via `PlaybackCoordinator`, and
      switches the video view to Home).
    - `track`: `showPlayer()` if `playerWindow == nil` and set `session.mode = .video`; if the
      track belongs to an album in `MediaLibraryStore`, call
      `localAudio.play(album.tracks, at: indexInAlbum, shuffled: shuffle == true)`, otherwise
      `localAudio.play([track], at: 0, shuffled: false)`.
    - Reserved `itemId == "all-music"`: play all `mediaLibrary.audioTracks` with
      `shuffled: shuffle ?? true` (`R18 · 05` "Shuffle all").
- `resumeSource { source: RemoteControllableSource (video | localMusic | spotify) }`:
  - Resumes a loaded source (`R18 · 01` "Now on Mac" / "Paused on Mac"):
    - `video`: requires `model?.canControl == true` (else `.noMedia`); `showPlayer()`, set
      `session.mode = .video`, `model.stopScreensaver()`, `model.returnToVideo()`, and if
      `model.paused || model.isAtEnd`, call `model.setPaused(false)`.
    - `localMusic`: requires `localAudio.currentTrack != nil` (else `.noMedia`); `showPlayer()` if
      `playerWindow == nil`, `model?.stopScreensaver()`, and if `localAudio.paused`, call
      `localAudio.setPaused(false)`.
    - `spotify`: requires `music.currentTrack != nil && music.acceptsPlayback` (else `.noMedia`);
      `showPlayer()` if `playerWindow == nil` (preserving `session.mode` if already `.music`),
      `model?.stopScreensaver()`, and if `music.paused`, call `music.setPaused(false)`.
- `ProtocolError.Code.unavailable`: `RemoteServer+Commands.message(for: .unavailable)` returns the
  plain English wire string `"The drive with this file is not connected."` (not `L10n.text`).
  `ack` means command accepted; confirmed playback arrives on the next `state`.

### 3.7. Opaque identifiers

`RemoteLibraryIDs` derives deterministic opaque IDs as `<prefix>_<32 lowercase hex chars>` from
the first 16 bytes of `HMAC-SHA256(key, kind + "\u{1f}" + stableKey)`, where `stableKey` is the
canonical file path (`VideoFiles.key`), `seriesKey`, or `albumKey`, and `key` is a random 32-byte
secret generated once (Base64-stored in the injected `UserDefaults` under
`app.kinrox.player.remoteLibraryKey`, never hardcoded `UserDefaults.standard`). Prefixes: `m_`
(movie), `s_` (series), `e_` (episode), `a_` (album), `t_` (track), plus reserved `"all-music"`.
Ids never reveal paths, volume UUIDs, bookmarks, or `<sha256>.jpg` artwork filenames.

## 4. Implementation steps

1. **RemoteProtocol & RemoteTransport models and gates.**
   - Add `Packages/RemoteProtocol/Sources/RemoteProtocol/RemoteLibrary.swift` (`StateRequest`,
     `RemoteLibraryState`, `RemoteSources`, `RemoteSourceSummary`, `RemoteMusicOrigin`,
     `RemotePlaybackStart`, `RemoteControllableSource`, `RemoteLibrarySection`,
     `RemoteLibraryVideoKind`, `RemoteLibrarySort`, `LibraryRequest`, `LibraryPage`,
     `RemoteLibraryItem`, `RemoteWatchProgress`, `LibraryItemRequest`, `LibraryItemDetails`,
     `LibraryItemResponse`, `ArtworkRequest`, `ArtworkResponse`) and
     `Message+LibraryValidation.swift` (enforcing all UTF-8 byte caps, array bounds, finite
     non-negative numbers, `parentId` iff `section == .children`, `!fileName.contains("/")`, and
     `Command.validMusicID`; widen `Message.validPage` in `Message+MusicValidation.swift` to
     `internal`).
   - Update `MusicState.swift` (`MusicState.origin`, `RemoteMusicTrack.format`),
     `PlayerState.swift` (`library`, `sources`), `Command.swift` (`playLibrary`, `resumeSource` +
     `validate()`), `ProtocolError.swift` (`Code.unavailable`), and `Message.swift` (6 new
     `MessageType` / `Message` cases, `case requestState(Header, StateRequest)` + static
     `requestState(_ header: Header)` factory, calling `validateLibraryFields()` in both `init` and
     `encode`).
   - Update all four session/transport message switches: `Crypto/SessionFailure.swift`
     (`isApplicationMessage`), `Crypto/ServerHandshake.swift` (return `.notPaired` with
     `close: false` for pre-auth `requestLibrary`, `requestLibraryItem`, `requestArtwork`),
     `RemoteTransport/ServerSession.swift` (deliver `requestLibrary`, `requestLibraryItem`,
     `requestArtwork` to `onMessage`), and `RemoteTransport/TransportClient.swift` (deliver
     `library`, `libraryItem`, `artwork` to `onEvent`). Keep every file ≤ 500 lines.
2. **Protocol & transport tests and fixtures.**
   - Add golden v1 JSON fixtures in `Fixtures/v1/` and register them in `FixtureSamples` /
     `CodecFixtureTests` (covering all 6 new `MessageType` cases, `command-playLibrary.json`,
     `command-resumeSource.json`, `requestState` with `features`, and `PlayerState` with
     `library`/`sources` and `MusicState.origin`/`format` while keeping existing
     `Fixtures/v1/requestState.json` and `state*.json` byte-for-byte unchanged).
   - Add validation failure tests (oversized strings, multi-scalar UTF-8 overflow, bad IDs,
     `parentId` mismatch, inconsistent pages, too many genres/badges/features, `maxPixel` out of
     `64...360`, JPEG > 40,000 bytes, `fileName` containing `/`), encrypted frame test confirming
     40,000-byte JPEG `artwork` seals and opens within `SecureChannel.maxPlaintextBytes`, pre-auth
     `ServerHandshake` `.notPaired` tests, and `RemoteTransportTests` round-trip delivery of the
     new request/response messages over `TransportServer` + `TransportClient`.
3. **MediaLibraryStore observer hooks & Mac library bridge.**
   - Add lightweight catalog/scan vs progress observer registration on `MediaLibraryStore`
     (`MediaLibraryStore.swift`, `MediaLibraryStore+Enrichment.swift`) so `RemoteLibraryBridge`
     receives deterministic `@MainActor` notifications without polling timers or 32-file scan-count
     churn.
   - Add `PlayerMac/PlayerMac/Remote/RemoteLibraryBridge.swift` (`@MainActor`; `RemoteLibraryIDs`
     with injected `UserDefaults`, materialized catalog index per `library.revision`, sections
     including non-indexed `Continue Watching` items, `sort` and localized `query`, longest-prefix
     `WatchedFolder.displayName` lookup, `LibraryItemDetails`, UTF-8-safe truncation, frame-fitting
     paging, one-shot 10 s `progressRevision` coalescing) and
     `RemoteLibraryBridge+Artwork.swift` (ImageIO downsampling off `@MainActor`, 40,000-byte cap
     with quality/dimension fallback, `NSCache` keyed by `"\(artworkKey)|\(maxPixel)"` at 4 MiB /
     200 entries, 4-concurrent / 64-queued per-connection scheduler with outbox backpressure and
     disconnect cancellation). Reads only `MediaLibraryStore`, `RecentFilesStore`, and
     `LocalAudioViewModel` — zero new network requests.
4. **Local music bridge & queue helpers.**
   - Add `PlayerMac/PlayerMac/LocalAudio/LocalAudioViewModel+Queue.swift` (`setShuffle`,
     `setRepeat`, `moveQueue(_:before:)`, `removeFromQueue`, `formatBadge`) and
     `PlayerMac/PlayerMac/Remote/RemoteLocalMusicBridge.swift` (`MusicState` with `origin: .local`,
     opaque `t_`/`a_` IDs including ad-hoc files, `queuePage`, queue/shuffle/repeat command
     execution).
5. **Server routing & state projection.**
   - Update `RemoteStatePublisher.swift` (`positionOnly` via `var candidate = state; candidate.position = previous.position`) and `RemoteOutbox.swift` (expose `pendingCount` / capacity signal for artwork backpressure without removing the 32-message safety cap for stalled sockets).
   - Move library/local-music wiring and per-connection state projection into
     `PlayerMac/PlayerMac/Remote/RemoteServer+Library.swift` (keeping `RemoteServer.swift` well
     under 500 lines): per-connection `features` and `lastSentState`, `requestLibrary` /
     `requestLibraryItem` / `requestArtwork` handlers, `requestQueue` / `requestLikeOptions`
     routing when `activeLocalAudio != nil`, `sources` summary, legacy projection when
     `!features.contains("library.v1")`, and `playLibrary` / `resumeSource` closures. Add plain
     English `.unavailable` text in `RemoteServer+Commands.swift`.
6. **AppDelegate & PlayerSession wiring.**
   - Connect `mediaLibrary` and `RemoteLocalMusicBridge` in `PlayerSession` (fixing
     `localAudioObserver` so inactive pause/shutdown updates `sources.localMusic`).
   - Provide `playLibrary` and `resumeSource` closures in `AppDelegate` (and a testable session
     helper callable from `PlayerMacTests` without requiring GUI `applicationDidFinishLaunching`),
     implementing pre-flight reachability checks (`.unavailable` vs `.itemNotFound` + `rescanAll()`),
     `stopScreensaver()`, normal window (`showPlayer()`, never toggling fullscreen), and direct
     `model.resume` / `localAudio.play` / `setPaused(false)` calls without double-wrapping
     `PlaybackCoordinator`.
7. **Compile-only consumers.**
   - Keep `kinrox-cli` and `RemoteiOS` compiling cleanly with the new `Message` cases and
     `requestState` shape (`RemoteAppModel+Commands.swift` already ignores unknown inbound messages
     via `default: break`; `RemoteAppModel+Connection.swift` already handles unknown error codes
     via `default:`). Do **not** alter `RemoteiOS` runtime behavior, UI, or localization catalogs
     in Part A.
8. **Mac tests (`PlayerMacTests`).**
   - Bridge sections (`continueWatching` including ad-hoc recent with progress, `videos` with
     `videoKind` and `sort`, `series`, `albums`, `tracks`, `children`), search, offline items
     (`folderName` populated, `playLibrary` returns `.unavailable`), missing file on mounted folder
     (`playLibrary` returns `.itemNotFound` and triggers rescan), stale `library.revision` restart
     vs `progressRevision` stability, frame fitting with long multi-byte titles, ID stability across
     rebuilds, strict non-disclosure of filesystem paths / bookmarks / `<sha256>.jpg` keys across
     all encoded messages, per-connection projection (legacy connection without `library.v1` vs
     `library.v1` connection connected simultaneously, plus initial `.authenticated` state carrying
     `library != nil`), `RemoteStatePublisher` 2 Hz throttle preservation with non-nil
     `library`/`sources`, local `MusicState` (`origin == .local`, `format`, opaque IDs for indexed
     and ad-hoc tracks) and `requestQueue`/`queueMove`/`queueRemove`/`setShuffle`/`setRepeat`
     routing, `playLibrary` for movie (`resume` / `start`), series (`next` episode and all-watched
     restart fallback), album (`shuffle`), track (`queue == album` and standalone track),
     `all-music`, `resumeSource` across `video` / `localMusic` / `spotify` (including exiting
     Matrix screensaver), and concurrent warm/cold `requestArtwork` bursts (> 40 pipelined requests
     succeeding without tripping `RemoteOutbox` disconnect, ≤ 40,000-byte cap, missing artwork
     returning `jpeg: nil`, cancellation on disconnect).
9. **Documentation.**
   - `AGENTS.md` Section 6.3: document remote media library support as additive v1 (`requestState`
     feature declaration, `state.library` / `state.sources`, `MusicState.origin`, `RemoteMusicTrack.format`,
     browsing/item/artwork messages, `playLibrary` / `resumeSource`, `.unavailable`, legacy
     local-audio projection, zero paths/cache filenames on the wire).
   - `AGENTS.md` Section 3.5 table and page-ID list: add Figma page
     `18 · Remote — Медиатека на пульте` (`334:304`).
   - Record implementation and verification results in this document.

## 5. Verification

### 5.1. Automated gate (implementation agent runs; orchestrator re-runs)

Selected per `docs/runbooks/RUNBOOK-TASK-TESTS.md` and `AGENTS.md` Rule 11 (never boot or target
`iOS Simulator`):

```sh
./Scripts/check-env.sh
./Scripts/generate.sh
bash Scripts/make-test-media.sh
swift test --package-path Packages/KinroxMusic
swift test --package-path Packages/RemoteProtocol
xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData build test
# RemoteiOS compile check on device SDK only — never an iOS Simulator destination (AGENTS.md Rule 11):
xcodebuild -workspace Kinrox.xcworkspace -scheme RemoteiOS -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
python3 Scripts/check-localization.py
xcrun swift-format lint --strict --recursive PlayerMac RemoteiOS Packages Shared SharedTests
bash -n Scripts/check-env.sh Scripts/generate.sh Scripts/make-test-media.sh
find . \( -name '*.swift' -o -name '*.h' -o -name '*.sh' -o -name '*.yml' -o -name '*.xcconfig' \) \
  -not -path '*/.build/*' -not -path '*/DerivedData/*' -not -path '*/.tmp/*' \
  -not -path '*/Vendor/*' -not -path '*/dist/*' -not -path '*/build/*' \
  | xargs wc -l | awk '$1 > 500 && $2 != "total"'
```

Note on manual/device limits: `RemoteiOS` XCTest execution requires a cable-connected physical
iPhone (`AGENTS.md` Rule 11); in Part A `RemoteiOS` is compile-only, and full `RemoteiOS` device
verification accompanies Part B when the owner connects the iPhone.

### 5.2. Acceptance criteria

1. **Backward compatibility:** An existing Part A–unaware client (no `features: ["library.v1"]`)
   behaves identically to `main` against the new Mac over the real encrypted `RemoteTransport`,
   including active local audio projected as `source: .video, music: nil` and unchanged golden v1
   fixtures.
2. **Transport & scale:** Over an authenticated `TransportServer` + `TransportClient` session, a
   `library.v1` client receives valid `state.library` / `state.sources`, `library`, `libraryItem`,
   `artwork`, and local-audio `queue` responses that fit within `SecureChannel.maxPlaintextBytes`
   for a fixture library of at least 2,000 videos and 5,000 tracks, and survives a burst of ≥ 50
   pipelined warm/cold `requestArtwork` messages without disconnecting.
3. **Playback & coordinator invariants:** `playLibrary` and `resumeSource` start or resume the
   expected item/source, serialize cross-source pauses through `PlaybackCoordinator` without double
   audio, exit Matrix screensaver when active, open the normal window without toggling fullscreen,
   return `.unavailable` for offline items/drives, and return `.itemNotFound` (triggering rescan)
   when an indexed file is missing from a mounted folder.
4. **Privacy boundary:** No filesystem path, volume UUID, security bookmark, or `<sha256>.jpg`
   artwork cache filename appears anywhere in any encoded `Message` (asserted on raw JSON bytes).
5. **Code & localization hygiene:** Zero WebViews (`AGENTS.md` Rule 9); zero `mpv_*` types outside
   `MPVKit/`; Swift 6 strict concurrency compiles cleanly; `Scripts/check-localization.py` passes
   across all 30 locales; every repository source/header/script/YAML/xcconfig file is ≤ 500 lines.

### 5.3. Orchestrator measurements (orchestrator only, not the implementation agent)

Per `AGENTS.md` Section 11, the orchestrator runs all performance measurements itself in **Release**
configuration (`-configuration Release`), with Kinrox playback volume set to **`0` within Kinrox**
before loading any media (`AGENTS.md` Rule 7; Mac system volume untouched).

- **Session safety:** Check `pgrep -fl Kinrox` first. Never kill, overwrite, or steal Bonjour /
  `MPNowPlayingInfoCenter` / single-bundle activation from the owner's running
  `/Applications/Kinrox.app`. Run measurements inside an opt-in Release XCTest benchmark in
  `PlayerMacTests` (modeled on `HomeReleaseBenchmarkTests.swift`) using isolated `UserDefaults`,
  temporary SQLite/artwork directories, `FakeNowPlayingCenter`, and loopback-only
  `TransportServer.start(advertise: false, loopbackOnly: true)` + `TransportClient`, then run
  `./Scripts/unregister-dev-copies.sh`.
- **Comparable before/after measurements (`ri_phys_footprint` via `proc_pid_rusage`, RSS recorded
  separately, CPU % of one core, interrupt wakeups/s, p50/p95/max latencies, and `@MainActor`
  10 ms timer hitch gap on macOS 26.5.2; synthetic fixture library of ≥ 2,000 videos and ≥ 5,000
  tracks with network enrichment disabled):**
  1. **Idle with no remote connected:** Compare before (`main`) vs after physical footprint, RSS,
     CPU %, and interrupt wakeups/s over a steady-state window (verifying zero new background
     timers).
  2. **`requestLibrary` pagination:** Measure p50 / p95 / max round-trip latency over encrypted
     loopback for 50-item pages (`continueWatching`, `videos`, `albums`, `tracks` search) and max
     `@MainActor` tick gap (engineering design target: p95 ≤ 150 ms, `@MainActor` gap ≤ 50 ms).
  3. **Artwork throughput & memory return:** Measure 200 cold `requestArtwork` calls at 4 in flight
     (p50 / p95 / max latency, peak physical footprint delta during burst, and physical footprint
     after idle settle; engineering design targets: p95 ≤ 250 ms, peak delta ≤ 15 MiB, post-burst
     footprint within ~5 MiB of baseline + 4 MiB cache cap).
  4. **Remote start latency:** Measure `playLibrary` dispatch → confirmed `state` (`source` and
     `!paused`) over loopback at Kinrox `volume = 0` for local video and local audio.
- **Accepted limits & waivers (`AGENTS.md`):** Engineering targets above are diagnostic design
  goals, not newly invented owner acceptance gates. Standalone Spotify limits remain governed by
  `AGENTS.md` and `docs/runbooks/SOLOIST-VERIFICATION.md` (`Spotify.app` terminated; Soloist
  ≤ 120 MiB footprint, ≤ 3% CPU, ~21 wakeups/s short pause with 20 s parking; cold ≤ 4 s, warm
  ≤ 3 s, Next ≤ 3.2 s — if the owner's live `/Applications/Kinrox.app` + `Soloist` session is
  active, do not disrupt it; Part A does not modify `Music/` or `Soloist/`). Physical sleep/reboot
  checks remain waived (not passed), and no separate macOS 14 runtime test is requested.

## 6. Out of scope

RemoteiOS UI and localization strings (Part B), `kinrox-cli` subcommands beyond compile fixes,
Spotify catalog browsing on the remote, Lock Screen card changes, Mac UI changes, release, version
bump, commits.

## 6.1. Implementation results (2026-11-20)

- **Release status:** `not released` (implemented locally on `main`).
- **Plan item outcomes:**
  1. **RemoteProtocol & RemoteTransport models and gates — Completed.** Added
     `RemoteLibrary.swift` and `Message+LibraryValidation.swift`; updated `MusicState.swift`
     (`MusicState.origin`, `RemoteMusicTrack.format`), `Message+MusicValidation.swift`
     (widened `validPage` to `internal`, validated `format` ≤ 64 UTF-8 bytes),
     `PlayerState.swift` (`library`, `sources`), `Command.swift` (`playLibrary`, `resumeSource`),
     `ProtocolError.swift` (`unavailable`), `Message.swift` (6 new message types,
     `requestState(Header, StateRequest)` + static `requestState(_ header: Header)` factory,
     validation on decode and encode), and all four non-exhaustive switches
     (`Crypto/SessionFailure.swift`, `Crypto/ServerHandshake.swift`,
     `RemoteTransport/ServerSession.swift`, `RemoteTransport/TransportClient.swift`).
  2. **Protocol & transport tests and fixtures — Completed.** Added 10 golden v1 fixtures
     (`artwork.json`, `command-playLibrary.json`, `command-resumeSource.json`, `library.json`,
     `libraryItem.json`, `requestArtwork.json`, `requestLibrary.json`, `requestLibraryItem.json`,
     `requestState-features.json`, `state-library.json`), preserved existing v1 fixtures
     byte-for-byte, and added `LibraryFixtureSamples.swift`, `LibraryProtocolTests.swift`, and
     `LibraryTransportTests.swift`.
  3. **MediaLibraryStore observer hooks & Mac library bridge — Completed.** Added
     `LibraryChange` (`catalog`, `scanning(Bool)`, `progress(WatchProgress)`), `isScanning`, and
     observer registration to `MediaLibraryStore.swift` / `MediaLibraryStore+Enrichment.swift`
     (zero notifications on intermediate 32-file `updateScan` ticks), added `Equatable` on
     `WatchedFolder` / `MediaLibraryFile` / `MediaEnrichment` in `MediaLibraryModels.swift`,
     exposed `MediaFolderScanner.isAvailable(_:dependencies:)`, and implemented the library bridge
     split across `RemoteLibraryIDs.swift`, `RemoteLibraryBridge.swift`,
     `RemoteLibraryBridge+Index.swift`, `RemoteLibraryBridge+Browse.swift`, and
     `RemoteLibraryBridge+Artwork.swift` to stay well under the 500-line ceiling.
  4. **Local music bridge & queue helpers — Completed.** Added `track(for:)` and `mutateQueue(_:)`
     in `LocalAudioViewModel.swift`, explicit remote queue helpers and `formatBadge(for:)` in
     `LocalAudioViewModel+Queue.swift`, and `RemoteLocalMusicBridge.swift`.
  5. **Server routing & state projection — Completed.** Updated `RemoteStatePublisher.swift`
     (`positionOnly` via struct copy), `RemoteOutbox.swift` (`pendingCount` and `onDrained`
     backpressure while preserving the 32-message stalled-socket cap), `RemoteMusicBridge.swift`
     (`origin: .spotify`), `RemoteServer.swift`, `RemoteServer+Commands.swift` (plain English
     `.unavailable` wire text), and added `RemoteServer+Library.swift`.
  6. **AppDelegate & PlayerSession wiring — Completed.** Wired `connectLibrary(mediaLibrary)` and
     injectable test defaults (`initialLocalAudioVolume`, `localAudioEngineFactory`) in
     `PlayerSession.swift`, implemented `playRemoteLibrary` / `resumeRemoteSource` /
     `wireRemoteLibraryCommands` in `PlayerSession+RemoteLibrary.swift`, and wired them in
     `AppDelegate.swift`.
  7. **Compile-only consumers — Completed.** Added `.playLibrary, .resumeSource` to the no-op
     switch branch in `RemoteiOS/RemoteiOS/Demo/RemoteAppModel+Demo.swift` without changing
     `RemoteiOS` runtime behavior, UI, or localization catalogs; verified `kinrox-cli` and
     `RemoteiOS` compile cleanly.
  8. **Mac tests (`PlayerMacTests`) — Completed.** Added `RemoteLibraryBridgeTests.swift`,
     `RemoteLibrarySessionTests.swift`, and `RemoteLibraryArtworkTests.swift` covering sections,
     ad-hoc continue watching, sorting/filtering, longest-prefix folders, details/languages,
     progress coalescing, 2 Hz throttle preservation, 2,000-video + 5,000-track scale and
     multi-byte UTF-8 frame fitting, strict zero-path/bookmark/cache-key privacy, simultaneous
     legacy + `library.v1` projection, local queue/shuffle/repeat routing, `playLibrary` /
     `resumeSource` / Matrix exit / pre-flight offline & missing-file rescan, and 55+ pipelined
     warm/cold artwork bursts + ad-hoc cover resolution + disconnect cancellation.
  9. **Documentation — Completed.** Updated `AGENTS.md` Sections 3.5 (Figma page `18`, `334:304`)
     and 6.3 (additive v1 remote media library protocol specification), and archived this document
     in `docs/RESEARCHES/DONE/`.
- **Deviations (structural only, no scope expansion):**
  - Split `RemoteLibraryBridge` into `RemoteLibraryIDs.swift`, `RemoteLibraryBridge.swift`,
    `RemoteLibraryBridge+Index.swift`, `RemoteLibraryBridge+Browse.swift`, and
    `RemoteLibraryBridge+Artwork.swift`; placed session playback command helpers in
    `PlayerSession+RemoteLibrary.swift`; split artwork burst tests into
    `RemoteLibraryArtworkTests.swift` so every source and test file stays ≤ 500 lines.
  - Added defaulted `initialLocalAudioVolume` and `localAudioEngineFactory` parameters to
    `PlayerSession.init` so `RemoteLibrarySessionTests` exercises the real `PlayerSession`
    without real audio output.
- **Changed paths (Part A implementation only; pre-existing dirty files preserved untouched):**
  - *Modified:* `AGENTS.md` (Sections 3.5 & 6.3 only, preserving earlier working-tree edits),
    `Packages/RemoteProtocol/Sources/RemoteProtocol/Command.swift`,
    `Packages/RemoteProtocol/Sources/RemoteProtocol/Crypto/ServerHandshake.swift`,
    `Packages/RemoteProtocol/Sources/RemoteProtocol/Crypto/SessionFailure.swift`,
    `Packages/RemoteProtocol/Sources/RemoteProtocol/Message+MusicValidation.swift`,
    `Packages/RemoteProtocol/Sources/RemoteProtocol/Message.swift`,
    `Packages/RemoteProtocol/Sources/RemoteProtocol/MusicState.swift`,
    `Packages/RemoteProtocol/Sources/RemoteProtocol/PlayerState.swift`,
    `Packages/RemoteProtocol/Sources/RemoteProtocol/ProtocolError.swift`,
    `Packages/RemoteProtocol/Sources/RemoteTransport/ServerSession.swift`,
    `Packages/RemoteProtocol/Sources/RemoteTransport/TransportClient.swift`,
    `Packages/RemoteProtocol/Tests/RemoteProtocolTests/FixtureSamples.swift`,
    `PlayerMac/PlayerMac/App/AppDelegate.swift`,
    `PlayerMac/PlayerMac/App/PlayerSession.swift`,
    `PlayerMac/PlayerMac/LocalAudio/LocalAudioViewModel.swift`,
    `PlayerMac/PlayerMac/MediaLibrary/MediaFolderScanner.swift`,
    `PlayerMac/PlayerMac/MediaLibrary/MediaLibraryModels.swift`,
    `PlayerMac/PlayerMac/MediaLibrary/MediaLibraryStore+Enrichment.swift`,
    `PlayerMac/PlayerMac/MediaLibrary/MediaLibraryStore.swift`,
    `PlayerMac/PlayerMac/Remote/RemoteMusicBridge.swift`,
    `PlayerMac/PlayerMac/Remote/RemoteOutbox.swift`,
    `PlayerMac/PlayerMac/Remote/RemoteServer+Commands.swift`,
    `PlayerMac/PlayerMac/Remote/RemoteServer.swift`,
    `PlayerMac/PlayerMac/Remote/RemoteStatePublisher.swift`,
    `RemoteiOS/RemoteiOS/Demo/RemoteAppModel+Demo.swift`.
  - *Created:*
    `Packages/RemoteProtocol/Sources/RemoteProtocol/Message+LibraryValidation.swift`,
    `Packages/RemoteProtocol/Sources/RemoteProtocol/RemoteLibrary.swift`,
    `Packages/RemoteProtocol/Tests/RemoteProtocolTests/Fixtures/v1/{artwork,command-playLibrary,command-resumeSource,library,libraryItem,requestArtwork,requestLibrary,requestLibraryItem,requestState-features,state-library}.json`,
    `Packages/RemoteProtocol/Tests/RemoteProtocolTests/LibraryFixtureSamples.swift`,
    `Packages/RemoteProtocol/Tests/RemoteProtocolTests/LibraryProtocolTests.swift`,
    `Packages/RemoteProtocol/Tests/RemoteTransportTests/LibraryTransportTests.swift`,
    `PlayerMac/PlayerMac/App/PlayerSession+RemoteLibrary.swift`,
    `PlayerMac/PlayerMac/LocalAudio/LocalAudioViewModel+Queue.swift`,
    `PlayerMac/PlayerMac/Remote/RemoteLibraryBridge+Artwork.swift`,
    `PlayerMac/PlayerMac/Remote/RemoteLibraryBridge+Browse.swift`,
    `PlayerMac/PlayerMac/Remote/RemoteLibraryBridge+Index.swift`,
    `PlayerMac/PlayerMac/Remote/RemoteLibraryBridge.swift`,
    `PlayerMac/PlayerMac/Remote/RemoteLibraryIDs.swift`,
    `PlayerMac/PlayerMac/Remote/RemoteLocalMusicBridge.swift`,
    `PlayerMac/PlayerMac/Remote/RemoteServer+Library.swift`,
    `PlayerMac/PlayerMacTests/RemoteLibraryArtworkTests.swift`,
    `PlayerMac/PlayerMacTests/RemoteLibraryBridgeTests.swift`,
    `PlayerMac/PlayerMacTests/RemoteLibrarySessionTests.swift`.
  - *Pre-existing working-tree changes preserved untouched:* `.agents/skills/**`,
    `.agents/templates/investigate.md`, `docs/RESEARCHES/README.md`,
    `Packages/RemoteProtocol/Sources/RemoteTransport/WebSocketPeer.swift`,
    `Packages/RemoteProtocol/Tests/RemoteTransportTests/WebSocketPathRecoveryTests.swift`, and
    earlier `AGENTS.md` edits.
- **Verification commands and results:**
  - `./Scripts/check-env.sh`: passed (`All required tools are installed.`).
  - `./Scripts/generate.sh`: passed (regenerated `PlayerMac.xcodeproj` and `RemoteiOS.xcodeproj`).
  - `bash Scripts/make-test-media.sh`: passed (verified existing `h264.mp4`, `h264.mkv`, `hevc.mkv`, `tagged.mp3`).
  - `swift test --package-path Packages/KinroxMusic`: passed (`81 tests in 15 suites`).
  - `swift build --package-path Packages/RemoteProtocol` (incl. `kinrox-cli`) and `swift test --package-path Packages/RemoteProtocol`: passed (`138 tests in 25 suites`).
  - `xcodebuild -workspace Kinrox.xcworkspace -scheme RemoteiOS -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build`: passed (`** BUILD SUCCEEDED **`; iOS Simulator not used).
  - `xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData build test`: passed (`418 tests in 77 suites`, `** TEST SUCCEEDED **`).
  - `python3 Scripts/check-localization.py`: passed (`Verified 30 locales, 512 UI keys, permission prompts, and format arguments.`).
  - `xcrun swift-format lint --strict --recursive PlayerMac RemoteiOS Packages Shared SharedTests`: passed (0 errors).
  - `bash -n Scripts/check-env.sh Scripts/generate.sh Scripts/make-test-media.sh`: passed.
  - Line-count check (`≤ 500` across `PlayerMac`, `RemoteiOS`, `Packages`, `Shared`, `SharedTests`, `Config`, `Scripts`), zero `WKWebView`/`WebView`, and zero `mpv_*` outside `MPVKit/`: all passed.
- **Manual / environment limits and pending orchestrator measurements:**
  - `RemoteiOS` XCTest execution requires a cable-connected physical iPhone (`AGENTS.md` Rule 11); Part A verified `RemoteiOS` compile-only on `generic/platform=iOS`, and physical device testing accompanies Part B.
  - Physical sleep/reboot checks remain waived (not passed), and no separate macOS 14 runtime check was performed (`AGENTS.md` owner decision 2026-11-03).
  - Release performance measurements specified in Section 5.3 (`Orchestrator measurements`) are pending orchestrator execution per `AGENTS.md` Section 11 (not run by the implementation agent).

## 6.2. Orchestrator verification and measurements (2026-11-20)

- **Run:** `.tmp/scratch/research-execute/runs/2026-11-20_12-49-44-ZL1E6S`. The implementation
  agent finished its work at about 13:43 (+07) but its `agy` process never exited: it kept waiting
  for a "background task" while it had no child processes besides its MCP server, and no file
  changed for 8.5 hours. The orchestrator stopped it with `SIGTERM` at 22:18; the runner therefore
  recorded exit 12 ("incomplete"). The working tree, document, and checks show the plan completed.
- **Working tree:** only `AGENTS.md` (Sections 3.5 and 6.3) changed over a pre-existing edit; the
  other pre-existing edits (`.agents/**`, `WebSocketPeer.swift`, `WebSocketPathRecoveryTests.swift`,
  `docs/RESEARCHES/README.md`) are untouched. Existing v1 golden fixtures are byte-for-byte unchanged.
- **Orchestrator re-run of the automated gate (Debug):** `./Scripts/generate.sh`; `swift test
  --package-path Packages/RemoteProtocol` (138 tests in 25 suites passed); `swift test
  --package-path Packages/KinroxMusic` (81 tests in 15 suites passed); `PlayerMac` `build test`
  (418 tests in 77 suites passed); `RemoteiOS` `generic/platform=iOS` build with
  `CODE_SIGNING_ALLOWED=NO` (succeeded; no iOS Simulator); `swift-format lint --strict` (clean);
  `Scripts/check-localization.py` (30 locales passed); no project source over 500 lines; no
  WebView. The only compiler warnings are the pre-existing Homebrew `libmpv` deployment-target
  linker warnings.
- **Release build note:** the first Release attempt in the shared `DerivedData` failed in
  `RemoteTransport` because it resolved a stale `RemoteProtocol.swiftmodule` from 2026-11-12; a clean
  Release build in a separate derived-data directory succeeded. No code change was needed.
- **Measurement harness:** `PlayerMac/PlayerMacTests/RemoteLibraryReleaseBenchmarkTests.swift`,
  opt-in (`TEST_RUNNER_KINROX_REMOTE_LIBRARY_BENCH=1`, `TEST_RUNNER_KINROX_BENCH_MEDIA_DIR=<M1Media>`),
  run with `-configuration Release ENABLE_TESTABILITY=YES` on macOS 26.5.2 (arm64). Isolated
  `UserDefaults`, temporary library and artwork directories, `FakeNowPlayingCenter`, Kinrox volume 0
  for video and local audio (system volume untouched), enrichment disabled, a real encrypted
  `TransportServer`/`TransportClient` session declaring `library.v1`. Fixture: 2,001 videos (200 with
  distinct 480 px noisy posters, 34 in progress) and 5,001 tracks in 501 albums; real `h264.mp4` and
  `tagged.mp3` for `playLibrary`. The owner's `/Applications/Kinrox.app` and Soloist kept running
  and were not touched; `./Scripts/unregister-dev-copies.sh` ran afterwards. Raw JSON:
  `.tmp/scratch/research-execute/runs/2026-11-20_12-49-44-ZL1E6S/remote-library-bench.json`.

| Measurement | Result | Design target |
|---|---|---|
| Idle, no remote: server without library → with library (8 s windows) | CPU 0.28 % → 0.21 % of one core; interrupt wakeups 10.4 → 10.4/s | No new timers: **met** |
| Idle footprint added by `connectLibrary` (7,002-item library) | **+36.9 MiB** physical footprint (RSS +4.6 MiB) | "Unchanged": **not met** |
| `requestLibrary`, 50-item pages, 40 round trips each, p50 / p95 / max | `continueWatching` 5.8 / 9.6 / 9.7 ms; `videos` 5.1 / 10.6 / 11.7 ms; `videos` offset 1,000 4.8 / 9.7 / 9.9 ms; `albums` 6.4 / 11.1 / 12.1 ms; `tracks` search 20.8 / 22.0 / 26.5 ms | p95 ≤ 150 ms: **met** |
| Max `@MainActor` gap during library requests (10 ms timer) | 29.9 ms | ≤ 50 ms: **met** |
| Artwork, 200 cold requests at 4 in flight, p50 / p95 / max | 10.0 / 11.2 / 20.0 ms; 200/200 JPEGs, largest 28,454 bytes | p95 ≤ 250 ms: **met** |
| Artwork peak footprint delta during the burst | **+24.0 MiB** (previous run +25.7 MiB) | ≤ 15 MiB: **not met** |
| Footprint 60 s after the burst, versus before it | **+10.3 MiB** (previous run +13.3 MiB) | ≤ ~5 MiB + 4 MiB cache cap: **marginally not met** |
| `playLibrary` → confirmed `state` | local album cold 159 ms; video (pauses audio) 29.6 ms; local album after video 61 ms; video paused, never fullscreen | Diagnostic |

- **Interpretation:** latency, main-actor responsiveness, and idle CPU/wakeups are well within the
  targets. Memory exceeds two engineering targets. Code reading attributes the idle cost to
  `RemoteLibraryBridge.CatalogIndex`: it is built eagerly when the session connects the library,
  even with no iPhone connected, and stores full struct copies of each entry (`IndexedVideo` with
  `MediaLibraryFile` and `MediaEnrichment`, `IndexedTrack` with `LocalAudioTrack`, inline album and
  series payloads) in the arrays and again in both `byId` and `byPath` `Target` dictionaries. These
  are design goals, not `AGENTS.md` acceptance limits (Section 5.3); they need an owner decision or a
  follow-up optimization (for example building the index lazily for the first `library.v1`
  connection and releasing it when none remain, plus position-based lookup tables).
- **Update after the 0.5.12 release review (2026-11-20):** the owner accepted the memory results,
  and the general-release review then made the index lazy (built on the first remote connection,
  released after the last one) with handle-based lookup tables and a non-caching remote artwork
  read. Re-measured with the same harness in Release: idle footprint added by `connectLibrary`
  −0.03 MiB; artwork peak +11.8 MiB and +8.7 MiB after 60 s; `requestLibrary` p95 ≤ 21.8 ms;
  artwork p95 12.5 ms — all targets met.
- **Spotify standalone limits:** not re-measured. Part A does not change `Music/` or `Soloist/`
  (`RemoteMusicBridge` only adds `origin: .spotify`), and the owner's live Kinrox + Soloist session
  was left running; the accepted limits in `AGENTS.md` are unaffected by this change.
- **Not performed:** RemoteiOS device tests (compile-only in Part A; physical iPhone with Part B);
  physical sleep/reboot checks remain waived (not passed); no separate macOS 14 runtime check.
  Release status: not released.

## 7. Model log

### 2026-11-20 09:00:00 Europe/Moscow — Gemini 4 Carbon (High) — `plan_review`

- **Operation:** `plan_review`
- **Model:** Gemini 4 Carbon (High)
- **Completion time:** 2026-11-20 09:00:00 `Europe/Moscow`
- **Findings:**
  - **CRITICAL 1 (Channel, handshake, and transport switches drop all six new message types and close connections):**
    - *Locations:* `Packages/RemoteProtocol/Sources/RemoteProtocol/Crypto/SessionFailure.swift:54-62`; `Packages/RemoteProtocol/Sources/RemoteProtocol/Crypto/ServerHandshake.swift:96-102`; `Packages/RemoteProtocol/Sources/RemoteTransport/ServerSession.swift:46-51`; `Packages/RemoteProtocol/Sources/RemoteTransport/TransportClient.swift:94-99`; `Packages/RemoteProtocol/Tests/RemoteProtocolTests/SessionContractTests.swift:100-125`.
    - *Failure scenarios:* All four switches use non-exhaustive `default:` branches and were omitted from the plan's affected files and steps. Without updating them, `SecureChannel.seal`/`open` rejects `requestLibrary`, `library`, `requestLibraryItem`, `libraryItem`, `requestArtwork`, and `artwork` with `isApplicationMessage == false` (closing the channel with `.invalidPayload`), `ServerSession.receive` and `TransportClient.receive` hit `default: close(.invalidMessage)` and terminate the WebSocket on first library/artwork traffic, and `ServerHandshake.receive` fails pre-auth library requests with `.invalidPayload` (closing the socket) instead of returning recoverable `.notPaired`.
  - **CRITICAL 2 (`RemoteStatePublisher` 2 Hz throttle bypass, `RemoteOutbox` 32-message disconnect on cached artwork bursts, and initial pre-`requestState` capability flash):**
    - *Locations:* `PlayerMac/PlayerMac/Remote/RemoteStatePublisher.swift:28-37`; `PlayerMac/PlayerMac/Remote/RemoteOutbox.swift:18-25`; `PlayerMac/PlayerMac/Remote/RemoteServer.swift:297-311,338-340,352-376`; `PlayerMac/PlayerMacTests/RemoteServerTests.swift:195-201`; `PlayerMac/PlayerMacTests/LocalAudioPlaybackTests.swift:86-90`.
    - *Failure scenarios:* `RemoteStatePublisher.update` checks `positionOnly` by manually reconstructing `PlayerState` without `library` or `sources`, evaluating `positionOnly == false` on every `time-pos` tick once `library` is non-nil and broadcasting `state` unthrottled at 10–60 Hz. `RemoteOutbox.enqueue` disconnects the client at `messages.count >= 32`; > 32 pipelined `requestArtwork` hits from an in-memory cache synchronously overflow `RemoteOutbox` and drop the iPhone connection. Finally, `RemoteServer` sends `.state` on `.authenticated` before `requestState { features: ["library.v1"] }` can arrive; hiding `state.library` until `"library.v1"` is declared flashes the older-Mac warning (`R18 · 09` State 5) on every connect/reconnect and breaks Lock Screen sessions, whereas keeping `library`/`sources` whenever `libraryBridge != nil` and gating only active local-audio `source: .music` (`origin: .local`) projection on `"library.v1"` (plus per-connection `lastSentState` deduplication) preserves 100% `0.2.2` and existing-test compatibility.
  - **CRITICAL 3 (Local music bridge API mismatches, raw file-path IDs failing `validMusicID`, Spotify `requestQueue` misrouting, and inactive `localAudioObserver` blind spot):**
    - *Locations:* `PlayerMac/PlayerMac/LocalAudio/LocalAudioViewModel.swift:201-223,441-448`; `Packages/RemoteProtocol/Sources/RemoteProtocol/Command.swift:21-24,174-179`; `Packages/RemoteProtocol/Sources/RemoteProtocol/Message+MusicValidation.swift:42-48`; `PlayerMac/PlayerMac/Remote/RemoteServer.swift:239-250,330-336`.
    - *Failure scenarios:* `Command.queueMove` carries `beforeId: UUID` while `LocalAudioViewModel.move(_:by:)` takes an `Int` offset; `toggleShuffle()` and `cycleRepeat()` corrupt idempotent `setShuffle(_:)` / `setRepeat(_:)` commands; `remove(_:)` returns `Void` instead of `Bool` (preventing `.itemNotFound`); and `Command` has no `jump` case. `LocalAudioViewModel.queueTrack` puts POSIX file paths into `MusicTrack.id` and `\u{1f}` keys into `albumID`, which fail `Command.validMusicID` on `Codec.encode` (closing `SecureChannel`) unless mapped via `RemoteLibraryIDs` (`t_`/`a_`), including ad-hoc audio files outside watched folders. In `RemoteServer`, `.requestQueue` routed unconditionally to Spotify `musicBridge` even when `activeLocalAudio != nil`, and `localAudioObserver` guarded on `activeLocalAudio != nil`, missing background pause and `shutdownPlayback()` updates for `sources.localMusic`.
  - **CRITICAL 4 (`playLibrary` / `resumeSource` double-coordinator wrapping, Matrix screensaver rejection, missing-file false `ack`, and all-watched series failure):**
    - *Locations:* `PlayerMac/PlayerMac/Music/PlaybackCoordinator.swift:47-51,73-117,164-187`; `PlayerMac/PlayerMac/Player/PlayerViewModel.swift:117-130`; `PlayerMac/PlayerMac/Player/PlayerViewModel+Commands.swift:28-54`; `PlayerMac/PlayerMac/LocalAudio/LocalAudioViewModel.swift:78-125,241-254`; `PlayerMac/PlayerMac/Music/MusicViewModel+Playback.swift:97-116,378`; `PlayerMac/PlayerMac/MediaLibrary/MediaLibraryModels.swift:126-136`.
    - *Failure scenarios:* `PlayerViewModel.resume`/`open`/`setPaused(false)`, `LocalAudioViewModel.play`/`setPaused(false)`, and `MusicViewModel.setPaused(false)` already call `PlaybackCoordinator` internally; wrapping them in an outer `PlaybackCoordinator.start` invalidates the outer generation and double-pauses engines. `setPaused(false)` on video or local audio returns `false` (`.internal`) while `isScreensaverEngaged` is true unless `resumeSource` stops Matrix first. `mpv_command_async("loadfile")` accepts deleted/moved paths synchronously, returning `ack` instead of checking volume mount (`.unavailable`) and file existence (`.itemNotFound` + `rescanAll()`, `R18 · 09` State 2). For a completed series, `LocalSeriesGroup.next` is `nil`, failing `playLibrary` without an `episodes.first` fallback (`HomeVideoLibraryView.swift:104`).
  - **MAJOR 1 (Missing additive protocol fields required by Figma page `18`, `334:304`):**
    - *Locations:* Figma `334:304` (`341:691`, `337:432`, `338:458`, `338:523`, `341:611`, `342:696`, `342:708`); `MusicState.swift:7-31`; `HomeOverviewView.swift:20-34`; `MediaLibraryDatabase+Queries.swift:199-227`.
    - *Failure scenarios:* Part B (`RemoteiOS` UI) would require a second protocol change without: `RemoteMusicTrack.format` (`"FLAC · 24/96"` in `R18 · 07`), `RemoteLibraryItem.folderName` (`WatchedFolder.displayName` resolved by longest canonical folder prefix since `MediaLibraryFile` has no `folderId` in memory, needed for offline drive prompt in `R18 · 09` State 3) and summed album `duration` (`R18 · 06`), `LibraryRequest.sort` (`R18 · 01` rating sort), `LibraryItemDetails.ratingSource` / `seasons` / `watchedCount` (`R18 · 02` & `R18 · 03` for > 50-episode series), `RemoteLibraryState.folders` (`R18 · 09` State 4 empty-folders state), and non-indexed `RecentFilesStore` unfinished videos in `continueWatching`.
  - **MAJOR 2 (`MediaLibraryStore` observer absence, 32-file scan revision churn, and 7,000-item `@MainActor` rebuild cost):**
    - *Locations:* `PlayerMac/PlayerMac/MediaLibrary/MediaLibraryStore.swift:158-213`; `PlayerMac/PlayerMac/MediaLibrary/MediaLibraryStore+Enrichment.swift:79`; `PlayerMac/PlayerMac/MediaLibrary/MediaLibraryStore+Catalog.swift:4-71`.
    - *Failure scenarios:* `MediaLibraryStore` had no observer callbacks for `RemoteLibraryBridge`, `updateScan` mutates `states` every 32 files (which must not churn `library.revision`), and recomputing 7,000 HMAC IDs + groupings on every 2 Hz `PlayerState` tick or page request stalls `@MainActor`. Specified explicit catalog/scan vs progress callbacks, materialized index per `library.revision` with `O(pageSize)` progress overlay, and one-shot 10 s `progressRevision` coalescing (immediate on pause/completion).
  - **MAJOR 3 (Artwork thumbnail cache key deduplication/invalidation, ad-hoc audio artwork resolution, and hard 40,000-byte fallback):**
    - *Locations:* `PlayerMac/PlayerMac/MediaLibrary/ArtworkCache.swift:33-72`; `PlayerMac/PlayerMac/LocalAudio/LocalAudioViewModel.swift:405-439`; Plan Sections 3.2 & 3.4.
    - *Failure scenarios:* Keying `NSCache` by `(item.id, maxPixel)` duplicates series/album art across every episode/track and serves stale art when enrichment updates `posterPath`; keying internally by `"\(artworkKey)|\(maxPixel)"` deduplicates and auto-invalidates without exposing `<sha256>.jpg`. Added resolution for ad-hoc `localAudio.currentTrack` covers (`nil` for Spotify) and pixel-step fallback / `jpeg: nil` if quality reduction still exceeds 40,000 bytes.
  - **MAJOR 4 (`validPage` access control, `requestState` factory compatibility, UTF-8 byte truncation, and strict wire validation):**
    - *Locations:* `Packages/RemoteProtocol/Sources/RemoteProtocol/Message+MusicValidation.swift:49`; `Packages/RemoteProtocol/Sources/RemoteProtocol/Message.swift:131-188`; `PlayerMac/PlayerMac/Remote/RemoteMusicBridge.swift:287`.
    - *Failure scenarios:* `Message.validPage` was `private`; `String.prefix` counts `Character`s rather than UTF-8 bytes (risking `Codec.encode` failure on multi-scalar graphemes); and `Message+LibraryValidation` needed explicit `parentId` iff `section == .children`, `!fileName.contains("/")`, finite non-negative numeric checks, and `static func requestState(_ header: Header)` so existing callers and `Fixtures/v1/requestState.json` stay untouched.
  - **MINOR 1 (Trailing XML corruption in document, 500-line ceiling on 461-line `LocalAudioViewModel.swift`, `UserDefaults` injection, and localization script rules):**
    - *Locations:* `docs/RESEARCHES/2026-11-20_08-24_Remote-media-library-protocol-and-Mac.md:290-291`; `LocalAudioViewModel.swift` (461 lines); `RemoteServer+Commands.swift:79-85`; `Scripts/check-localization.py:41-48`.
    - *Failure scenarios:* Removed stray `</content>\n</invoke>` tags at the end of the document; split local queue helpers into `LocalAudioViewModel+Queue.swift` to stay ≤ 500 lines; required injected `UserDefaults` in `RemoteLibraryIDs` for test isolation; and clarified that `RemoteServer+Commands.message(for: .unavailable)` uses plain English wire text while `Scripts/check-localization.py` runs unconditionally.
  - **MINOR 2 (Verification gate commands and isolated Release measurement methodology):**
    - *Locations:* Plan Sections 5.1 & 5.3; `docs/runbooks/RUNBOOK-TASK-TESTS.md:23-45`; `AGENTS.md` Rules 7, 10, 11 & Section 11.
    - *Failure scenarios:* Added `./Scripts/check-env.sh`, `bash Scripts/make-test-media.sh`, `swift test --package-path Packages/KinroxMusic`, `.h`/`.xcconfig` and `.tmp/` exclusions to Section 5.1; reframed latency/memory numbers in Section 5.3 as non-blocking engineering targets alongside `AGENTS.md` accepted limits/waivers; and replaced `kinrox-cli` (currently a 4-line stub) with an isolated loopback Release XCTest harness that preserves the owner's running `/Applications/Kinrox.app`.
- **Changes made:** Corrected affected targets, `Status:` line, codebase facts (Section 2), protocol specification (Sections 3.1–3.7), implementation steps (Section 4), automated gate, acceptance criteria, and orchestrator measurement methodology (Section 5); removed trailing XML corruption; added this `plan_review` model log entry; renamed the document with the `REVIEWED - ` prefix.
- **Checks and results:**
  - Read-only inspection of `AGENTS.md` (`58,051` bytes), `docs/RESEARCHES/README.md`, `docs/runbooks/RUNBOOK-TASK-TESTS.md`, `docs/runbooks/RUNBOOK-BUILD-AND-SIGNING.md`, `docs/runbooks/SOLOIST-VERIFICATION.md`, Figma page `18 · Remote — Медиатека на пульте` (`334:304` XML structure, annotations, and `342:664` notes), and 40+ Swift/Python source, test, and project files across `Packages/RemoteProtocol`, `Packages/KinroxMusic`, `PlayerMac`, and `RemoteiOS`.
  - `python3 Scripts/check-localization.py`: passed (`Verified 30 locales, 512 UI keys, permission prompts, and format arguments.`).
  - Checked incoming links to `2026-11-20_08-24_Remote-media-library-protocol-and-Mac` across `docs/`, `AGENTS.md`, `README.md`, and `.agents/`: none present requiring update.
  - Checked running processes (`pgrep -fl Kinrox`): `/Applications/Kinrox.app` (`PID 5329`) and `Soloist` (`PID 89291`) are running in the owner's session and were left completely untouched.

### 2026-11-20 09:43:00 Europe/Moscow — Gemini 4 Neon (XHigh) — `implementation`

- **Operation:** `implementation`
- **Model:** Gemini 4 Neon (XHigh)
- **Completion time:** 2026-11-20 09:43:00 `Europe/Moscow`
- **Changes made:** Implemented Part A (additive v1 remote media library protocol, transport/channel/handshake gates, golden fixtures and protocol/transport tests, `MediaLibraryStore` observer hooks, `RemoteLibraryIDs`, `RemoteLibraryBridge` index/browsing/artwork pipeline with per-connection outbox backpressure, `LocalAudioViewModel+Queue`, `RemoteLocalMusicBridge`, per-connection state projection in `RemoteServer+Library`, `RemoteStatePublisher` throttle fix, `PlayerSession+RemoteLibrary` / `AppDelegate` wiring, `RemoteiOS` demo compile fix, `PlayerMacTests` suites, and `AGENTS.md` Sections 3.5 & 6.3 documentation). Preserved all pre-existing dirty working-tree files and left `/Applications/Kinrox.app` untouched. Moved this document to `docs/RESEARCHES/DONE/DONE - 2026-11-20_08-24_Remote-media-library-protocol-and-Mac.md`.
- **Checks and results:**
  - `./Scripts/check-env.sh`, `./Scripts/generate.sh`, `bash Scripts/make-test-media.sh`: passed.
  - `swift test --package-path Packages/KinroxMusic`: 81 tests in 15 suites passed.
  - `swift build --package-path Packages/RemoteProtocol` and `swift test --package-path Packages/RemoteProtocol`: 138 tests in 25 suites passed.
  - `xcodebuild ... -scheme RemoteiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`: `BUILD SUCCEEDED` (no iOS Simulator).
  - `xcodebuild ... -scheme PlayerMac -destination 'platform=macOS,arch=arm64' build test`: 418 tests in 77 suites passed (`TEST SUCCEEDED`).
  - `python3 Scripts/check-localization.py`, `xcrun swift-format lint --strict`, `bash -n`, 500-line ceiling, zero WebViews, zero `mpv_*` outside `MPVKit/`: all passed.
- **Pending:** Orchestrator Release performance measurements (Section 5.3) and physical iPhone RemoteiOS testing with Part B. Release status: `not released`.
