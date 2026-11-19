# Unified Home & Local Media Library (Video + Local Music on Mac)

- **Date:** 2026-11-18 19:30 (Europe/Moscow)
- **Figma Page:** `17 · Home — Медиатека (Видео + Локальная музыка)` (`node-id=319-304` in [Kinrox — Design](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox-%E2%80%94-Design?node-id=319-304))
  - Components (`319:320`): `Sidebar Nav Row` (`319:323`), `Folder Row` (`319:327`), `Filter Chip` (`319:333`), `Continue Card` (`319:336`), `Movie Poster Card` (`319:348`), `Local Album Card` (`319:358`), `Local Track Row` (`319:369`), `Local Audio Mini-Player` (`319:380`, including `QueueBtn` `319:405`)
  - Screen 01 (`321:305`): Unified Home overview (Continue Watching + Movies & Series + Local Music on Mac + docked Local Audio Mini-Player)
  - Screen 02 (`321:604`): Watched Folders & Auto-Scanning sheet (`321:696`) + 0-folder first-launch empty state (`321:765`)
  - Screen 03 (`323:536`): Movies & Series view with expanded Series detail drawer (`323:651`), episode strip, ratings, and genre filters
  - Screen 04 (`323:741`): Local Music on Mac view with local album grid, track table (genres, ratings, lossless badges), and mini-player
  - Notes (`323:1049`, `323:1056`): Folder scanning, offline volume retention, strict Spotify separation, and keyless open metadata privacy
- **Affected Targets:** `MetaBrainzAPI` (`Packages/KinroxMusic`), `PlayerMac` (`MPVKit`, `LocalAudio`, `MediaLibrary`, `Player/Home`, `App`, `Music`, `NowPlaying`, `Remote`), `PlayerMacTests`, `Resources/Localization` (30 locales), `AGENTS.md`, `NOTICE`
- **Out of Scope (Phase 1, per owner decision 2026-11-18):** New folder-browsing screens in `RemoteiOS` (deferred to Phase 2; existing LAN playback controls continue working), and `Website/` + `site/` static pages (updated only when a Mac release is published per `AGENTS.md` Section 3.6: *"Claims on the page must match shipped behavior"*).

Status: Implemented locally; not released.

---

## 1. Owner Decisions & Product Requirements (2026-11-18)

1. **Unified Home (`Главная`) replacing video-only `WelcomeView`:**
   - Top mode switcher changes from `Video | Spotify` to **`Home | Spotify`** (`Главная | Spotify`), cleanly separating **on-Mac local media** (both Video and Local Music) from **streaming Spotify**.
   - Local music on Home is **strictly local files** on the Mac or mounted volumes (`FLAC`, `ALAC`, `MP3`, `M4A`, `AAC`, `WAV`, `AIFF`, `OGG`, `OPUS`). Spotify catalog items never appear on Home.
   - Single-file ad-hoc playback (`Open File… ⌘O`, Finder "Open With", Dock/window drag-and-drop) remains instant and requires zero folder setup: opening or dropping a video file plays in `PlayerViewModel`; opening or dropping local audio files plays in `LocalAudioViewModel` on Home. `Info.plist` `CFBundleDocumentTypes` and `DefaultVideoPlayer` remain video-only (`MOV, MP4, M4V, MKV, WebM, AVI, TS`).
2. **Watched Folders & Automatic Background Scanning:**
   - Users add one or more folders (`~/Movies`, `/Volumes/...`, `~/Music/...`) via `+ Add` in the sidebar, the Folders sheet, or drag-and-drop of directories onto Home.
   - Kinrox recursively scans added folders in the background, monitors filesystem changes automatically via macOS `FSEvents` + `NSWorkspace.shared.notificationCenter` volume mount/unmount/wake notifications, and performs fast incremental `mtime + size` delta updates.
   - Disconnected external drives (`/Volumes/...`) mark the folder as offline (`Drive disconnected`) while preserving all indexed items, watch progress, ratings, genres, and cached artwork in SQLite until reconnected.
3. **Keyless Open Metadata, Ratings (`★`), Genres, Posters & Series Grouping (Owner Decision #1):**
   - **No API keys required.**
   - **Local Music:** Reads embedded audio tags and embedded artwork locally first (`ID3v2`, `MP4/iTunes` atoms, `FLAC/Ogg Vorbis/Opus` comments + `STREAMINFO` / `CMAudioFormatDescription` codec, bit-depth, and sample-rate + `METADATA_BLOCK_PICTURE`), then enriches missing ratings, genres, and cover art via Kinrox's existing `MetaBrainzAPI` (`MusicBrainz` release-group ratings & genres + `Cover Art Archive`, sharing a single `MusicBrainzRateLimiter` across the app).
   - **Movies & TV Series:** Parses filenames and parent folder hierarchy locally (`Season_01/s01e07_Episode.Seven.avi` -> series title, season 1, episode 7, resolution/HDR/codec badges) to group episodic series cleanly, then enriches ratings (`★`), genres, year, synopsis, episode titles, and posters via keyless open endpoints (`Cinemeta` public IMDb-backed catalog + `TVMaze` public CC-BY-SA fallback with `TVMaze` source attribution in UI pills and `NOTICE`).
   - **Privacy & Principle 4:** Metadata enrichment is controlled by an explicit toggle in both `LibraryFoldersSheet` (`321:761`) and `RemoteSettingsView` (`Load ratings, genres, and artwork`, persisted under `mediaLibrary.enrichMetadata`, on by default when folders are added, disclosed in UI and `AGENTS.md`). Requests use an ephemeral `URLSession` with no cookies, credentials, or user identifiers, send only normalized media titles / ISRCs / MBIDs, cache locally in SQLite + disk, and immediately cancel in-flight work and make zero network requests when turned off.
4. **Mac-First Scope (Owner Decision #2):**
   - Phase 1 ships the redesigned Home & Local Media Library on `PlayerMac`. `RemoteiOS` UI changes are deferred to a follow-up task, while existing Mac Now Playing media keys and paired iPhone playback transport commands remain functional across `.video`, `.localAudio`, and `.music`.

---

## 2. Verified Codebase & External API Evidence

### 2.1. Existing Codebase Integration Points

| Component | Path | Verified Behavior & Reuse |
|---|---|---|
| Window & mode chrome | `PlayerMac/PlayerMac/Player/PlayerRootView.swift`, `PlayerWindowController.swift`, `Music/UI/MusicView.swift` | Minimum content size in `.video` (`Home`) mode is `640×360` (`1024×768` in `.music`). Both `PlayerRootView` (`line 4, 22`) and `MusicTitleBar` (`MusicView.swift:93`) render `AppModePicker` and must share `PlayerRootView.modePickerWidth = 216` so switching modes never shifts or clips the centered picker. `PlayerRootViewTests` asserts `VideoHostView` stays mounted across `Esc` toggles and `TitlebarVideoNavButton` fits left of `AppModePicker` at `640 pt`. Titlebar right-hand controls on Home (`GlobalSearch` `321:322` + clickable `RemoteStatus` `321:326`) must adapt to `rightNavBudget` so `640 pt` never overflows. |
| Video playback, Home & Track panels | `PlayerMac/PlayerMac/Player/PlayerView.swift`, `PlayerViewModel.swift`, `PlayerViewModel+Commands.swift`, `App/TrackCommands.swift` | `model.isShowingHome` pauses the open video while preserving `currentURL`, `position`, and selected tracks. `MPVPlayer` runs with `keep-open=yes` (`MPVPlayer.swift:19`), so natural video completion emits `.property(.endReached, .flag(true))` (`PlayerViewModel.swift:257`) rather than `.ended`. `PlayerView.swift:45` hides `TrackPanelsOverlay` when `model.isShowingHome` is true, while `model.trackController.presentation != nil` disables `Esc` and controls; opening "Tracks & Subtitles" from Home (`323:672`) or the menu must first return to / load into the video view. |
| Existing Welcome features | `PlayerMac/PlayerMac/Player/Welcome/WelcomeView.swift`, `ContinueWatchingBanner.swift` | `WelcomeView` currently hosts Sparkle's `UpdateBanner` (`WelcomeView.swift:50-56`, `AGENTS.md` Section 2.1), clickable `Connect iPhone` entry (`WelcomeView.swift:91-95, 124`), and `ContinueWatchingBanner` for an open paused movie. All three must be preserved in `HomeWorkspaceView`, including when `0` watched folders are configured. |
| Cross-source serialization & window close | `PlayerMac/PlayerMac/Music/PlaybackCoordinator.swift`, `App/AppDelegate.swift` | Serializes transitions across sources and switches `NowPlayingController`. Extending `PlaybackCoordinator.Source` to `.video`, `.localAudio`, and `.music` must pause **both** other sources on start, route `.localAudio` errors to `LocalAudioViewModel`, and shut down `localAudio` alongside `music` in `beginClose()` (`PlaybackCoordinator.swift:124-141`) so closing the window (`⌘W`) or quitting (`⌘Q`) never leaves headless audio running. |
| Keyboard, menus, Now Playing & LAN Remote | `PlayerMac/PlayerMac/App/PlayerSession.swift`, `PlayerCommands.swift`, `NowPlaying/NowPlayingController.swift`, `Remote/RemoteServer.swift`, `RemoteServer+Commands.swift` | `PlayerCommands` binds unmodified `.space`, arrows, and `"f"` on the main menu; `PlayerSession` must disable unmodified menu shortcuts while Home's search `TextField` is focused or a library sheet is presented (`!isHomeSearchFocused && !isLibrarySheetShown`). `NowPlayingController.swift:104` currently omits artwork when `isMusic == true` and needs optional `artworkData` on `NowPlayingMetadata` for `.localAudio` covers. `RemoteServer` (`lines 332-348`) and `RemoteServer+Commands` must observe `localAudio` and publish/route `.localAudio` as standard `PlayerState` (`source: .video`, `music: nil`, `hasMedia: true`) so paired iPhones do not fail with `.noMedia`. |
| `MPVKit` boundary & C API | `PlayerMac/PlayerMac/MPVKit/MPVPlayer.swift`, `MPVEventLoop.swift`, `MPVEvent.swift`, `MPVLifetime.swift` | Per `AGENTS.md` Section 3.3, C types (`mpv_handle`, `mpv_event`) never escape `MPVKit/`. `MPVAudioEngine` must live in `PlayerMac/PlayerMac/MPVKit/` behind a Swift-only `@MainActor protocol LocalAudioEngine` in `LocalAudio/`, disable all 7 built-in LuaJIT scripts (`MPVPlayer.swift:26-29`), set `initialVolume` before `mpv_initialize`, and qualify `MPV_EVENT_END_FILE` by `MPV_END_FILE_REASON_EOF` + `playlist_entry_id` (`<mpv/client.h>:1461-1525`) so `loadfile ... replace` (`MPV_END_FILE_REASON_STOP`) never triggers spurious auto-advance. |
| SQLite store pattern | `PlayerMac/PlayerMac/Music/Spotify/Cache/SpotifyCacheDatabase.swift`, `SpotifyCacheStore.swift` | Thread-safe SQLite3 C-API wrapper (`WAL`, `busy_timeout=2000`, `synchronous=NORMAL`, `cache_size=-2000`, 100 MiB `max_page_count` cap). For `MediaLibraryDatabase`, set `PRAGMA mmap_size = 0` so mapped pages do not inflate Kinrox's physical footprint, isolate storage when `XCTestConfigurationFilePath != nil` (`PlayerSession.swift:43-45`), and support `KINROX_DATA_DIR` / `KINROX_CACHE_DIR` overrides for isolated orchestrator runs. |
| MetaBrainz client & rate limiter | `Packages/KinroxMusic/Sources/MetaBrainzAPI/MetaBrainzClient.swift`, `PlayerMac/Music/Spotify/SpotifyLibraryStore+MetaBrainz.swift` | `MetaBrainzClient` currently restricts hosts to `["musicbrainz.org", "labs.api.listenbrainz.org"]` (`line 197`), marks `request`/`read`/`cached`/`save` file-`private`, and blocks all HTTP redirects in `MetaBrainzRedirectPolicy` (`lines 250-258`). Cover Art Archive (`coverartarchive.org` -> `307` to `*.archive.org`) requires widening internal helpers, allowlisting `coverartarchive.org` with HTTPS-only redirect permission to `archive.org` / `*.archive.org`, escaping Lucene special characters, and sharing one `MusicBrainzRateLimiter` via `PlayerSession`. |
| Layout & localization gates | `PlayerMac/PlayerMacTests/WelcomeLayoutTests.swift`, `PlayerRootViewTests.swift`, `Scripts/check-localization.py` | Asserts zero horizontal scroll overflow across `[1120, 640, 1440, 1120]` widths; sidebar (`248 pt`) collapses below `920 pt`. `Scripts/check-localization.py` enforces exact key parity across 30 `.lproj` catalogs, single-line literal `L10n.text`/`L10n.format` keys, `%@`-only placeholders (rejecting any other `%` character), and zero unused keys. |

### 2.2. Live-Probed Keyless Open Metadata Endpoints (Verified 2026-11-18)

All endpoints below were probed live on 2026-11-18 with `User-Agent: Kinrox/0.6.0 ( https://kinrox.app )` and zero API keys or cookies:

| Domain / Endpoint | Auth / Rate Limit | Verified Live Response & Integration Constraints |
|---|---|---|
| `GET https://musicbrainz.org/ws/2/release-group/?query=releasegroup:"<album>" AND artist:"<artist>"&fmt=json&limit=3` | None; shared `1 req/s` (`MusicBrainzRateLimiter`) | `200 OK` — returns `release-groups[].id` (MBID), `title`, `artist-credit`, and `first-release-date`. Escape Lucene special characters (`\` and `"`) before quoting and verify normalized title/artist match. |
| `GET https://musicbrainz.org/ws/2/release-group/<mbid>?inc=ratings+genres&fmt=json` | None; shared `1 req/s` | `200 OK` — for `77d7c506-8d47-4d68-9615-f25db638bbea` (*Tomorrow's Harvest*): `rating.value = 4.35` (`0..5` scale), `genres = ["electronic", "ambient", "idm", "downtempo", "electronica"]`. |
| `GET https://coverartarchive.org/release-group/<mbid>` | None; redirects `307` to `archive.org` / `*.archive.org` | `200 OK` after HTTPS redirect — returns `images[0].thumbnails.large` (`-500.jpg`) and `small` (`-250.jpg`); upgrade `http://` URLs in JSON to `https://` and permit HTTPS `GET` redirects only to `archive.org` / `*.archive.org`. |
| `GET https://v3-cinemeta.strem.io/catalog/{movie\|series}/top/search=<query>.json` | None; `<= 2 req/s` client limiter | `200 OK` — returns `metas[]` with `imdb_id` (`tt15239678`, `tt3230854`), `name`, `releaseInfo`, `poster`. Percent-encode `<query>` strictly as a single path component (encoding `/`, `?`, `#`, `%`, spaces; rejecting `..`). |
| `GET https://v3-cinemeta.strem.io/meta/{movie\|series}/<imdb_id>.json` | None; `<= 2 req/s` client limiter | `200 OK` — returns `imdbRating` (`"8.4"`, `"8.5"`, `0..10` scale), `genre` (`["Drama", "Mystery", "Sci-Fi"]`), `year`, `runtime`, `description`, `cast`, `director`, `poster`, and for series `videos[]` (`season`, `episode`, `name`, `overview`). Validate `imdb_id` against `^tt[0-9]{5,12}$`. |
| `GET https://api.tvmaze.com/singlesearch/shows?q=<query>&embed=episodes` | None; CC-BY-SA, `20 req / 10 s` | `200 OK` — returns `rating.average` (`8.7`, `0..10` scale), `genres`, `premiered`, `summary` (strip basic `<p>`/`<b>`/`<i>` HTML tags cleanly into plain text), `image.medium` / `original`, and `_embedded.episodes[]`. Used as automatic fallback for TV series with `TVMaze` attribution. |

---

## 3. Architecture & Data Design

### 3.1. Module & Directory Layout (`<= 500` lines per file)

Every new and modified Swift file must stay strictly `<= 500` lines (`AGENTS.md` Rule 5). Split files proactively as follows:

1. **`Packages/KinroxMusic/Sources/MetaBrainzAPI/`:**
   - `MetaBrainzClient.swift` (updated): Widen `cached`, `save`, `read`, `request` to package-internal; update `MetaBrainzRedirectPolicy` to allow HTTPS `GET`/`HEAD` redirects strictly from `coverartarchive.org` to `archive.org` / `*.archive.org` while stripping extra headers and rejecting all other redirects.
   - `MetaBrainzReleaseLookup.swift` (new): Adds `resolveAlbum(album:artist:)` (`releaseGroupMBID: String?`, `rating: Double?`, `genres: [String]`, `year: String?`, `coverArtURL: URL?`) to `MetaBrainzClient` with Lucene query escaping, `MusicBrainzRateLimiter`, and `MetaBrainzCache`.
2. **`PlayerMac/PlayerMac/MPVKit/` (C-API boundary preserved):**
   - `MPVAudioEngine.swift` (new): `@MainActor` conformer to `LocalAudioEngine` wrapping a headless `mpv_handle` (`vo=null`, `vid=no`, `audio-display=no`, `keep-open=no`, `ytdl=no`, `config=no`, `osc=no`, `sub-auto=no`, `audio-file-auto=no`, `input-default-bindings=no`, `input-vo-keyboard=no`, `input-media-keys=no`, `volume-max=100`, all 7 `load-*` built-in LuaJIT script switches set to `"no"`, and `volume` initialized via `mpv_set_option_string` before `mpv_initialize`). Reuses `MPVPlayer.ensureNumericLocale()`, `MPVEventLoop`, and ordered background `mpv_terminate_destroy` teardown without an OpenGL context. Qualifies natural EOF via `MPV_END_FILE_REASON_EOF` + `playlist_entry_id` so `MPV_END_FILE_REASON_STOP` from `loadfile ... replace` or `stop` never emits natural-end events.
3. **`PlayerMac/PlayerMac/LocalAudio/` (pure Swift, zero `mpv_*` C types):**
   - `LocalAudioEngine.swift`: Defines `@MainActor protocol LocalAudioEngine: AnyObject`, `LocalAudioEvent: Sendable`, and `LocalAudioFiles` (`extensions`, `contentTypes`, `isAudio(_:)`).
   - `LocalAudioViewModel.swift`: `@MainActor @Observable` local audio player owning a `MusicCore.MusicQueue` of local tracks (`file://` paths remain local to Mac and never cross `RemoteProtocol`), shuffle/repeat, volume, `NowPlayingSource` conformance (including downsampled cover `artworkData`), `PlaybackCoordinator` integration, and serialized 20 s idle/paused engine parking with epoch tracking, saved-position restoration, and `initialVolume` preservation. Throttles `displayedPosition` updates to `4 Hz` (`0.25 s`) so SwiftUI views do not relayout at audio-frame rate.
4. **`PlayerMac/PlayerMac/MediaLibrary/` (new subsystem):**
   - `MediaLibraryModels.swift`: Domain types (`WatchedFolder`, `FolderScanState`, `LocalVideoItem`, `LocalSeriesGroup`, `LocalEpisodeItem`, `LocalAudioTrack`, `LocalAudioAlbum`, `WatchProgress`, `HomeSection`, `HomeFilterState`, `MediaRatingScale`).
   - `MediaLibraryDatabase.swift` & `MediaLibraryDatabase+Queries.swift`: Serial actor owning `<dataDir>/media-library.sqlite` (`~/Library/Application Support/Kinrox/media-library.sqlite` in production; `KINROX_DATA_DIR` override when set; isolated temp directory in XCTest). Configures `WAL`, `busy_timeout=2000`, `synchronous=NORMAL`, `mmap_size=0`, `cache_size=-2000`, and a 100 MiB `max_page_count` cap; handles schema migrations, parent/child folder overlap normalization, non-destructive offline volume flags, watch-progress persistence, and enrichment cache queries.
   - `MediaFolderWatcher.swift`: Recursive directory tree monitor using macOS `FSEventStream` (`CoreServices`) with balanced `FSEventStreamContext` `retain`/`release` callbacks and ordered serial-queue teardown (`FSEventStreamStop` -> `FSEventStreamInvalidate` -> `FSEventStreamRelease`), plus `NSWorkspace.shared.notificationCenter` observers (`didMountNotification`, `willUnmountNotification`, `didUnmountNotification`, `didWakeNotification`), `250–500 ms` burst coalescing, and injectable `Dependencies` for deterministic tests.
   - `MediaFolderScanner.swift`: Detached utility-priority recursive scanner skipping hidden files, bundles/packages, symlinks, and VobSub `.sub` sidecars; verifies directory reachability and matching `volume_uuid` before applying deletions; diffs `(canonicalPath, mtime, fileSize)` via `VideoFiles.key` against `MediaLibraryDatabase` in bounded batches so unchanged files are untouched.
   - `VideoTitleParser.swift`: Pure, deterministic filename + parent-directory parser extracting clean title, year, season/episode (`S01E07`, `1x07`, `Season_01/Episode 7`, `E07`, multi-episode `S01E01E02`), resolution (`4K`, `1080p`, `720p`), HDR (`HDR`, `DV`), container/codec badges (`MKV`, `MP4`, `AVI`, `HEVC`, `AV1`), and camera/screen-recording detection (`IMG_`, `DSC_`, `MVI_`, `Screen Recording`) to skip external movie lookups on personal clips.
   - `FLACOggTagParser.swift` & `LocalAudioTagReader.swift`: Offline metadata & artwork reader combining a streaming `FileHandle` binary parser for `FLAC` (`STREAMINFO` sampleRate/bitDepth/duration + `VORBIS_COMMENT` + `METADATA_BLOCK_PICTURE`) and `OGG/Opus` (`Vorbis`/`OpusTags` + last-64 KiB `granule_position` duration) — enforcing strict block size caps (`<= 16 MiB` picture, `<= 1 MiB` comments, max 64 header pages) — with bounded async `AVURLAsset` (`AVURLAssetPreferPreciseDurationAndTimingKey: false`, max concurrency `4`) `load(.commonMetadata)` / `load(.metadata)` / `loadTracks(withMediaType: .audio)` + `CMAudioFormatDescription` (`kAudioFormatAppleLossless` vs `kAudioFormatMPEG4AAC`, sample rate, bit depth) for `MP3`, `M4A/ALAC/AAC`, `WAV`, and `AIFF`. Deduplicates extracted cover bytes by SHA-256 into `<cacheDir>/MediaLibrary/Artwork/`.
   - `OpenVideoMetadataClient.swift`: Actor with ephemeral cookie-free `URLSession` (no redirects on JSON API calls), strict host allowlist (`v3-cinemeta.strem.io`, `api.tvmaze.com`), URL path-segment encoding, `^tt[0-9]{5,12}$` validation, `<= 2 req/s` rate limiting, plain-text HTML tag stripping for TVMaze summaries, and 7-day negative-result caching (`status = 'not_found'`).
   - `ArtworkCache.swift`: Bounded in-memory (`NSCache` count/cost cap) + disk thumbnail loader (`CGImageSourceCreateThumbnailAtIndex` capped at `480 px` max pixel size) and cookie-free remote artwork downloader allowlisting HTTPS hosts (`coverartarchive.org`, `archive.org`, `*.archive.org`, `images.metahub.space`, `static.tvmaze.com`, `m.media-amazon.com`) with `<= 10 MiB` payload limit and `CGImageSource` validation before disk write.
   - `MediaLibraryStore.swift` & `MediaLibraryStore+Enrichment.swift`: `@MainActor @Observable` coordinator binding database snapshots, folder watcher/scanner progress, lifetime-observed `UserDefaults` settings (`mediaLibrary.autoWatchFolders`, `mediaLibrary.enrichMetadata`) with immediate cancellation on opt-out, search/genre/rating/sort projections, and watch-progress updates.
5. **`PlayerMac/PlayerMac/Player/PlayerViewModel+WatchProgress.swift` (new extension, keeping `PlayerViewModel.swift` `<= 500` lines):**
   - Owns throttled watch-progress reporting (`5 s` interval, pause, `endReached`, `loadForPlayback` replacement, `closeVideo`, `shutdown`) and generation-scoped `pendingStartPosition` resume seeking.
6. **`PlayerMac/PlayerMac/Player/Home/` & Settings (SwiftUI views matching Figma `319:304`):**
   - `HomeWorkspaceView.swift`: Root unified Home view replacing `WelcomeView` inside `PlayerView`, responsive across `640 pt ... 2560 pt` (persistent `248 pt` `HomeSidebarView` at `>= 920 pt`; compact top navigation bar + popover folder button below `920 pt`), preserving Sparkle `UpdateBanner` and `ContinueWatchingBanner` for any open paused video.
   - `HomeSidebarView.swift`: Sections (`Overview`, `Movies & Series`, `Music on Mac`, `Recent`), catalog genre chips, `Folders` list with `+ Add`, live sync status card (`321:389`), and `Open File… ⌘O`.
   - `HomeOverviewView.swift`: Three distinct visual rows — `Continue Watching` (`16:9` cards), `Movies & Series` (`2:3` poster cards with `★` rating & format/season badges), and `Music on This Mac` (`LOCAL · FLAC / ALAC / MP3` badge + `1:1` square album cards).
   - `HomeVideoLibraryView.swift` & `SeriesDetailCard.swift`: Filtered video grid (`All`, `Movies`, `Series`, `Unwatched`, genre/rating chips, sort menu) + inline expandable `SeriesDetailCard` (`323:651`: poster, `★` rating with `IMDb`/`TVMaze` source pill, genres, synopsis, `▶ Continue SxxExx`, `Tracks & Subtitles`, `Show in Finder`, season picker, and horizontal episode strip).
   - `HomeLocalMusicView.swift` & `LocalTrackTable.swift`: Dedicated local music browser (`Play All`, `Shuffle`, genre & lossless filters, rating/album/recent sort, `1:1` album strip, and `LocalTrackTable` with `#`, `Title`, `Artist`, `Album · Year`, `Genres`, `Rating ★`, `Format`, `Duration`).
   - `LocalAudioMiniPlayerBar.swift` & `LocalAudioQueuePopover.swift`: `68 pt` Liquid Glass bottom bar (`319:380`) shown on Home whenever `LocalAudioViewModel` has an active track, with isolated `4 Hz` scrubber subview, rating badge, volume bar, and `Queue · N` popover (`319:405`) supporting upcoming inspection, jump, remove/reorder, shuffle, and repeat.
   - `LibraryFoldersSheet.swift`, `HomeEmptyStateView.swift`, & `MediaLibrarySettingsCard.swift`: Drag-and-drop folder management modal (`321:696`: `Check Now`, live scan progress bar, offline external drive badge, `FSEvents` auto-watch toggle, metadata enrichment toggle, remove folder), 0-folder first-launch hero (`321:765`), and matching settings card in `RemoteSettingsView`.

### 3.2. SQLite Schema (`media-library.sqlite`)

All filesystem paths stored in SQLite must be canonicalized with `VideoFiles.key(url)` (`standardizedFileURL.resolvingSymlinksInPath().path`). Ratings use media-appropriate normalized scales (`video`: `0.0...10.0`; `audio`: `0.0...5.0`, converting ID3 `POPM` `1...255` and Vorbis `0...100` into `0.0...5.0`).

- `watched_folders (id TEXT PRIMARY KEY, path TEXT UNIQUE NOT NULL, display_name TEXT NOT NULL, bookmark BLOB, volume_uuid TEXT, is_removable INTEGER NOT NULL DEFAULT 0, added_at REAL NOT NULL, last_scanned_at REAL, is_offline INTEGER NOT NULL DEFAULT 0)`
  - Adding an already-watched folder focuses it; adding a subfolder already covered by a watched ancestor is coalesced into that ancestor; adding a parent directory of existing watched subfolders migrates their `media_files.folder_id` in one transaction before removing the redundant child `watched_folders` rows.
- `media_files (id TEXT PRIMARY KEY, folder_id TEXT NOT NULL REFERENCES watched_folders(id) ON DELETE CASCADE, path TEXT UNIQUE NOT NULL, kind TEXT NOT NULL, file_size INTEGER NOT NULL, mtime REAL NOT NULL, added_at REAL NOT NULL, duration REAL, container_badge TEXT, codec_badge TEXT, resolution_badge TEXT, hdr_badge TEXT, parsed_title TEXT NOT NULL, parsed_year INTEGER, series_key TEXT, season_num INTEGER, episode_num INTEGER, artist TEXT, album TEXT, album_key TEXT, track_num INTEGER, disc_num INTEGER, sample_rate INTEGER, bit_depth INTEGER, is_lossless INTEGER NOT NULL DEFAULT 0, isrc TEXT, embedded_genres TEXT, embedded_rating REAL, artwork_path TEXT, metadata_key TEXT)`
  - Indexes on `(folder_id)`, `(kind, series_key, season_num, episode_num)`, `(kind, album_key, disc_num, track_num)`, and `(metadata_key)`.
- `enrichment_cache (metadata_key TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT, summary TEXT, rating REAL, rating_source TEXT, year_text TEXT, genres_json TEXT NOT NULL, poster_url TEXT, poster_path TEXT, episodes_json TEXT, fetched_at REAL NOT NULL, status TEXT NOT NULL)`
  - `status` values: `'ready'`, `'not_found'` (7-day TTL unless manually refreshed via `Check Now`).
- `playback_progress (path TEXT PRIMARY KEY, position REAL NOT NULL, duration REAL NOT NULL, completed INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL)`

### 3.3. Playback, Window, Keyboard, Now Playing & Remote Coordination Rules

1. **Mode Switcher & Titlebar (`AppModePicker`, `PlayerRootView`, `MusicTitleBar`):**
   - `PlayerRootView.modePickerWidth` becomes `216` in both `PlayerRootView` and `MusicTitleBar` (`MusicView.swift:93`); labels are `L10n.text("Home")` (with grid icon) and `"Spotify"`. `View` menu `⌘1` updates to `L10n.text("Home")`, and `⌘R` triggers `MediaLibraryStore.rescanAll()` in `.video` (`Home`) mode when `model.isShowingHome || !model.hasMedia`.
   - Clicking `Home` while watching a full-window video pauses the video and enters Home (`model.showHome()`); clicking `▶ Back to Video · 0:13` (`Esc`) returns to the paused video frame (`model.returnToVideo()`).
   - Titlebar layout in `.video` mode:
     - Leading (`leftNavBudget`): `TitlebarVideoNavButton` when `model.hasMedia && !model.isScreensaverEngaged`; `"Kinrox"` wordmark when `!model.hasMedia && leftNavBudget >= 60`.
     - Trailing (`rightNavBudget = max(0, (width - modePickerWidth) / 2 - 20)`), shown only on Home (`model.isShowingHome || !model.hasMedia`): wide (`>= 360 pt`) shows `GlobalSearch` (`⌘F`) + clickable `RemoteStatus` (`connectPhone`); medium (`160..<360 pt`) shows compact `GlobalSearch`; narrow (`< 160 pt`, including `640 pt` min width) shows a `30×30` search icon button (toggling an inline workspace search bar) + compact remote indicator so nothing overlaps `AppModePicker`.
2. **Three-Way `PlaybackCoordinator` (`Source: .video, .localAudio, .music`):**
   - Starting `.video` pauses both `.localAudio` and `.music` (Spotify).
   - Starting `.localAudio` pauses `.video` (preserving `currentURL` and keeping `isShowingHome = true` when a video is loaded so the paused video stays resumable) and pauses `.music`.
   - Starting `.music` (Spotify) pauses `.video` and `.localAudio`.
   - Errors thrown during `.localAudio` transitions set `localAudio.errorMessage` (never `video.errorMessage`).
   - `PlaybackCoordinator.beginClose()` (`PlaybackCoordinator.swift:124-141`) awaits **both** `music?.shutdownPlayback()` and `localAudio?.shutdownPlayback()` before releasing the retiring window, preventing background phantom audio after `⌘W` or `⌘Q`.
   - Engaging the Matrix screensaver (`PlayerViewModel.startMatrix`) also pauses `.localAudio` if active before activating Matrix.
3. **Keyboard Focus, Menu Shortcuts, Track Panels, Now Playing & `RemoteServer`:**
   - **Active playback target (`PlayerSession.activeControlTarget`):**
     - When `mode == .music` or (`playback.activeSource == .music` and neither full-window video nor active local audio overrides it): `.spotify`.
     - When `mode == .video` and `model?.hasMedia == true && model?.isShowingHome == false`: `.video` (full-window video always owns transport keys so pressing `Space` after `Back to Video` resumes the movie).
     - When on Home (`mode == .video` and `(model?.isShowingHome == true || model?.hasMedia != true)`) and `localAudio.currentTrack != nil` (with `playback.activeSource == .localAudio` or `model?.canControl != true`): `.localAudio`.
     - Otherwise, if `model?.canControl == true`: `.video`.
   - **Text-input & modal guards:** `PlayerSession` tracks `isHomeSearchFocused` and `isLibrarySheetShown`. While either is `true` (or `isOpenPanelShown`, `pairing.prompt != nil`, `trackController.presentation != nil`, `trackController.isChoosingFile`), unmodified menu shortcuts (`Space`, `←`/`→`, `↑`/`↓`, `"f"`) are disabled so typing `"f"`, spaces, and cursor arrows in `GlobalSearch` works normally; `Esc` clears/defocuses `GlobalSearch` or closes `LibraryFoldersSheet` before toggling `returnToVideo()`.
   - **Tracks & Subtitles from Home:** `TrackCommands` disables track menu items while `model?.isShowingHome == true` unless selecting `Audio & Subtitles` first calls `model?.returnToVideo()`. Clicking `Tracks & Subtitles` on `SeriesDetailCard` (`323:672`) returns to the video (or opens the selected episode paused in video view) before setting `trackController.presentation = .quick`, never setting `presentation != nil` while `isShowingHome == true`.
   - **`NowPlayingController`:** `NowPlayingMetadata` adds `var artworkData: Data? = nil`. Spotify (`.music`) leaves `artworkData = nil`; `.localAudio` supplies downsampled track/album artwork data (falling back to `KinroxLogo` when nil) so macOS Control Center displays local cover art.
   - **`RemoteServer` (`RemoteProtocol` v1 preserved):** `RemoteServer` observes `localAudio.observePlayback`. When `playback.activeSource == .localAudio` (or `localAudio.currentTrack != nil` while neither `.music` nor active `.video` owns playback), `RemoteServer.snapshot` publishes `PlayerState(title: localAudio.remoteTitle, position: localAudio.position, duration: localAudio.duration, paused: localAudio.paused, volume: localAudio.volume, fullscreen: model?.isFullscreen ?? false, hasMedia: localAudio.hasTrack, canNext: localAudio.canNext, canPrevious: localAudio.canPrevious, screensaver: model?.screensaver ?? .off, source: .video, music: nil)` and `RemoteServer+Commands` routes `.togglePause`, `.setPaused`, `.seekRelative`, `.seekAbsolute`, `.setVolume`, `.next`, and `.previous` to `localAudio`. No filesystem paths or `file://` URIs ever cross the network, and `RemoteiOS` transport + Lock Screen Live Activity work without protocol changes.
4. **Watch Progress Recording & Resume (`PlayerViewModel+WatchProgress.swift` -> `MediaLibraryStore`):**
   - `PlayerViewModel` flushes watch progress for `currentURL` (throttled to every `5 s` during playback, immediately on confirmed pause, immediately on `.property(.endReached, .flag(true))` **before** `advanceAfterEnd()`, and **before** `resetMedia()`/`clearCurrentFile()` in `loadForPlayback`, `closeVideo`, and `shutdown`).
   - Positions `< 5 s` are ignored while `completed == false` (and suppressed while `pendingStartPosition != nil`); positions `>= 92%` of duration (when `duration >= 60 s`) or `.endReached == true` mark `completed = true`, surfacing the next unwatched episode of a series in `Continue Watching`.
   - Resuming from `Continue Watching` or `SeriesDetailCard`:
     - If `model.hasMedia && VideoFiles.key(url) == model.currentURL.map(VideoFiles.key)`: calls `model.returnToVideo()` + `model.setPaused(false)`, preserving loaded tracks and buffered frames.
     - Otherwise: calls `model.open(url: url, startPosition: savedPosition)`, recording a generation-scoped `pendingStartPosition = (key: VideoFiles.key(url), seconds: savedPosition)` that issues `engine.seek(absolute:)` immediately upon `.loaded` when `currentURL` still matches `key`, and clears on manual seek, file change, or `resetMedia()`.

---

## 4. Implementation Steps

1. **`MetaBrainzAPI` Release-Group Ratings, Genres & Cover Art Redirects:**
   - Update `MetaBrainzClient.swift` (internal helpers + allowlisted HTTPS redirect policy for `coverartarchive.org` -> `archive.org` / `*.archive.org`) and add `MetaBrainzReleaseLookup.swift` (`resolveAlbum(album:artist:)` with Lucene escaping, `0..5` community rating, genres, year, and Cover Art Archive HTTPS thumbnail URLs).
   - Share a single `MusicBrainzRateLimiter` instance on `PlayerSession` across `SpotifyLibraryStore` and `MediaLibraryStore`.
   - Add unit tests in `MetaBrainzAPITests` covering release-group lookup, Lucene special-character escaping, `307` Cover Art Archive redirect allowlisting + rejection of untrusted redirect hosts, and shared rate-limiter serialization.
2. **Core `MediaLibrary` Storage, Parsers & Watchers:**
   - Implement `MediaLibraryModels.swift`, `VideoTitleParser.swift`, `FLACOggTagParser.swift`, `LocalAudioTagReader.swift`, `MediaLibraryDatabase.swift` + `MediaLibraryDatabase+Queries.swift`, `MediaFolderScanner.swift`, and `MediaFolderWatcher.swift`.
   - Implement `OpenVideoMetadataClient.swift` + `ArtworkCache.swift` (strict path-segment encoding, `^tt\d+$` check, host-allowlisted image redirects, downsampled `480 px` `CGImage` thumbnails, TVMaze HTML summary stripping, negative caching, and consent-toggle gate).
   - Implement `MediaLibraryStore.swift` + `MediaLibraryStore+Enrichment.swift` wiring incremental scan batches, non-destructive offline volume handling (`volume_uuid` verification), immediate cancellation when `mediaLibrary.enrichMetadata` is turned off, and watch-progress updates.
3. **Headless `MPVAudioEngine`, `LocalAudioViewModel` & 3-Way Coordinator Integration:**
   - Implement `MPVAudioEngine.swift` inside `PlayerMac/PlayerMac/MPVKit/` and `LocalAudioEngine.swift` + `LocalAudioViewModel.swift` inside `PlayerMac/PlayerMac/LocalAudio/`.
   - Extend `PlaybackCoordinator`, `PlayerSession`, `PlayerCommands`, `TrackCommands`, `NowPlayingSource`/`NowPlayingController`, `PlayerViewModel+WatchProgress.swift`, and `RemoteServer`/`RemoteServer+Commands` for 3-way `.video` / `.localAudio` / `.music` coordination without altering `RemoteProtocol` wire format.
4. **Unified Home SwiftUI Views, Settings, Documentation & Localization (Figma `319:304`):**
   - Build `HomeWorkspaceView`, `HomeSidebarView`, `HomeOverviewView`, `HomeVideoLibraryView`, `SeriesDetailCard`, `HomeLocalMusicView`, `LocalTrackTable`, `LocalAudioMiniPlayerBar`, `LocalAudioQueuePopover`, `LibraryFoldersSheet`, `HomeEmptyStateView`, and `MediaLibrarySettingsCard` (in `RemoteSettingsView`).
   - Update `PlayerRootView`, `MusicTitleBar` (`modePickerWidth = 216`), `PlayerView`, and `AppDelegate` (`Add Folder…` panel, directory drag-and-drop onto Home, ad-hoc video + local audio file open/drop, and `UpdateBanner` + `Connect iPhone` preservation).
   - Update `AGENTS.md` concisely (staying well under `65,536` bytes): Principle 4 & Section 9 Rule 8 keyless open metadata disclosure, Section 2.1 Home & Local Media Library features, Section 2.3 removal of `Playback position memory` from excluded items, Section 3.1/3.2 architecture layout, and Section 3.5 Figma page `17` (`319:304`) entry. Add `TVMaze` CC-BY-SA attribution note to `NOTICE`.
   - Localize all new UI strings across all **30 `.lproj/Localizable.strings` catalogs** (single-line literal keys, `%@`-only placeholders with no stray `%`, and removal of retired `WelcomeView`-only keys verified unused across `PlayerMac`, `RemoteiOS`, and `Shared`).
5. **Automated Regression & Unit Tests:**
   - `MetaBrainzAPITests`: release-group rating/genre/cover resolution, Lucene escaping, `307` redirect allowlist/rejection, and shared rate-limiter compliance.
   - `VideoTitleParserTests`: movies with years/4K/HDR tags, `Season_01/s01e07_Episode.Seven.avi`, multi-season grouping, camera clip detection (`IMG_4021.MOV`), and edge cases.
   - `LocalAudioTagReaderTests`: synthetic FLAC (`STREAMINFO` + `VORBIS_COMMENT` + oversized-block skip + `PICTURE`), Ogg/Opus tail `granule_position` duration, and async M4A (`ALAC` vs `AAC` format detection) / MP3 tag extraction.
   - `MediaLibraryDatabaseTests` & `MediaFolderScannerTests`: incremental rescan, rename/delete cleanup, overlapping parent/child folder normalization, offline external volume (`volume_uuid` mismatch / unmount) retention and remount recovery, watch-progress `endReached` completion before playlist auto-advance, and resume seeking without overwriting saved progress.
   - `OpenVideoMetadataClientTests`: `URLProtocol` fixtures for Cinemeta (including `/` and `?` in titles) + TVMaze fallback, negative caching, offline/malformed resilience, and immediate cancellation + zero-request verification when `mediaLibrary.enrichMetadata` is turned off.
   - `LocalAudioPlaybackTests`: `MPVAudioEngine` `MPV_END_FILE_REASON_STOP` vs `EOF` qualification (verifying manual `Next` never double-skips), post-20 s idle teardown resume preserving `volume = 0` and `savedPosition` without overlap, 3-way `PlaybackCoordinator` transitions + window-close (`beginClose`) teardown, `NowPlayingController` cover artwork routing, Home search `TextField` disabling unmodified `"f"`/`Space` menu shortcuts, `SeriesDetailCard` track panel transition without wedging `Esc`, and `RemoteServer` `.localAudio` state/command routing.
   - `WelcomeLayoutTests` & `PlayerRootViewTests`: updated for `HomeWorkspaceView`, `TitlebarVideoNavButton`, and `MusicTitleBar` (`modePickerWidth = 216`) across `[1120, 640, 1440, 1120]` widths (0 folders, 0 folders with open paused video, populated folders, active local audio mini-player), verifying zero horizontal overflow and `VideoHostView` preservation on `Esc`.

---

## 5. Verification, Acceptance Criteria & Orchestrator Measurements

### 5.1. Automated Build, Test, Localization & Lint Gate

Selected from `docs/runbooks/RUNBOOK-TASK-TESTS.md` (with `Packages/KinroxMusic` and `Scripts/check-localization.py` added; per `AGENTS.md` Rule 11, never launch the iOS Simulator):

```sh
./Scripts/check-env.sh
./Scripts/generate.sh
bash Scripts/make-test-media.sh
swift test --package-path Packages/KinroxMusic
swift test --package-path Packages/RemoteProtocol
xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData build test
python3 Scripts/check-localization.py
xcrun swift-format lint --strict --recursive PlayerMac RemoteiOS Packages Shared SharedTests
bash -n Scripts/check-env.sh Scripts/generate.sh Scripts/make-test-media.sh
find . \( -name '*.swift' -o -name '*.h' -o -name '*.sh' -o -name '*.yml' -o -name '*.xcconfig' \) \
  -not -path '*/.build/*' -not -path '*/DerivedData/*' -not -path '*/.tmp/*' \
  | xargs wc -l | awk '$1 > 500 && $2 != "total"'
```

### 5.2. Acceptance Criteria

1. **Architecture & Safety Boundaries:** Zero WebViews anywhere (`AGENTS.md` Rule 9); zero `mpv_*` C types outside `PlayerMac/PlayerMac/MPVKit/`; Swift 6 complete concurrency builds with zero warnings/errors; every source/config/script file `<= 500` lines; `AGENTS.md` `< 65,536` bytes.
2. **Unified Home & Responsive Layout:** `Home | Spotify` switcher aligned at `216 pt` in both modes; `HomeWorkspaceView` matches Figma `319:304` (`Overview`, `Movies & Series` with `SeriesDetailCard`, `Music on Mac` with `LocalTrackTable`, `Recent`, `LibraryFoldersSheet`, `HomeEmptyStateView`, `LocalAudioMiniPlayerBar` + `LocalAudioQueuePopover`), preserves `UpdateBanner` and `Connect iPhone`, and produces zero horizontal scroll overflow across `640 pt ... 2560 pt`.
3. **Folders, External Drives & Metadata Privacy:** Recursive `FSEvents` + `NSWorkspace` auto-scanning updates added/renamed/deleted files incrementally; unmounted external drives preserve cached entries, artwork, and progress (`is_offline = 1`); disabling `Load ratings, genres, and artwork` in either the Folders sheet or Settings cancels in-flight enrichment and sends zero network requests.
4. **3-Way Playback, Zero-Gain Safety & Remote Compatibility:** `.video`, `.localAudio`, and `.music` never produce simultaneous audio; window close (`⌘W`) shuts down headless local audio cleanly; post-20 s idle audio resume restores saved position and `volume` (`0` in tests) before audio output; Mac media keys, Control Center artwork, and paired `RemoteiOS` transport commands work for `.localAudio` without `RemoteProtocol` wire changes.
5. **Localization:** All 30 app locales pass `Scripts/check-localization.py` and `LocalizationTests` with zero missing, unused, or malformed format keys.

### 5.3. Orchestrator Measurements & Manual-Test Boundaries (Mandatory)

Per `AGENTS.md` Section 11 (owner decision 2026-11-12), the orchestrator performs all performance measurements itself in **Release** configuration (`-configuration Release`), setting Kinrox playback volume to **`0` within Kinrox** before loading media and **never modifying Mac system volume**.

- **Protecting the owner's running app and data:** Check `pgrep -fl Kinrox` first. Never overwrite, kill, or steal media keys from a running `/Applications/Kinrox.app`. Launch the built Release binary in an isolated instance using `KINROX_DATA_DIR` and `KINROX_CACHE_DIR` under `.tmp/` (`open -n` or direct isolated test/app harness). If `/Applications/Kinrox.app` is actively playing audio/video for the owner and GUI launch would contend with `MPNowPlayingInfoCenter` or single-bundle activation, record that boundary honestly and collect isolated XCTest/process measurements without interrupting the owner's session.
- **Comparable before/after measurements to record in this document:**
  1. **Baseline vs post-change startup & idle memory/CPU:** Record physical footprint (`footprint <pid>` / `proc_pid_rusage` `ri_phys_footprint`, alongside RSS separately), CPU % of one core, and interrupt wakeups/s on macOS 26.5.2 across (a) 0-folder Home idle baseline and (b) populated Home (`>= 200` mixed video & local audio fixture files with downsampled poster/cover thumbnails visible), comparing against Kinrox's pre-change Release idle baseline under stated session conditions.
  2. **Folder scan latency:** Record cold initial scan duration and warm incremental (`0`-change and `1`-file delta) rescan duration on the `>= 200`-file mixed fixture, confirming `@MainActor` remains responsive.
  3. **Local audio (`MPVAudioEngine`) latency, footprint, CPU & 20 s idle teardown:** At confirmed Kinrox volume `0`, measure local FLAC start latency, Pause/Resume/Seek/Next command latencies, steady playing physical footprint and CPU %, and paused -> 20 s idle engine teardown confirming `MPVAudioEngine` releases its `mpv_handle`/threads and subsequent Play restores `volume = 0` and saved position cleanly.
  4. **Cross-source transition:** Measure `.localAudio` -> `.video` (`MPVPlayer`) -> `Esc` (`Home`) -> `.localAudio`, confirming zero double-audio and preserved video frame/position.
- **Explicit boundaries (per `AGENTS.md`):** Do not invent arbitrary pass/fail thresholds outside `AGENTS.md`; do not launch the iOS Simulator (Rule 11); do not request a separate macOS 14 runtime test; preserve the owner's physical sleep/reboot waiver as a waiver (not a pass); standalone Spotify acceptance (`Spotify.app` terminated) remains governed by `docs/runbooks/SOLOIST-VERIFICATION.md` if Spotify regression checks are run.

---

## 6. Model Log

### 2026-11-18 20:09:36 Europe/Moscow — Gemini 4 Carbon (High) — `plan_review`

- **Operation:** `plan_review`
- **Model:** Gemini 4 Carbon (High)
- **Completion time:** 2026-11-18 20:09:36 `Europe/Moscow`
- **Findings:**
  - **CRITICAL 1 (`MPVKit` C-API boundary, `MPV_END_FILE_REASON_STOP` double-advance, and post-parking 100% volume leak / teardown race):**
    - *Locations:* `AGENTS.md:293,430-460`; `PlayerMac/PlayerMac/MPVKit/MPVPlayer.swift:9-33,59-65`; `PlayerMac/PlayerMac/MPVKit/MPVEvent.swift:43-50`; `PlayerMac/PlayerMac/MPVKit/MPVLifetime.swift:21-44`; `/opt/homebrew/include/mpv/client.h:1461-1525`.
    - *Failure scenarios:* Placing `MPVAudioEngine.swift` in `PlayerMac/PlayerMac/LocalAudio/` exposes `mpv_handle`/`mpv_event` outside `MPVKit/`. With `keep-open=no`, `loadfile ... replace` emits `MPV_EVENT_END_FILE` with `MPV_END_FILE_REASON_STOP`, which `MPVEvent.copy` currently collapses into `.ended(error: nil)` alongside `EOF`, causing manual `Next` or track clicks to double-skip. Recreating `mpv_handle` after the 20 s idle teardown without `mpv_set_option_string(handle, "volume", ...)` before `mpv_initialize` resets volume to `100` (violating `AGENTS.md` Rule 7 zero-gain playback) and can overlap async `mpv_terminate_destroy` without serialized epoch tracking; omitting the 7 built-in `load-*` LuaJIT disables (`MPVPlayer.swift:26-29`) also breaks Hardened Runtime.
  - **CRITICAL 2 (`MetaBrainzClient` Cover Art Archive host/redirect rejection, file-`private` helpers, and unshared `MusicBrainzRateLimiter`):**
    - *Locations:* `Packages/KinroxMusic/Sources/MetaBrainzAPI/MetaBrainzClient.swift:9-15,161-198,214-224,250-258`; `PlayerMac/PlayerMac/Music/Spotify/SpotifyLibraryStore+MetaBrainz.swift:14-21`.
    - *Failure scenarios:* `MetaBrainzClient.request` rejects `"coverartarchive.org"` (`Failure.invalidURL`), and `MetaBrainzRedirectPolicy` cancels all HTTP redirects (`completionHandler(nil)`), causing Cover Art Archive's mandatory `307` redirect to `*.archive.org` to fail 100% of the time with `Failure.unavailable`. `request`/`read`/`cached`/`save` are `private` so `MetaBrainzReleaseLookup.swift` could not call them; unescaped `"`/`\` in Lucene queries trigger HTTP `400`; and separate `MusicBrainzRateLimiter` instances in `SpotifyLibraryStore` and `MediaLibraryStore` would send `2 req/s` to `musicbrainz.org`, causing `503` rate-limit blocks.
  - **CRITICAL 3 (3-way `PlaybackCoordinator` window-close leak, `keep-open` video EOF completion miss, and resume-seek race):**
    - *Locations:* `PlayerMac/PlayerMac/Music/PlaybackCoordinator.swift:60-108,124-141`; `PlayerMac/PlayerMac/App/AppDelegate.swift:165-191`; `PlayerMac/PlayerMac/Player/PlayerViewModel.swift:121-142,193-210,257-262,360-372`; `PlayerMac/PlayerMac/Player/PlayerViewModel+Commands.swift:92-100`.
    - *Failure scenarios:* `PlaybackCoordinator.perform` only paused one counterpart source and misrouted non-`.music` errors to `video.errorMessage`, while `beginClose()` omitted `localAudio`, leaving headless audio playing after `⌘W` window close. Because `MPVPlayer` sets `keep-open=yes`, natural video EOF emits `.property(.endReached, .flag(true))` rather than `.ended`, so recording completion on `.ended` misses finished episodes before `advanceAfterEnd()` resets `position`/`duration` to `0`. Unconditionally calling `load(url:)` on `Continue Watching` reloads an already-open paused movie (losing selected tracks) or races file switches without generation-scoped `pendingStartPosition`.
  - **CRITICAL 4 (Unmodified menu shortcuts stealing `"f"`/`Space` from Home search, wedged `Esc` on Track panels from Home, and `.noMedia` failure on `RemoteServer` for `.localAudio`):**
    - *Locations:* `PlayerMac/PlayerMac/App/PlayerSession.swift:117-152`; `PlayerMac/PlayerMac/App/PlayerCommands.swift:65-163`; `PlayerMac/PlayerMac/App/TrackCommands.swift:19-30`; `PlayerMac/PlayerMac/Player/PlayerView.swift:45-49`; `PlayerMac/PlayerMac/Remote/RemoteServer.swift:332-348`; `PlayerMac/PlayerMac/Remote/RemoteServer+Commands.swift:19-55`; `PlayerMac/PlayerMac/NowPlaying/NowPlayingController.swift:104`.
    - *Failure scenarios:* In `.video` (`Home`) mode, `PlayerCommands` binds unmodified `"f"` (`Full Screen`), `.space`, and arrow keys, intercepting typing inside Home's `GlobalSearch` `TextField` unless gated on `!isHomeSearchFocused && !isLibrarySheetShown`; binary `controlsMusic` also routes `Space` on Home to a background paused movie instead of active `.localAudio`. Setting `trackController.presentation = .quick` from `SeriesDetailCard` (`323:672`) while `isShowingHome == true` hides `TrackPanelsOverlay` (`PlayerView.swift:45`) while disabling `Esc` and controls. `RemoteServer` ignores `localAudio`, reporting `hasMedia: false` and rejecting iPhone commands with `.noMedia`, and `NowPlayingController` suppresses artwork when `isMusic == true`.
  - **MAJOR 1 (External drive unmount wipe race, overlapping watched folders, SQLite `mmap` & test isolation):**
    - *Locations:* Plan Sections 3.1 & 3.2; `PlayerMac/PlayerMac/Music/Spotify/Cache/SpotifyCacheDatabase.swift:35`; `PlayerMac/PlayerMac/App/PlayerSession.swift:43-45`.
    - *Failure scenarios:* Unmounting `/Volumes/...` or hitting an empty mount-point stub before `NSWorkspace.didUnmountNotification` arrives causes `FSEvents` scans to delete cached rows unless `watched_folders` verifies `volume_uuid` and reachability first (observing `NSWorkspace.shared.notificationCenter`). Overlapping parent/child folders collide on `media_files.path UNIQUE` + `ON DELETE CASCADE`. `media_files` also lacked `is_lossless`, `sample_rate`, `bit_depth`, `codec_badge`, `resolution_badge`, and `hdr_badge`; `mmap_size` should be `0`; and XCTest runs must isolate storage from `~/Library/Application Support/Kinrox/`.
  - **MAJOR 2 (`LocalAudioTagReader` Swift 6 async `AVURLAsset`, `.m4a` ALAC-vs-AAC detection, Ogg duration, and streaming bounds):**
    - *Locations:* Plan Section 3.1 (`LocalAudioTagReader.swift`).
    - *Failure scenarios:* Synchronous `AVAsset` properties are deprecated in Swift 6; extension-only `.m4a` misclassifies AAC as lossless ALAC (requires `CMAudioFormatDescription` `kAudioFormatAppleLossless` check); macOS `AVFoundation` does not read `.ogg` Vorbis duration (requires tail-64 KiB `granule_position` scan); and un-capped `Data` reads spike memory on large 24/192 FLAC/WAV files.
  - **MAJOR 3 (`OpenVideoMetadataClient` URL path encoding, artwork redirect allowlist, live consent cancellation, and `0..10` vs `0..5` rating scales):**
    - *Locations:* Plan Sections 2.2, 3.1, 3.2; `PlayerMac/PlayerMac/Remote/RemoteSettingsView.swift:20`.
    - *Failure scenarios:* Unencoded `/` or `?` in Cinemeta `search=<query>.json` breaks URL paths; artwork CDNs redirect across `archive.org` / `m.media-amazon.com`; revoking enrichment in either `LibraryFoldersSheet` or `RemoteSettingsView` must immediately cancel active tasks; video (`0..10`) vs music (`0..5`) ratings require distinct normalization; and camera clips (`IMG_xxxx`) + `404`s need skipping/negative caching.
  - **MAJOR 4 (`MusicTitleBar` `modePickerWidth` mismatch, `640 pt` titlebar overflow, omitted `UpdateBanner`/`Connect iPhone`, drop/open handling, and `LocalAudioMiniPlayerBar` 60 Hz CPU & `Queue` popover):**
    - *Locations:* `PlayerMac/PlayerMac/Music/UI/MusicView.swift:73,93`; `PlayerMac/PlayerMac/Player/PlayerRootView.swift:4-56`; `PlayerMac/PlayerMac/Player/Welcome/WelcomeView.swift:50-66,91-95`; `PlayerMac/PlayerMac/Player/PlayerView.swift:93-102`; Figma `321:306`, `319:380`, `319:405`.
    - *Failure scenarios:* Leaving `MusicTitleBar`'s `AppModePicker` at `198 pt` while changing `PlayerRootView` to `216 pt` shifts the mode picker; fixed titlebar search + remote pills overflow at `640 pt`; replacing `WelcomeView` without `UpdateBanner`, `Connect iPhone`, and 0-folder paused-video banner regresses shipped features; `PlayerView` drop destination rejects folders and audio files; unthrottled `time-pos` observation causes 30–60 Hz Home grid layout; and `QueueBtn` (`319:405`) lacked `LocalAudioQueuePopover`.
  - **MAJOR 5 (`<= 500`-line file splits including 447-line `PlayerViewModel.swift`, `Scripts/check-localization.py` rules, `find` exclusions, and comparable Release measurements without interrupting `/Applications/Kinrox.app`):**
    - *Locations:* `PlayerMac/PlayerMac/Player/PlayerViewModel.swift` (447 lines); `Scripts/check-localization.py:35-48`; `docs/runbooks/RUNBOOK-TASK-TESTS.md:40-43`; `AGENTS.md:709-719`.
    - *Failure scenarios:* `PlayerViewModel.swift` (447 lines) and monolithic new files would breach 500 lines; unused `WelcomeView` localization keys or non-`%@` `%` characters fail `Scripts/check-localization.py`; `find` without `-not -path '*/.build/*'` scans SwiftPM build artifacts; and Section 5.2 invented unapproved numerical thresholds while risking collision with the currently running `/Applications/Kinrox.app` (PID observed via `pgrep`).
  - **MINOR 1 (`AGENTS.md`, `NOTICE`, and `Website/` boundaries):** Added `AGENTS.md` Section 2.3 (`Playback position memory` removal), Section 3.1/3.2, Section 9 Rule 8, `< 65,536`-byte cap, `NOTICE` CC-BY-SA `TVMaze` attribution, and explicit `Website/`/`site/` non-modification until release (`AGENTS.md` Section 3.6).
  - **MINOR 2 (`FSEventStream` Swift 6 lifecycle & test seam):** Specified balanced `FSEventStreamContext` `retain`/`release`, `Stop -> Invalidate -> Release` ordering, and injectable `Dependencies`.
  - **MINOR 3 (`View` menu `⌘1` & `⌘R` parity):** Updated `⌘1` label to `Home` and bound `⌘R` on Home to `MediaLibraryStore.rescanAll()`.
- **Changes made:** Updated header scope, Sections 1–5, file splits, SQLite schema, 3-way playback/keyboard/NowPlaying/Remote contracts, automated verification commands, acceptance criteria, and orchestrator measurement methodology directly in this document; set `Status: Plan review completed; awaiting implementation.`; renamed file with `REVIEWED - ` prefix.
- **Checks and results:**
  - Read-only verification of `AGENTS.md` (`56,333` bytes), `docs/RESEARCHES/README.md`, `docs/runbooks/RUNBOOK-TASK-TESTS.md`, `docs/runbooks/RUNBOOK-BUILD-AND-SIGNING.md`, `docs/runbooks/SOLOIST-VERIFICATION.md`, `/opt/homebrew/include/mpv/client.h` (`mpv_end_file_reason`), Figma `319:304` / `319:320` / `319:380` / `319:369` XML metadata, and 35+ Swift/Python source and test files.
  - `python3 Scripts/check-localization.py`: passed (`Verified 30 locales, 476 UI keys, permission prompts, and format arguments.`).
  - Checked incoming Markdown references across `docs/`, `AppStore/`, `Website/`, and root `*.md`: none found requiring update.
  - Checked running processes (`pgrep -fl Kinrox`): `/Applications/Kinrox.app` is running (`PID 6820`); left completely untouched.

### 2026-11-18 21:01:35 Europe/Moscow — gpt-6.2-sol — `implementation`

- **Operation:** `implementation`
- **Model:** gpt-6.2-sol
- **Completion time:** 2026-11-18 21:01:35 `Europe/Moscow`
- **Outcome:** Unified Home and the local media library implemented and verified on the Mac. Section 7 records checks and orchestrator measurements. Release status: not released.

### 2026-11-18 21:22:23 Europe/Moscow — Orchestrator — `orchestrator_verification`

- **Operation:** `orchestrator_verification`
- **Completion time:** 2026-11-18 21:22:23 `Europe/Moscow`
- **Outcome:** Verified architecture invariants, applied two targeted post-implementation fixes with regression coverage, and completed comparable Release (`-configuration Release`, Kinrox `volume = 0`) performance measurements against pre-change commit `30cf124` without disturbing the owner's running `/Applications/Kinrox.app` (`PID 6820`).
- **Fixes and additions:**
  - `PlayerMac/PlayerMac/MediaLibrary/VideoTitleParser.swift` & `PlayerMac/PlayerMacTests/MediaLibraryTests.swift`: Fixed series folder name fallback (`prefix.isEmpty && (seasonMatch != nil || root != seriesFolder)`) so adding a series folder directly as a watched root (e.g., `/Library/The Expanse/Season_01/s01e07_Episode.Seven.avi`) resolves series title `"The Expanse"` rather than the raw episode stem; added regression test coverage (`11` tests in `MediaLibraryTests` + `OpenVideoMetadataClientTests` passed).
  - `PlayerMac/PlayerMac/MediaLibrary/OpenVideoMetadataClient.swift` & `PlayerMac/PlayerMac/MediaLibrary/ArtworkCache.swift`: Replaced byte-by-byte `URLSession.AsyncBytes` iteration with buffered `session.data(from:)` plus `Content-Length` and post-read `maximumBytes` checks.
  - `PlayerMac/PlayerMacTests/HomeReleaseBenchmarkTests.swift`: Added opt-in (`KINROX_HOME_RELEASE_BENCH=1`) Release measurement suite covering empty Home idle, `240`->`241` mixed-fixture cold/warm scans + `@MainActor` responsiveness, populated Home idle, local FLAC playback/seek/next/pause/20 s parking/resume at `volume = 0`, and `.localAudio` -> `.video` -> `Home (Esc)` -> `.localAudio` transitions.

## 7. Local implementation and verification

Release status: not released.

| Plan item | Outcome and changed paths |
|---|---|
| 1. MusicBrainz and Cover Art Archive | `Packages/KinroxMusic/Sources/MetaBrainzAPI/` resolves matched release groups, rates them on the five-point scale, and caches ratings, genres, year and artwork URLs. Cover Art Archive redirects accept HTTPS GET/HEAD to Archive.org and strip incoming request headers. `PlayerSession` shares its MusicBrainz limiter with the Spotify store and the local library. |
| 2. Catalog, scanning and enrichment | `PlayerMac/PlayerMac/MediaLibrary/` owns the SQLite catalog, fresh volume checks, FSEvents and Workspace notifications, incremental scans, local video and audio parsing, open video metadata, and 480-pixel artwork. Parent folders absorb indexed children transactionally. An unreachable or different volume keeps its index, artwork and watch progress. Removable mounts without a stable UUID keep missing rows because a scan cannot verify that it examined the original drive. The shared consent switch cancels lookups and prevents new requests. |
| 3. Playback and resume | `PlayerMac/PlayerMac/MPVKit/` and `LocalAudio/` implement headless playback, occurrence-based queue, playlist-entry-qualified natural EOF, zero-gain initialization, and serialized pause parking. The app coordinator, Now Playing, menus and Mac server route video, local audio and Spotify. Video progress flushes at pause, replacement, completion and shutdown. Resume checks the loaded path before seeking. The existing LAN video state carries local audio transport controls and metadata titles. |
| 4. Home, Settings and documentation | `PlayerMac/PlayerMac/Player/Home/` replaces the welcome layout with Overview, Movies & Series, local music, recents, the watched-folders sheet and the audio bar and queue. The titlebars share a 216-point Home/Spotify switcher. The compact search icon and inline field apply below 720 points, including the 640-point minimum where the budget formula alone would select a text field. Update and iPhone connection entry points remain available. Open File and drop accept local audio and video, and Finder document associations remain video-only. The 30 catalogs in `Resources/Localization/`, `AGENTS.md`, `README.md` and `NOTICE` describe the new behavior and TVMaze attribution. |
| 5. Regressions | `Packages/KinroxMusic/Tests/MetaBrainzAPITests/` and `PlayerMac/PlayerMacTests/` cover provider responses, the shared limiter, consent cancellation, negative-cache reuse and manual retry, title and audio tags, folder overlap and offline recovery, watch-progress and track-panel transitions, native Next and EOF, parking and close, Now Playing cover and commands, server-side local-audio routing, and responsive Home layout. `SharedTests/LocalizationTests.swift` validates the shipped catalogs. `Scripts/make-test-media.sh` adds a silent tagged MP3 fixture beside the existing synthetic video fixtures. |

The pre-fix regression in `music-red.log` shows the artist lookup sending a broken
Lucene phrase for an artist containing both a quote and a backslash. The focused
MetaBrainz suite passed after escaping the phrase. The real libmpv local-audio
regression played silent WAV fixtures at Kinrox gain zero and observed one manual
Next transition followed by one natural EOF transition. Parking tests inject a
shorter clock interval while checking complete shutdown before replacement and
restoration of position and zero volume. The production interval is 20 seconds.

### Commands and results

Logs and rendered test images are retained in
`.tmp/scratch/research-execute/runs/2026-11-18_23-46-30-ye6I9G/`.

| Command | Result |
|---|---|
| `./Scripts/check-env.sh` | Passed. The environment check listed simulator runtimes as inventory. |
| `./Scripts/generate.sh` | Passed for both project files. |
| `bash Scripts/make-test-media.sh` | Passed. Reused the three existing videos and generated the silent tagged MP3. |
| `swift test --package-path Packages/KinroxMusic --filter artistLookupEscapesQuotedLuceneTerms` | Failed before the fix as expected. |
| `swift test --package-path Packages/KinroxMusic --filter MetaBrainz` | Passed after the fix, including release-group, allowlist and spacing coverage. |
| `swift test --package-path Packages/KinroxMusic` | Passed 79 tests in 15 suites. |
| `swift test --package-path Packages/RemoteProtocol --scratch-path "$run/protocol-build"` | Passed 130 tests in 23 suites, with `run` set to the run directory above. |
| `xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData build test` | Passed 402 tests in 73 suites. Xcode reported normal App Intents extraction skips and the documented Homebrew libmpv 26.0 linker warning. Swift compilation succeeded. |
| `xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData test -only-testing:PlayerMacTests/MediaLibraryTests -only-testing:PlayerMacTests/LocalAudioPlaybackTests -only-testing:PlayerMacTests/OpenVideoMetadataClientTests` | Passed 16 tests in 3 suites after canonical-path containment and lint corrections. |
| `xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData test -only-testing:PlayerMacTests/WelcomeLayoutTests -only-testing:PlayerMacTests/PlayerRootViewTests -only-testing:PlayerMacTests/LocalizationTests` | Passed 10 tests in 3 suites after the final visual adjustments. |
| `python3 Scripts/check-localization.py` | Passed 30 locales and 512 UI keys. |
| `xcrun swift-format lint --strict <60 changed Swift paths>` | Passed. Paths were selected using `git diff --name-only --diff-filter=ACM -- '*.swift'` and `git ls-files --others --exclude-standard -- '*.swift'`. |
| `for script in Scripts/check-env.sh Scripts/generate.sh Scripts/make-test-media.sh; do bash -n "$script" || exit; done` | Passed. |
| `git ls-files` and `git ls-files --others --exclude-standard`, then source line counts and `git diff --check` | Passed. The line ceiling applies to tracked and new repository sources, headers, scripts, YAML and xcconfig files. Previous build and release artifacts were excluded from the count. |
| `xcrun vtool -show-build DerivedData/Build/Products/Debug/Kinrox.app/Contents/MacOS/Kinrox` and `/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' DerivedData/Build/Products/Debug/Kinrox.app/Contents/Info.plist` | Both report macOS 14.0 minimum. Debug uses Homebrew libmpv. Portable release libraries remain a distribution concern. |

The installed Kinrox process was present during verification. AppKit-hosted
XCTest rendered the empty Home, populated Home, series drawer, music workspace
and Folders sheet using fixtures. Resize checks exercised 640, 1120, 1440 and
2560 points. The hosted tests verified Mac-side LAN state and commands, including
encrypted transport in the existing integration suites. A physical iPhone,
physical drive cycle and standalone Spotify session were outside the performed
checks. The owner’s sleep and reboot waiver remains in place. Runtime tests used macOS 26.5.2 (25F84). Project rules exclude a separate macOS 14 runtime check.

Earlier uncommitted edits to the two runner skills and the existing model-policy
lines in `AGENTS.md` were preserved. The worktree remains on `main`. The app
version, release files, website, iPhone sources and LAN protocol are unchanged.

### Orchestrator measurements

Completed on macOS `26.5.2 (25F84)` (`arm64`, Xcode `26.5`, Homebrew `libmpv 0.41.0`, `ENABLE_TESTABILITY=YES`, `-configuration Release`) inside an isolated AppKit-hosted XCTest process at a `1440×940` viewport with Kinrox playback volume set to `0` (`videoModel.setVolume(0)` and `localAudio.setVolume(0)`) before opening any media and Mac system volume untouched. Because `/Applications/Kinrox.app` (`PID 6820`) and `Soloist` (`PID 17744`) were actively running in the owner's session, running inside the isolated XCTest host (`FakeNowPlayingCenter`, isolated `UserDefaults` suite, temporary SQLite/artwork directories) avoided stealing `MPNowPlayingInfoCenter`, Bonjour, or single-bundle activation. Raw JSON outputs are retained at `.tmp/scratch/research-execute/runs/2026-11-18_23-46-30-ye6I9G/home-bench.json` and `baseline-bench.json`; temporary DerivedData bundles were unregistered from LaunchServices afterward via `./Scripts/unregister-dev-copies.sh`.

#### 1. Idle Memory, CPU & Wakeups — Pre-Change `30cf124` (`WelcomeView`) vs Post-Change Unified Home (`HomeWorkspaceView`)

Sampled via `proc_pid_rusage(..., RUSAGE_INFO_V4, ...)` (`ri_phys_footprint`, `ri_resident_size`, `ri_user_time + ri_system_time`, `ri_interrupt_wkups`) over 4-second steady-state windows after layout settle at `1440×940`. Note on displayed content: the pre-change populated baseline renders `WelcomeView` at its maximum 20 recent-file cards (`RecentFilesStore.limit = 20`) plus a `920×540` blurred decorative ellipse, whereas the post-change populated Home renders `HomeWorkspaceView` with `241` indexed media files (`81` movies, `40` series episodes, `120` tagged FLAC tracks across `20` albums) and cached downsampled artwork.

| Scenario (`1440×940`, Release, 4 s window) | Physical footprint | RSS | CPU (% of 1 core) | Interrupt wakeups / s |
|---|---:|---:|---:|---:|
| Pre-change `30cf124` — Empty `WelcomeView` (`0` recents) | `108.92 MiB` | `217.47 MiB` | `0.37%` | `10.81 / s` |
| Post-change — Empty Unified Home (`0` watched folders) | `95.38 MiB` | `208.78 MiB` | `0.25%` | `10.59 / s` |
| Pre-change `30cf124` — Populated `WelcomeView` (`20` recents cap) | `111.08 MiB` | `220.14 MiB` | `0.41%` | `10.49 / s` |
| Post-change — Populated Unified Home (`241` mixed files + cached artwork) | `106.16 MiB` | `218.41 MiB` | `0.26%` | `10.86 / s` |

#### 2. Watched-Folder Scan Latency & `@MainActor` Responsiveness (`MediaFolderScanner`, enrichment off)

Fixture: `80` movie `.mkv` files + `40` episodic series `.mkv` files (`Series/The Expanse/Season_01/s01e01..s01e40`) + `120` tagged `.flac` audio files across `20` albums (`2` silent 12 s PCM-encoded FLAC tracks + `118` Vorbis-comment + embedded PNG `METADATA_BLOCK_PICTURE` FLAC files), plus `+1` movie `.mkv` delta (`241` total indexed files). A `10 ms` repeating `@MainActor` timer measured main-thread responsiveness throughout the cold scan.

| Scan operation | Indexed files | Wall duration | Max `@MainActor` 10 ms tick interval |
|---|---:|---:|---:|
| Cold initial recursive scan + tag & embedded cover extraction | `240` | `82.47 ms` | `11.82 ms` |
| Warm 0-change incremental rescan (`mtime + size` fast path) | `240` | `132.93 ms` | — |
| Warm 1-file delta rescan (`+1` movie file added) | `241` | `46.65 ms` | — |

#### 3. Headless Local Audio (`MPVAudioEngine` + `LocalAudioViewModel`, Release, FLAC at `volume = 0`)

| Metric | Measured value |
|---|---:|
| Cold start latency (dispatch -> `!paused && !loading`, `volume = 0`) | `100.69 ms` |
| Seek latency (`seek(4.0)` -> engine position update) | `0.19 ms` |
| Manual `Next` track switch latency (dispatch -> track 2 active & playing) | `21.36 ms` |
| Pause latency (`setPaused(true)` -> confirmed paused) | `0.17 ms` |
| Warm resume latency (before 20 s parking) | `20.79 ms` |
| Post-20s-parking resume latency (recreates `MPVAudioEngine` at `volume = 0` & saved position) | `26.04 ms` |
| Restored playback state after `>20 s` parking teardown | `position = 5.46 s` (paused at `~5.45 s`), `volume = 0` |

| Local audio runtime window (Release, `volume = 0`) | Physical footprint | RSS | CPU (% of 1 core) | Interrupt wakeups / s |
|---|---:|---:|---:|---:|
| Sustained FLAC playback (`6 s` window, 4 Hz UI position throttle) | `111.31 MiB` | `229.16 MiB` | `3.00%` | `8.13 / s` |
| Short pause (`4 s` window, engine retained before 20 s timeout) | `111.38 MiB` | `229.23 MiB` | `0.57%` | `11.74 / s` |
| Parked idle after `>20 s` pause (`4 s` window after `MPVAudioEngine` teardown) | `86.52 MiB` | `207.61 MiB` | `0.23%` | `10.09 / s` |

#### 4. Cross-Source Transition (`.localAudio` -> `.video` -> `Home (Esc)` -> `.localAudio` at `volume = 0`)

| Transition / Invariant | Measured value |
|---|---:|
| `.localAudio` -> `.video` (`silent-video.mp4` open & play; `localAudio` auto-paused) | `26.49 ms` |
| `.video` -> `Home` (`Esc` / `showHome()`; video paused & frame retained) | `32.51 ms` |
| `Home` -> `.localAudio` resume (video stays paused on Home) | `21.46 ms` |
| Preserved video position across `.localAudio` resume | `0.58 s` |
| Simultaneous unpaused `.localAudio` + `.video` (`double_audio_observed`) | `false` |

Standalone Spotify acceptance (`Spotify.app` terminated) remains governed by `docs/runbooks/SOLOIST-VERIFICATION.md` (`Soloist` `PID 17744` was active in the owner's live `/Applications/Kinrox.app` session during this run and was not interrupted).
