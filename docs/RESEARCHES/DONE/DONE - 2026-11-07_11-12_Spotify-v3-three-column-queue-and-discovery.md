# Spotify v3 — Three-Column Navigation, Compact Queue & Discovery Engine

- **Date:** 2026-11-07 11:12
- **Status:** DONE
- **Figma Page:** `09 · Spotify — v3 · Навигация, Похожее и Очередь` (`node-id=166-304` in [Kinrox — Design](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U))
- **Affected Targets:** `MusicCore`, `SpotifyWebAPI`, `PlayerMac`, `PlayerMacTests`

---

## 1. Context & Problem Statement

In Music mode v2 (`08 · Music — Spotify`), the Mac screen used a three-column layout (`SourceColumn` | `AlbumColumn` | `TrackTable`), which introduced several functional and UX limitations reported by the owner:

1. **Mode naming:** The top mode tab was labeled `Music` instead of `Spotify`.
2. **Truncated playlists & missing drill-down in Left Column:**
   - `SpotifyLibraryStore.loadCollection("playlists")` filtered playlists with `.filter { $0.isEditable(by: library.userID) }`, hiding all followed/subscribed Spotify playlists and showing only user-owned or collaborative playlists.
   - `ensurePlaylistLoaded(_:)` rejected non-editable playlists with `SpotifyError.forbidden`, preventing read-only browsing of followed playlists.
   - Sections in the left column (`Playlists`, `Artists`, `Albums`) could not be expanded into a dedicated full-column view with search, ownership filters, and thematic tags.
3. **Middle Column rigidity:** The middle column always displayed `AlbumColumn`, even when the user selected a playlist, `Liked tracks`, or an artist in the left column, leaving less space for the active collection and requiring a separate full-screen switch to inspect the queue.
4. **Lack of persistent, compact Queue management:** The queue was hidden behind a source switch instead of living in the right column where tracks, whole albums, or playlists can be dropped and expanded at any position, reordered via drag-and-drop or up/down controls, or removed with one click (`×`).
5. **Music Discovery beyond Liked Songs:** Users needed a built-in way to discover similar tracks, underground cuts, fresh releases, and thematic playlists without being restricted to their existing likes, while respecting Spotify's February 2026 Development Mode Web API deprecations.

---

## 2. Research Findings

### 2.1. Root Cause of Missing Playlists in Left Column

- In `PlayerMac/PlayerMac/Music/Spotify/SpotifyLibraryStore+Loading.swift`:
  - `loadCollection("playlists")` appended `.filter { $0.isEditable(by: library.userID) }` at line 54.
  - Why it was originally written that way: `FavoritesPolicy` removes unliked tracks from editable playlists and `LikePopover` only offers editable playlists as targets.
  - However, `LibrarySnapshot` already provides a dedicated `editablePlaylists` computed property (`playlists.filter { $0.isEditable(by: userID) }`) used by `FavoritesPolicy`, `LikePopover`, `RemoteMusicBridge`, and `SpotifyLibraryStore.refresh()`.
  - Filtering `library.playlists` at ingestion time discarded every followed editorial, artist, and friend playlist.
  - Fix: Retain all non-excluded playlists in `library.playlists` during `loadCollection("playlists")`, track content availability (`MusicPlaylist.itemsAvailable` and `SpotifyLibraryStore.restrictedPlaylistIDs`) separately from metadata presence, and parameterize `ensurePlaylistLoaded(_ id: String, requireEditable: Bool = false)`. When Spotify's `/v1/playlists/{id}/items` endpoint returns `403 Forbidden` for a non-owned/non-collaborative subscribed playlist (`requireEditable: false`), the playlist metadata remains in `library.playlists` with `itemsAvailable = false` and the UI surfaces a clear localized notice (`"Spotify only provides tracks for playlists you own or collaborate on."`) with an `Open in Spotify` link, while mutations (`prepare(.membership)`, `prepare(.undo)`, `ensureEditablePlaylistsLoaded()`, `refresh()`) enforce `requireEditable: true`.

### 2.2. Spotify Web API Discovery Capabilities (Post-February 2026 Development Mode)

Following Spotify's 2025–2026 Development Mode restrictions:
- **Deprecated / Unavailable in Development Mode:** `GET /v1/recommendations`, `GET /v1/audio-features`, `GET /v1/artists/{id}/related-artists`, editorial featured endpoints, and `GET /v1/playlists/{id}/items` for playlists the user does not own or collaborate on.
- **Available & Verified in Development Mode:**
  1. **Playlist & Album Co-occurrence:**
     - `GET /v1/search?q=<artist+track>&type=album,playlist,track&limit=5` finds matching albums, playlists, and tracks.
     - `GET /v1/playlists/{id}/items` fetches neighbor tracks from readable (owned/collaborative) playlists and `GET /v1/albums/{id}/tracks` fetches neighbor tracks from matching albums (`MusicDiscoveryReasonKind.playlistCooccurrence`).
  2. **Artist Collaborations & Compilations Graph:**
     - `GET /v1/artists/{id}/albums?include_groups=album,single,appears_on,compilation` surfaces compilations, split releases, and guest appearances (`appears_on`, `compilation`), exposing labelmates and collaborators (`MusicDiscoveryReasonKind.compilation`).
  3. **Spotify Search Operators & Genre Taxonomy:**
     - `GET /v1/artists/{id}` provides `genres: [String]`.
     - `GET /v1/search` supports `genre:"..."` for tracks, and supports `tag:hipster` (lowest 10% popularity — underground/indie discovery, `MusicDiscoveryReasonKind.underground`) and `tag:new` (releases from the past two weeks, `MusicDiscoveryReasonKind.freshRelease`) for `type=album`, whose tracks are then loaded via `GET /v1/albums/{id}/tracks` and labeled only when confirmed from those album results.

---

## 3. Design & UX Architecture (Figma Page `09 · Spotify — v3`, `166:304`)

Five frames (`1440×900` + specification card) were designed and verified on Figma page `09 · Spotify — v3 · Навигация, Похожее и Очередь`:

1. **`09.1 · Главная: 3 колонки (Медиатека · Текущий выбор · Компактная очередь)` (`166:309`)**
   - Top segmented mode picker renamed from `Music` to **`Spotify`**.
   - **Left Column (`268 pt`):** `Library` (`Similar & discovery`, `Liked tracks`, `All albums` + `Show all  →`), `Playlists` (+ `Show all  →`), and `Artists` (+ `Show all  →`), with quick `+` queue buttons and drag sources.
   - **Middle Column (Flexible workspace):** Displays and manages whatever entity is selected in the left column (`TrackTable` with inline collection search, `Play all`, `Shuffle`, `+ Add to queue`, and `✦ Similar`).
   - **Right Column (`320 pt`, `CompactQueueColumn`):** Persistent compact queue with `Now Playing`, `Added manually` (`Clear manual`), and `From the source list`. Every upcoming row has a drag handle (`⋮⋮`), hover `↑`/`↓` step buttons, an always-visible `×` remove button, and `.dropDestination` accepting queue `UUID`s, `"track:<id>"`, `"album:<id>"`, or `"playlist:<id>"`.
2. **`09.2 · Левая колонка развёрнута: Все плейлисты (Show All + ‹ Назад)` (`166:475`)**
   - Clicking `Show all  →` expands the chosen entity (`Playlists`, `Artists`, or `Albums`) to fill the entire Left Column.
   - Top mobile-style **`‹ Back to library` (`‹ Назад в медиатеку`)** button (`Esc`), inline search field, ownership filter pills (`All | Mine | Subscribed`), and theme chips (`#Cosmic`, `#Harp`, `#Psybient`, `#Techno`).
3. **`09.3 · Средняя колонка: Все альбомы + Drag-and-Drop альбома в очередь` (`166:621`)**
   - Selecting `All albums` opens `AlbumsWorkspaceView` in the middle column with `Saved` / `All` filter pills, `By artist` / `By title` sort toggle, inline album search, and expandable album cards with `▶ Play`, `+ Add to queue`, `✦ Similar`, and inline track list expansion.
   - Dragging or adding an album/playlist to the queue expands all of its playable tracks at the target position.
4. **`09.4 · Поиск подобной музыки (Similar & Discovery Engine)` (`166:798`)**
   - Clicking `Similar & discovery` in the left column or any `✦ Similar` button in the deck, collection header, or album card opens `DiscoveryWorkspaceView` seeded by the chosen track, album, playlist, or artist.
   - Includes mode pills (`Same spirit` / `Underground` / `Fresh`), `Hide liked` toggle, genre chips, `Mixes & compilations` cards, and `Recommended tracks` with a `Why this track` badge explaining each recommendation.

---

## 4. Implementation Summary

- **`Packages/KinroxMusic/Sources/MusicCore/`:**
  - `MusicQueue.swift`: Added `add(_ tracks: [MusicTrack])`, `insert(_ tracks: [MusicTrack], before destination: UUID? = nil) -> [UUID]`, `clearManual()`, and `moveOffset(_ id: UUID, by delta: Int) -> Bool`.
  - `MusicDiscovery.swift`: Implemented `MusicDiscoveryMode`, `MusicDiscoveryReasonKind`, `MusicDiscoveryItem`, `MusicDiscoveryMix`, `MusicDiscoverySnapshot`, and `MusicDiscoveryEngine`.
  - `BrowserSelection.swift`: Added `MusicSource.similar` and wired it to `MusicDiscoveryEngine`.
- **`Packages/KinroxMusic/Sources/SpotifyWebAPI/`:**
  - `SpotifyModels.swift`: Added `SpotifyArtistDetails` (`genres`), null-safe item decoding in `SpotifyPage`, and `playlists` page decoding in `SpotifySearchResults`.
  - `SpotifyLibraryEndpoints.swift`: Added `artist(_ id: String)`, parameterized `artistAlbums(_ id: String, includeGroups:)`, and extended `search(_:offset:types:limit:)`.
- **`PlayerMac/PlayerMac/Music/`:**
  - `SpotifyLibraryStore+Loading.swift` & `SpotifyLibraryStore+Mutations.swift`: Preserved followed playlists in `library.playlists` and gated editability checks in `ensurePlaylistLoaded(_:requireEditable:)` on `requireEditable`.
  - `SpotifyLibraryStore+Discovery.swift`: Implemented `searchPlaylists(_:)` and multi-strategy `discover(...)`.
  - `MusicViewModel.swift`, `MusicViewModel+Discovery.swift`: Added left-column drill-down state, albums overview state, discovery state, and queue expansion/drop handlers.
  - `SourceColumn.swift`, `AlbumsWorkspaceView.swift`, `DiscoveryWorkspaceView.swift`, `CollectionHeader.swift`, `TrackTable.swift`, `QueueView.swift` (`CompactQueueColumn`), `DeckView.swift`, `MusicView.swift`, `MusicKeyboard.swift`, `PlayerRootView.swift`, `PlayerCommands.swift`: Implemented the full v3 UI and localized all 25 new keys across all 30 `.lproj/Localizable.strings` catalogs.
