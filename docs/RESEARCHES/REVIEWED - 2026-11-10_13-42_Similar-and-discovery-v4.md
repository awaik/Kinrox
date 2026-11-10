# Similar & Discovery v4: engine, ListenBrainz, radio and workspace UX

- **Date:** 2026-11-10 13:42 (Europe/Moscow)
- **Previous work:** [Spotify v3 three-column queue and discovery](<DONE/DONE - 2026-11-07_11-12_Spotify-v3-three-column-queue-and-discovery.md>)
- **Owner request (2026-11-10):** "Do all proposed items." Engine and services are implemented by Codex, review by agy (Gemini), Figma design and SwiftUI layout by the orchestrator (Claude).
- **Owner decision (2026-11-10):** a new external-service exception to principle 4 is approved: ListenBrainz / MusicBrainz (MetaBrainz Foundation) for listening-based similarity on Mac.
  Revised the same day: **on by default after the Spotify connection**, disclosed in the accepted Spotify privacy policy; can be turned off at any time in Settings → Spotify; no requests while off.

Status: Implemented locally (engine, ListenBrainz/MusicBrainz, radio, UI, 30-locale strings); default-on owner revision implemented with 30-locale privacy disclosures; live Spotify/ListenBrainz acceptance and performance measurement pending; not released.

**Owner revision 2026-11-10: default on.** The earlier opt-in proposal is superseded. An absent preference means enabled after Spotify connection/privacy acceptance; stored `false` remains disabled. Settings → Spotify explains the feature as “Recommendations from other listeners” and provides the off switch. Models without a defaults store remain disabled; reconnect reapplies the preference. Document version remains `2026-11-10` (unreleased). Regressions failed before the fix and passed afterward (23 discovery tests); required verification passed: 65 KinroxMusic tests, 353 PlayerMac tests, full strict Swift lint, 120 generated pages / 30 locales, and 8 document tests. MetaBrainz traffic used URLProtocol fixtures; live acceptance remains pending. See the [verification runbook](../runbooks/MUSIC-VERIFICATION.md#owner-revision-2026-11-10-default-on).

## 1. Problem

With the seed `Christian Löffler, Dominik Eulberg — Refu (Dominik Eulberg Remix)`, Similar & Discovery
lists almost exclusively Christian Löffler tracks, every row labelled `Artist: Christian Löffler`.
The genre chips (`#psybient`, `#organic electronic`, …) are not related to the seed, the only
"mix" duplicates the list, and the first recommendation is the seed itself.

## 2. Evidence (current code)

| # | Defect | Location |
|---|---|---|
| E1 | Hard-coded `defaultGenres` (owner's personal taste) are shown whenever Spotify returns no genres | `Packages/KinroxMusic/Sources/MusicCore/MusicDiscovery.swift:84`, `:247` |
| E2 | `sameSpirit` without a genre searches by the seed artist name, so results are the same artist | `SpotifyLibraryStore+Discovery.swift` `operatorQuery` (`case .sameSpirit`) |
| E3 | Remote playlist co-occurrence is effectively disabled: search results are filtered to playlists the user can edit, while public playlists return 403 in Development Mode | `SpotifyLibraryStore+Discovery.swift` `readablePlaylists` |
| E4 | Every catalog track becomes a candidate with score 50 and reason `sharedGenre` without any genre check (fake reason, inflated count 323) | `MusicDiscovery.swift` final `for track in catalog.tracks` loop |
| E5 | Only the seed track ID is excluded; another release of the same recording is ranked #1 | `MusicDiscovery.swift` `excludedIDs` |
| E6 | No per-artist cap or seed-artist penalty, no diversity re-ranking; ties sorted alphabetically | `MusicDiscovery.swift` `ordered` |
| E7 | Playlist co-occurrence is not normalised by playlist size; counts depend on loop order | `MusicDiscovery.swift` steps 1 and 4 |
| E8 | `Underground` / `Fresh` search `tag:hipster` / `tag:new` combined with the seed artist name → that artist's own albums, `tag:new` usually empty | `SpotifyLibraryStore+Discovery.swift` `case .underground, .fresh` |
| E9 | ~10 sequential requests, no per-seed cache | `SpotifyLibraryStore.discover` |
| E10 | Fallback mix `mix:spirit` is the top 8 of the same list titled with the seed | `MusicDiscovery.swift` mixes |

## 3. External facts (verified 2026-11-10)

Spotify Development Mode after the February/March 2026 changes
([migration guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide),
[February changelog](https://developer.spotify.com/documentation/web-api/references/changes/february-2026),
[March changelog](https://developer.spotify.com/documentation/web-api/references/changes/march-2026)):

- Available: `GET /v1/tracks/{id}`, `/v1/artists/{id}`, `/v1/artists/{id}/albums`, `/v1/albums/{id}`,
  `/v1/albums/{id}/tracks`, `/v1/search` (limit max 10, default 5, paginate with `offset`).
- Removed: batch `GET /v1/tracks|albums|artists`, `/v1/artists/{id}/top-tracks`, recommendations,
  related artists, audio features, browse.
- Removed fields: `popularity` (track/album/artist), album `label`, `available_markets`, artist `followers`.
  `external_ids` (ISRC) on track and album **remains** (reverted in March). `genres` and `release_date` remain
  (artist `genres` is frequently empty in practice).
- Therefore: no label-based signal; no popularity-based "underground" ranking.

ListenBrainz / MusicBrainz, probed with `curl` and User-Agent `Kinrox-dev/0.1 ( https://kinrox.app )`:

| Endpoint | Auth | Result |
|---|---|---|
| `GET https://labs.api.listenbrainz.org/similar-artists/json?artist_mbids=<mbid>&algorithm=session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30` | none | 200. For Christian Löffler (`a0d91c38-f5dc-487b-9b30-b67de1e7489e`): Jon Hopkins 876, Rival Consoles 803, Kiasmos 781, Mohna 775, Moderat 703, Bonobo 669, Max Cooper 650, Nils Frahm 606 … |
| `GET https://labs.api.listenbrainz.org/similar-recordings/json?recording_mbids=<mbid>&algorithm=session_based_days_9000_session_300_contribution_5_threshold_15_limit_50_skip_30` | none | 200, list of `{recording_mbid, recording_name, artist_credit_name, release_name, score, reference_mbid}`; may be `[]` for niche recordings |
| `POST https://labs.api.listenbrainz.org/spotify-id-from-mbid/json` body `[{"recording_mbid": "…"}, …]` | none | 200, bulk `{recording_mbid, artist_name, release_name, track_name, spotify_track_ids: [...]}` |
| `GET https://labs.api.listenbrainz.org/recording-search/json?query=<artist title>` | none | 200, text → `recording_mbid` (fallback when no ISRC match) |
| `GET https://musicbrainz.org/ws/2/isrc/<ISRC>?inc=artist-credits&fmt=json` | none, **1 req/s**, descriptive UA required | ISRC → recordings + artist MBIDs |
| `GET https://musicbrainz.org/ws/2/artist/?query=artist:"<name>"&fmt=json&limit=3` | none, 1 req/s | name → artist MBID (fallback) |
| `GET https://musicbrainz.org/ws/2/artist/<mbid>?inc=genres&fmt=json` | none, 1 req/s | genres; Christian Löffler: ambient house, ambient techno, deep house, electronic, melodic house, microhouse … |
| `api.listenbrainz.org/1/metadata/lookup`, `/1/explore/lb-radio`, `/1/popularity/*` | **token required (401)** | not used |

The POST form of `similar-artists/json` also works (`[{"artist_mbids": [...], "algorithm": "..."}]`).
Labs endpoints are an experimental "dataset hoster"; the client must treat any failure or schema change
as "signal unavailable" and never block local/Spotify results.

## 4. Plan

### 4.1. Ranking model (MusicCore, pure and unit-tested) — Codex

Replace hand-tuned constants with a signal model in `MusicCore` (split files so every file stays ≤500 lines, e.g. `MusicDiscovery.swift` + `MusicDiscoveryRanking.swift`):

- `MusicDiscoverySignal` kinds and base weights (normalised `0...1` per signal, weighted sum):
  `listenBrainzRecording` 1.0, `listenBrainzArtist` 0.8, `collaborator` 0.7, `remixer` 0.6,
  `ownPlaylistCooccurrence` 0.7 (IDF-weighted: `Σ 1/log2(2 + playlistSize)`), `compilation` 0.5,
  `likedSameDay` 0.4, `playHistoryTransition` 0.6, `sharedGenre` 0.35 (**only** when a genre is confirmed for
  the candidate's artist or returned by an explicit `genre:"…"` query), `freshRelease` 0.45 / `underground` 0.45
  (plus mode multipliers below). Weights live in one table.
- **Per-signal `0...1` normalisation:**
  - `listenBrainzRecording` and `listenBrainzArtist`: `clamp(rawScore / maxRawScoreInResponse, 0...1)` (or rank-based `1 - index / count` if all raw scores are ≤0).
  - `ownPlaylistCooccurrence`: compute raw IDF sum `Σ 1 / log2(2 + max(1, playlistTrackCount))` across overlapping user playlists where `playlist.itemsAvailable`, then normalise by `min(1.0, rawIDF / maxRawIDF)` across candidates (with a floor of `min(1.0, rawIDF * 2.0)` when only one candidate exists).
  - Binary/ranked signals (`collaborator`, `remixer`, `compilation`, `likedSameDay`, `playHistoryTransition`, `sharedGenre`, `freshRelease`, `underground`): `1.0` (or rank-decayed `max(0.5, 1.0 - Double(offset) * 0.03)` for ordered search results).
- Each candidate keeps all contributing `MusicDiscoveryReason` entries sorted by weighted contribution descending; `reasons[0]` is the highest-weighted contribution. If multiple signals of the same `kind` fire for one candidate, keep the highest weight and richest `detail`.
- **No catalog-wide fallback** (E4): a track appears **only** with at least one confirmed signal.
- **Local signal extraction inside `MusicDiscoveryEngine.build`:** so synchronous initial discovery (`MusicViewModel.refreshDiscovery()`) and `DemoMusicLibraryStore` work offline without the old catalog fallback:
  - Resolve `effectiveSeedTrackIDs = seedTrackIDs.isEmpty && seedArtistIDs.isEmpty ? library.likedTrackIDs : seedTrackIDs`.
  - Resolve `effectiveSeedArtistIDs = seedArtistIDs.isEmpty ? Set(effectiveSeedTrackIDs.compactMap { catalog.track(id: $0) }.flatMap(\.artists).map(\.id)).union(seedTrackIDs.isEmpty ? library.followedArtistIDs : []) : seedArtistIDs`.
  - Extract local `ownPlaylist` co-occurrence from `library.playlists` (`where playlist.itemsAvailable && !playlist.trackIDs.isEmpty`) that contain any `effectiveSeedTrackIDs` (or tracks by `effectiveSeedArtistIDs` when `effectiveSeedTrackIDs` has no playlist hits).
  - Extract local 2-hop `collaborator` and title-parsed `remixer` signals from `catalog.tracks` and `catalog.albums` co-credited with `effectiveSeedArtistIDs` (excluding `"Various Artists"`).
  - Extract local `likedSameDay` for tracks in `catalog` whose `addedAt` is within `±12 * 3600` seconds of any seed track's `addedAt`.
- **Dedupe & seed-variant exclusion** (E5):
  - Key = `normalisedPrimaryArtist + "|" + baseTitle`, where `baseTitle` strips `- … Remix|Edit|Mix|Version|Remaster(ed)|Live| Instrumental|Radio Edit…`, parenthetical `(… Remix|Edit|Mix|Version|feat. …|ft. …|with …)`, bracketed `[…]`, case, punctuation, and diacritics; non-empty case-insensitive `track.isrc` equality also merges candidates.
  - Exclude all variants of the seed: any candidate whose `track.id` is in `effectiveSeedTrackIDs`, whose non-empty `isrc` matches a seed track's `isrc`, whose `(normalisedPrimaryArtist, baseTitle)` matches a seed track's key, **or** whose `baseTitle` matches a seed track's `baseTitle` while sharing any artist ID or normalised artist name with the seed (catching remixes where the remixer is billed first, e.g. `Dominik Eulberg, Christian Löffler — Refu (Dominik Eulberg Remix)`).
  - When two non-seed candidates share a dedupe key or ISRC, keep the highest-scoring variant and merge their distinct `reasons`.
- **Penalties:**
  - Seed-artist penalty: any candidate credited to an artist in `effectiveSeedArtistIDs` (or matching a normalised seed artist name) is multiplied by `×0.35` across **all** modes (`sameSpirit`, `underground`, `fresh`).
  - Negative feedback: tracks whose ID is in `notInterestedTrackIDs` and tracks with any artist in `notInterestedArtistIDs` are excluded.
  - Play history penalties: tracks played within the last 14 days (`completed == true`) are multiplied by `×0.5`; tracks skipped (`playedSeconds < 30`, `skipped == true`) `≥ 2` times are excluded.
- **Diversity** (E6): MMR-style greedy re-rank over scored candidates: at most **2 tracks per primary artist** in the first 30 items, and at most **3 tracks overall** for any seed artist; deterministic tie-break by stable FNV-1a hash of `track.id` (never alphabetical).
- **Modes:**
  - `sameSpirit`: base weighted model.
  - `underground`: boosts (`×1.35`) candidates whose artists are not in the user's library (`followedArtistIDs`, `likedTrackIDs` artists, `savedAlbumIDs` artists) and whose ListenBrainz artist score is in the lower half of the similar-artists list (or comes from `undergroundTracks`).
  - `fresh`: boosts (`×1.35`) candidates whose release date (`track.releaseDate ?? catalog.album(id: track.albumID)?.releaseDate ?? catalog.album(id: track.albumID)?.year`) is within the last 12 months (relative to `now` passed into `build`) or that come from `freshTracks`.
- **Sections** for the UI (`MusicDiscoverySectionKind`), mapped deterministically from each item's primary reason (`reasons[0].kind`):
  - `.listeners`: `listenBrainzRecording`, `listenBrainzArtist`
  - `.collaborators`: `collaborator`, `remixer`, `compilation`
  - `.yourPlaylists`: `ownPlaylist`, `likedSameDay`, `playHistory`
  - `.genre`: `sharedGenre`, `freshRelease`, `underground`
  Emit non-empty sections in `[.listeners, .collaborators, .yourPlaylists, .genre]` order, preserving relative MMR rank within each section. A flattened ranked `items` list stays for Play all / radio.
- **Mixes** (E10): only real sources — user playlists from `library.playlists` (`itemsAvailable`) that contain the seed, plus `compilationAlbums` with ≥2 playable non-seed tracks. **No synthetic `mix:spirit` fallback.** Update `Packages/KinroxMusic/Tests/MusicCoreTests/BrowserSelectionTests.swift` so playlist mix assertions use a playlist-member seed (e.g. `"evening-2"` or `"neon-0"`) and verify that a non-playlist seed produces no synthetic mix.
- **Genres** (E1): remove `defaultGenres`. Source priority: Spotify artist genres (`.spotify`) → MusicBrainz genres when ListenBrainz/MusicBrainz is enabled (`.musicBrainz`) → `[]` (`.none`). Expose `genreSource: MusicGenreSource`; the UI hides the genre chip row when `genres.isEmpty`.

### 4.2. Spotify-side signals & model plumbing — Codex

In `Packages/KinroxMusic/Sources/MusicCore/`, `Packages/KinroxMusic/Sources/SpotifyWebAPI/`, and `PlayerMac/PlayerMac/Music/Spotify/` (split files to stay ≤500 lines):

- **Model & cache digest updates:**
  - Add optional `public let isrc: String?` and `public let releaseDate: String?` (defaulting to `nil` in `init`) on `MusicTrack`, and optional `public let releaseDate: String?` (defaulting to `nil` in `init`) on `MusicAlbum` in `Packages/KinroxMusic/Sources/MusicCore/MusicModels.swift`.
  - In `Packages/KinroxMusic/Sources/MusicCore/MusicCatalog.swift`, update `MusicCatalog.merge` so `internedAlbum` preserves `releaseDate: album.releaseDate ?? existing?.releaseDate` and `merged` (`MusicTrack`) preserves `isrc: track.isrc ?? existing?.isrc` and `releaseDate: track.releaseDate ?? canonicalAlbum?.releaseDate ?? existing?.releaseDate`. (Critical because `albumTracks` returns simplified tracks without `external_ids` and must not wipe an existing `isrc`.)
  - In `PlayerMac/PlayerMac/Music/Spotify/Cache/SpotifyCacheDecoder.swift`, mix `album.releaseDate`, `track.isrc`, and `track.releaseDate` into `SpotifyCacheSummary.digest(_:)`.
  - In `PlayerMac/PlayerMac/Music/Spotify/Cache/SpotifyCacheStore.swift`, preserve `releaseDate: album.releaseDate` in `SpotifyCacheStore.pruned(_:)`.
  - In `Packages/KinroxMusic/Sources/SpotifyWebAPI/SpotifyModels.swift`, decode `external_ids.isrc` on `SpotifyTrack` (`struct ExternalIDs: Decodable, Sendable { let isrc: String? }`) and pass `isrc: externalIDs?.isrc` and `releaseDate: (album ?? fallback)?.releaseDate` in `SpotifyTrack.model(...)`, plus `releaseDate: releaseDate` in `SpotifyAlbum.model(...)`.
  - In `Packages/KinroxMusic/Sources/SpotifyWebAPI/SpotifyLibraryEndpoints.swift`, add `public func track(_ id: String) async throws -> SpotifyTrack` (`try await get(SpotifyTrack.self, "tracks/" + Self.identifier(id))`).
- **Hydrate seed track ISRC when missing:**
  - Tracks loaded via `me/albums` or `albums/{id}` use Spotify's `SimplifiedTrackObject` and lack `external_ids.isrc`. In `SpotifyLibraryStore.discover`, if `let seedTrack, seedTrack.isrc == nil`, fetch `client.track(seedTrack.id)` via `optionalDiscoveryRead` in the initial task group, merge the hydrated track into `catalog`, and pass its `isrc` into MusicBrainz resolution.
- **Collaborators / remixers (2 hops):**
  - Collect co-credited artists and title-parsed remixers (`"… - X Remix"`, `"(X Remix)"`) from:
    1) `seedTrack.artists` and `seedTrack.title`,
    2) tracks/albums by `primaryArtist` already in `catalog`,
    3) `artistAlbums(artistID, includeGroups: "album,single,appears_on,compilation")` and the fetched compilation album tracks, plus a seed-artist track query (`search("artist:\"\(primaryArtist.name)\"", types: "track", limit: 10)`) used **only** to harvest collaborator/remixer names and ISRCs (never adding solo seed-artist tracks as `sharedArtist` candidates).
  - Never treat the seed artists or `"Various Artists"` (ID `0LyfQWJT6nXafLPZqxe9Of` or normalised name `"various artists"`) as collaborators.
  - For up to **4 collaborators/remixers**: run `client.search("artist:\"\(name)\"", types: "track", limit: 5)`, accept only tracks where a credited artist's normalised name matches `name` (or for remixers, where `track.artists` or `track.title` matches `name`), and tag them as `.collaborator` or `.remixer` (with `detail: name`).
- **Compilations:** from `appears_on,compilation`, prefer albums with `2...30` tracks; keep tracks whose primary artist is **not** a seed artist and not `"Various Artists"`, tagged as `.compilation` (`detail: album.title`).
- **Remove** the editable-only remote playlist search path (E3) — public playlists return 403 in Development Mode, and user playlists are handled locally.
- **Underground / Fresh** (E8): query by `activeGenre` only (`genre:"\(activeGenre)" tag:hipster` for `.underground`; `genre:"\(activeGenre)" tag:new` or `genre:"\(activeGenre)" year:\(currentYear)` for `.fresh`), **never** by the seed artist name; skip the query when `activeGenre == nil`.
- **Concurrency & request budget:** run independent Spotify discovery reads concurrently with `withThrowingTaskGroup` under `SpotifyRequestContext.$priority.withValue(.background)` so playback control keeps its reserved scheduler slot; preserve `session == sessionGeneration` and cancellation guards.
- **Per-seed SQLite cache (24 h TTL):**
  - Because `SpotifyCacheStore.pruned(_:)` strips non-library tracks from `catalog_entities` and `SpotifyLibraryStore.pruneDisposableCatalog` only keeps the latest `recentDiscoveryTrackIDs`, the per-seed cache entry in SQLite **must serialize the full candidate `MusicTrack` and `MusicAlbum` values** alongside their signal inputs, resolved `genres`, `genreSource`, and `compilationAlbums`.
  - Key by `"\(seedKey)|\(mode.rawValue)|\(selectedGenre ?? "")|\(listenBrainzEnabled ? 1 : 0)"`.
  - On a fresh (<24 h) cache hit, merge the cached `MusicTrack` and `MusicAlbum` entries into `catalog`, update `recentDiscoveryTrackIDs` / `recentDiscoveryAlbumIDs`, and return the built `MusicDiscoverySnapshot` immediately; if stale or missing, fetch and persist.

### 4.3. Local signals, play history & negative feedback — Codex

- **Own playlists:** IDF co-occurrence over `library.playlists` where `playlist.itemsAvailable`.
- **Same-day likes:** tracks in `catalog` / `library.likedTrackIDs` liked within ±12 h of the seed (`addedAt`).
- **Play history store & SQLite lifecycle:**
  - Add new tables (`discovery_cache`, `metabrainz_cache`, `play_history`) inside `library.sqlite` in `SpotifyCacheStore.connect()` (`CREATE TABLE IF NOT EXISTS ...`), and place the new actor methods in a separate extension file `PlayerMac/PlayerMac/Music/Spotify/Cache/SpotifyCacheStore+Discovery.swift` (`SpotifyCacheStore.swift` is already 406 lines; ceiling is 500 lines).
  - Do **not** add `discovery_cache`, `metabrainz_cache`, or `play_history` to the `if previous == nil { DELETE FROM ... }` loop in `SpotifyCacheStore.write()`. Keeping them in `library.sqlite` guarantees that `SpotifyCacheStore.destroyAccountCache()` on Disconnect deletes all cached discovery/MetaBrainz data and play history cleanly without leaving orphan files in `cache.directory` (`SpotifyCacheTests.hardExpiryEvictsWholeResourcesAndDisconnectRemovesSidecars`).
  - Keep an in-memory buffer of play history rows on `MusicViewModel` / `SpotifyLibraryStore` (persisted to `SpotifyCacheStore` when connected, and usable in-memory in unit tests without disk cache). Retention: 180 days, max 20 000 rows. Never sent to iPhone or ListenBrainz.
  - **Recording play history on `MusicViewModel`:** `.ended(id)` in `MusicEngine` fires **only** on natural EOF, never on manual skips. Track an active play session per `queue.current?.id` **only after playback has actually been unpaused (`!paused`)** (so initial/restored paused queues never record false 0-second skips):
    - On `.ended(id)` (natural EOF): record `completed = true`, `skipped = false`, `playedSeconds = max(accumulatedSeconds, track.duration)`, `previousTrackID = lastCompletedTrackID`, and update `lastCompletedTrackID = track.id`.
    - On manual occurrence replacement (`advance(automatically: false)`, `play`, `playShuffled`, `previous`) or `stop()` / `shutdownPlayback()` / `replaceStore()` after the track was unpaused: compute `playedSeconds`, set `completed = playedSeconds >= max(30, min(track.duration * 0.5, track.duration - 5))`, `skipped = !completed && playedSeconds < 30 && track.duration >= 30`, `previousTrackID = lastCompletedTrackID`, and if `completed` update `lastCompletedTrackID = track.id`.
  - **Transitions (`A → B`):** when building discovery for seed track `A`, any history row for track `B` where `previousTrackID == A.id && completed == true` (or vice versa in the same listening session) contributes a `.playHistory` (`playHistoryTransition`) signal for `B`.
- **Negative feedback:**
  - Persist `notInterestedTrackIDs: Set<String>` and `notInterestedArtistIDs: Set<String>` in `defaults` (`UserDefaults?` on `MusicViewModel`, using keys `app.kinrox.music.notInterestedTracks` and `app.kinrox.music.notInterestedArtists` when `defaults != nil`, plus in-memory state for tests) and clear them on account disconnect if desired.
  - Maintain a LIFO stack of `notInterested` actions so `undoNotInterested()` restores the most recently hidden track or artist and re-runs `refreshDiscovery()`.

### 4.4. ListenBrainz / MusicBrainz client (`MetaBrainzAPI`) — Codex

- **Package & project wiring:**
  - Add Mac-only library product and target `MetaBrainzAPI` (plus test target `MetaBrainzAPITests`) in `Packages/KinroxMusic/Package.swift` (Foundation only, `Sendable`, no Spotify types).
  - Add `- package: KinroxMusic / product: MetaBrainzAPI` to both `PlayerMac` and `PlayerMacTests` dependencies in `PlayerMac/project.yml`, and run `./Scripts/generate.sh` so `PlayerMac.xcodeproj` links `MetaBrainzAPI`.
- **HTTP & privacy rules:**
  - User-Agent: `Kinrox/<CFBundleShortVersionString> ( https://kinrox.app )`; no user identifiers, no cookies (`URLSessionConfiguration.ephemeral` with `urlCache = nil`, `httpCookieStorage = nil`, `httpShouldSetCookies = false`), HTTPS only, 10 s request timeout, no redirects to non-HTTPS hosts.
  - MusicBrainz (`musicbrainz.org/ws/2/*`) rate limiter: actor enforcing ≥1.0 s between requests using an injected clock/sleeper for deterministic unit testing; retry once on HTTP 503 honouring `Retry-After` (capped at 5 s). Treat HTTP 404 (e.g. unknown ISRC) as a clean empty result (`nil`), not an error.
- **Resolution chain & JSON schemas:**
  1. Check 30-day SQLite/in-memory cache for seed `track.id` / `isrc` → `(recordingMBID, artistMBIDs)` and `artist.id` / normalised artist name → `(artistMBID, genres)`.
  2. If uncached and `isrc` is available: `GET https://musicbrainz.org/ws/2/isrc/<ISRC>?inc=artist-credits&fmt=json` → decode `recordings[].id` and `recordings[].artist-credit[].artist.id`.
  3. Fallback if no ISRC or 404: `GET https://labs.api.listenbrainz.org/recording-search/json?query=<artist title>` (accept only when normalised `artist_credit_name` and `recording_name` match the seed) and/or `GET https://musicbrainz.org/ws/2/artist/?query=artist:"<name>"&fmt=json&limit=3` (accept exact normalised artist `name`).
  4. If Spotify returned no genres (`genres.isEmpty`) and `artistMBID` is known: `GET https://musicbrainz.org/ws/2/artist/<mbid>?inc=genres&fmt=json` → sort `genres` by `count` descending then `name`, take top 6, and set `genreSource = .musicBrainz`.
- **Similarity signals & Spotify mapping budget:**
  - Query `similar-recordings` (top 50) and `similar-artists` (top 15) on `labs.api.listenbrainz.org` (7-day SQLite cache keyed by MBID).
  - Map recording MBIDs via bulk `POST https://labs.api.listenbrainz.org/spotify-id-from-mbid/json`. For each mapped recording, prefer a Spotify track ID already present in `catalog` (0 network requests). For uncached Spotify track IDs, fetch `GET /v1/tracks/{id}` for **at most 8 IDs** under `.background` priority (since `SpotifyRequestScheduler` allows 2 concurrent non-control requests, capping at 8 prevents 429 rate limits and multi-second stalls).
  - For top similar artists without recording hits (excluding seed artists), query `client.search("artist:\"\(artist.name)\"", types: "track", limit: 5)` for **at most 5 artists**, accepting only tracks whose credited artist matches `artist.name` (normalised), and tag with `.listenBrainzArtist` (`detail: artist.name`).
- **Error handling & consent gating:**
  - Any network/decoding failure on `MetaBrainzAPI` degrades gracefully: local and Spotify signals still build the snapshot, `listenBrainzStatus` becomes `.unavailable`, and raw errors are never surfaced as `statusMessage`.
  - **Consent gating:** an absent `app.kinrox.music.listenBrainzEnabled` preference means `true` after Spotify connection/privacy acceptance; explicit stored `false` is respected. Models without a defaults store remain disabled, and reconnect reapplies the preference. When `false`, `listenBrainzStatus` is `.off`, the client is not invoked, and **zero** requests are sent to `musicbrainz.org` or `labs.api.listenbrainz.org` (verify with a `URLProtocol` stub that fails on any request).

### 4.5. Radio (auto-refill) — Codex

- In `Packages/KinroxMusic/Sources/MusicCore/MusicQueue.swift`, add `public mutating func appendSource(_ tracks: [MusicTrack])`: filters `isPlayable != false`, assigns sequential `sourceOrder` starting after `context.map(\.sourceOrder).max() ?? -1`, and appends `MusicQueueItem(track: ..., origin: .source, sourceOrder: ...)` to both `source` and `context`. (Do **not** use `queue.add` or `queue.insert(..., before: nil)`, which append to `manual`.)
- Put radio coordination in a separate extension file `PlayerMac/PlayerMac/Music/MusicViewModel+Radio.swift` so `MusicViewModel+Discovery.swift` (370 lines) and `MusicViewModel+Playback.swift` (398 lines) stay under 500 lines:
  - `startDiscoveryRadio()` starts playback of `discoverySnapshot?.tracks ?? contents.tracks`, sets `isDiscoveryRadioActive = true`, creates a fresh `radioSessionID = UUID()`, and seeds `radioSeenTrackIDs` / `radioSeenDedupeKeys` with all tracks in the initial queue.
  - Any non-radio queue source replacement (`play`, `playShuffled`, `playAlbum`, `stop`, `shutdownPlayback`, `replaceStore`) calls `stopDiscoveryRadio()`, which sets `isDiscoveryRadioActive = false`, invalidates `radioSessionID`, and cancels any in-flight radio refill task.
  - **Refill trigger (after `startQueue` completes, and on `advance`, `receive` occurrence change, or `removeFromQueue`):** when `isDiscoveryRadioActive`, `!isRefillingRadio`, and `queue.source.count < 5` (upcoming non-manual items < 5), launch a background refill task bound to `radioSessionID` seeded by `queue.current?.track`:
    - Build/fetch discovery items for `queue.current?.track`, filter out all track IDs and `(normalisedPrimaryArtist, baseTitle)` / `isrc` variants already in `radioSeenTrackIDs`, `radioSeenDedupeKeys`, `queue.items`, or `queue.history`.
    - Take up to **10** playable tracks, record them in `radioSeenTrackIDs` / `radioSeenDedupeKeys`, and append them via `editQueue { $0.appendSource(refillTracks) }` while `self.isDiscoveryRadioActive && self.radioSessionID == sessionID`.

### 4.6. View-model contract for the UI (Codex implements, orchestrator consumes)

`MusicCore`:

```swift
public enum MusicDiscoveryReasonKind: String, Codable, Equatable, Sendable {
    case listenBrainzRecording
    case listenBrainzArtist
    case collaborator
    case remixer
    case compilation
    case ownPlaylist
    case likedSameDay
    case playHistory
    case sharedGenre
    case freshRelease
    case underground
}

public struct MusicDiscoveryReason: Codable, Equatable, Sendable {
    public let kind: MusicDiscoveryReasonKind
    public let detail: String   // e.g. "Jon Hopkins", playlist title, genre
    public let matchCount: Int
}

public enum MusicDiscoverySectionKind: String, Codable, CaseIterable, Sendable {
    case listeners, collaborators, yourPlaylists, genre
}

public struct MusicDiscoverySection: Identifiable, Codable, Equatable, Sendable {
    public var id: String { kind.rawValue }
    public let kind: MusicDiscoverySectionKind
    public let items: [MusicDiscoveryItem]
}

public struct MusicDiscoverySeed: Codable, Equatable, Sendable {
    public let title: String
    public let artistNames: String
    public let trackID: String?
    public let artistID: String?
}

public enum MusicGenreSource: String, Codable, Equatable, Sendable {
    case spotify, musicBrainz, none
}

public enum MusicListenBrainzStatus: String, Codable, Equatable, Sendable {
    case off, ready, unavailable
}
```

- `MusicDiscoveryItem` keeps `public let track: MusicTrack`, `public let reasons: [MusicDiscoveryReason]`, `public let score: Double`, `public let section: MusicDiscoverySectionKind`, plus compatibility properties `public var primaryReason: MusicDiscoveryReason? { reasons.first }`, `public var reasonKind: MusicDiscoveryReasonKind { reasons.first?.kind ?? .sharedGenre }`, `public var contextName: String { reasons.first?.detail ?? "" }`, and `public var matchCount: Int { reasons.first?.matchCount ?? 1 }`.
- `MusicDiscoverySnapshot` keeps `public var seed: MusicDiscoverySeed`, `public var mode: MusicDiscoveryMode`, `public var genres: [String]`, `public var genreSource: MusicGenreSource`, `public var selectedGenre: String?`, `public var hideLiked: Bool`, `public var sections: [MusicDiscoverySection]`, `public var items: [MusicDiscoveryItem]`, `public var mixes: [MusicDiscoveryMix]`, plus compatibility properties `public var seedTitle: String { seed.title }` and `public var tracks: [MusicTrack] { items.map(\.track) }`.

`MusicViewModel` (Discovery & Radio extensions):

- `discoverySnapshot`, `isDiscovering`, `discoverySeedHistory: [MusicDiscoverySeed]`, `canGoBackDiscovery: Bool`,
  `goBackDiscoverySeed()`; `openSimilar(...)` pushes the previous seed onto `discoverySeedHistory` (max 10, avoiding adjacent duplicates) when navigating to a new seed.
- `notInterested(track:)`, `notInterested(artist:)`, `canUndoNotInterested: Bool`, `undoNotInterested()`.
- `startDiscoveryRadio()`, `stopDiscoveryRadio()`, `isDiscoveryRadioActive: Bool`.
- `listenBrainzEnabled: Bool` (get/set, persisted in `defaults`; toggling triggers `refreshDiscovery()` when `.similar` is active), `listenBrainzStatus: MusicListenBrainzStatus` (`.off | .ready | .unavailable`).
- `setDiscoveryMode`, `setDiscoveryGenre`, `toggleDiscoveryHideLiked` keep their names.

### 4.7. UI — orchestrator (Claude), not Codex

Codex must **not** edit `PlayerMac/PlayerMac/Music/UI/**` or `Resources/Localization/*.lproj/Localizable.strings` beyond the minimal mechanical switch adaptation in `PlayerMac/PlayerMac/Music/UI/DiscoveryWorkspaceView.swift` (`reasonDescription(for:)`).
**Critical localization constraint for Codex:** `Scripts/check-localization.py` enforces exact equality between `L10n.text`/`L10n.format` keys in Swift files and `Resources/Localization/en.lproj/Localizable.strings`. `DiscoveryWorkspaceView.reasonDescription(for:)` is the sole caller of `"In %@ playlists: %@"`, `"Compilation: %@"`, `"Underground · tag:hipster"`, `"Fresh release · tag:new"`, `"Genre: %@"`, and `"Artist: %@"`. When updating `reasonDescription(for:)` for the new `MusicDiscoveryReasonKind` cases, Codex **must keep all 6 existing `L10n` calls** (mapping `.ownPlaylist, .likedSameDay, .playHistory` to `"In %@ playlists: %@"`, `.listenBrainzRecording, .listenBrainzArtist, .collaborator, .remixer` to `"Artist: %@"`, and leaving the other 4 cases unchanged) and must **not** introduce any new `L10n.text`/`L10n.format` calls.

Orchestrator work after Codex finishes, designed first on a new Figma page `11 · Spotify — Discovery v4`:

1. Seed card header (icon, "Similar to", title, artists, seed history back chevron, drop a track to reseed),
   replacing the huge truncated title and duplicated breadcrumb.
2. Modes as a segmented control; filters row (Hide liked, genres with source hint) with horizontal scroll and
   edge fade; row hidden when no genres.
3. Sectioned results; reason as a secondary grey line (icon + text), no repeated orange pills.
4. Row actions on hover only: play, add to queue, like (same icon semantics as the deck Favorite), "More like
   this", context menu "Not interested in track / artist".
5. Mixes shown only for real sources, as horizontal cards.
6. "Play all" → "Start radio" with an active state; secondary "Add all to queue".
7. Loading skeleton and "Searching Spotify / ListenBrainz…" status; empty and unavailable states.
8. Settings → Spotify explanation (what is sent, link to privacy) + “Recommendations from other listeners” toggle, on by default after connection/privacy acceptance (owner revision 2026-11-10).
9. Left column: no meaningless Similar count; unreadable playlists show a lock instead of `0`; hide
   "Various Artists".
10. Deck/queue: "This Mac" no longer wraps; single Shuffle/Repeat location; queue drop zone only while dragging.

### 4.8. Documentation and privacy — Codex

- `AGENTS.md` principle 4 and Rule 8: add the ListenBrainz/MusicBrainz exception (owner decision 2026-11-10,
  revised the same day: on by default after Spotify connection/privacy acceptance, off switch in Settings → Spotify, Mac only, data sent as in 4.4).
- Spotify connection privacy supplement (`Resources/Spotify/SpotifyConnection.<locale>.json`, all 30 locales),
  `PlayerMac/PlayerMac/Music/Spotify/SpotifyDocuments.swift`, and generated site pages (`site/` via `Scripts/build-site.py`):
  - Keep the exact 8 `terms` section IDs and 6 `privacy` section IDs (`overview`, `access`, `storage`, `iphone`, `retention`, `cookies`) required by `SpotifyDocuments.decode` and `Scripts/build-site.py`.
  - Append a ListenBrainz / MusicBrainz paragraph to `privacy` (`access` / `storage`) in all 30 locales explaining default-on status after Spotify connection and the off switch in Settings → Spotify, data sent (artist names, track titles, ISRCs, MBIDs; no user identifiers or cookies), local SQLite caching (7-day similarity, 30-day MBIDs, deleted on Disconnect), and local-only play history (retained up to 180 days / 20 000 plays, deleted on Disconnect, never sent to any external service or iPhone).
  - Preserve all required substrings checked by `Scripts/tests/test_spotify_documents.py` (`SQLite`, `Caches`, `Soloist`, `Connect`, `200`, `Origin`, `7`) and ensure every `https://...` URL in any section of `SpotifyConnection.en.json` appears the exact same number of times in the corresponding section of all 29 translated JSON files.
  - Bump `"version"` to `"2026-11-10"` in all 30 `SpotifyConnection.<locale>.json` files (and update the version date in `privacy[0].body`), update `SpotifyDocuments.currentVersion = "2026-11-10"` in `PlayerMac/PlayerMac/Music/Spotify/SpotifyDocuments.swift`, and run `python3 Scripts/build-site.py` to regenerate `site/` followed by `python3 Scripts/build-site.py --check`.
- `docs/runbooks/MUSIC-VERIFICATION.md`: document the Discovery v4 verification checks and limits.

## 5. Verification

- `./Scripts/generate.sh` — regenerate `PlayerMac.xcodeproj` after adding `MetaBrainzAPI` to `Packages/KinroxMusic/Package.swift` and `PlayerMac/project.yml`.
- `swift test --package-path Packages/KinroxMusic` — new tests in `MusicCoreTests`, `SpotifyWebAPITests`, and `MetaBrainzAPITests`:
  - dedupe & seed-variant exclusion including remixes and swapped artist billing (regression for E5),
  - no catalog-wide fallback / no fake `sharedGenre` reasons (regression for E4),
  - per-artist cap (≤2 in first 30, ≤3 overall for seed artist) and seed-artist `×0.35` penalty across modes (regression for E6),
  - IDF playlist co-occurrence normalisation independent of loop order (regression for E7),
  - real mixes only and no synthetic `mix:spirit` (regression for E10),
  - genre source priority without `defaultGenres` (regression for E1),
  - `MusicCatalog.merge` preserving `isrc` and `releaseDate` across simplified album-track merges,
  - `MusicQueue.appendSource` appending `.source` occurrences without touching `.manual`,
  - `MetaBrainzAPI` fixture decoding (`isrc`, `artist`, `genres`, `similar-artists`, `similar-recordings`, `spotify-id-from-mbid`, `recording-search`), 404 fallback, and rate-limiter ≥1 s spacing.
- `xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData build test`
  — consent gating (`listenBrainzEnabled == false` makes zero MetaBrainz requests via URLProtocol stub), album-track seed ISRC hydration, radio auto-refill into `queue.source` and stop-on-source-replace, play history recording (natural EOF vs `<30 s` skip vs paused-only non-skip, plus `A → B` transition signal), `notInterested` + `undoNotInterested`, per-seed SQLite cache 24 h TTL restoring non-library `MusicTrack` metadata after catalog pruning, and `destroyAccountCache()` removing all cache/history data.
- `xcrun swift-format lint --strict --recursive PlayerMac RemoteiOS Packages Shared`
- Line-length ceiling check (all touched files ≤500 lines):
  `find . \( -name '*.swift' -o -name '*.h' -o -name '*.sh' -o -name '*.yml' -o -name '*.xcconfig' \) -not -path '*/.build/*' -not -path '*/DerivedData/*' | xargs wc -l | awk '$1 > 500 && $2 != "total"'`
- `python3 Scripts/check-localization.py`, `python3 -m unittest discover -s Scripts/tests -p 'test_spotify_documents.py'`, and `python3 Scripts/build-site.py --check`.
- Manual (orchestrator): live seed `Christian Löffler — Refu`, with ListenBrainz off and on; Kinrox volume 0;
  Spotify.app terminated. Record request count and time-to-first-results.

## 6. Out of scope

iPhone protocol changes, release/version bump, Last.fm, any server component.

## Model log

### 2026-11-10 13:55 Europe/Moscow — Gemini 4 Argon (High) — `plan_review`

- **Operation:** `plan_review`
- **Findings:**
  - **CRITICAL 1 — `DiscoveryWorkspaceView.swift` localization check failure on `MusicDiscoveryReasonKind` change (`PlayerMac/PlayerMac/Music/UI/DiscoveryWorkspaceView.swift:250-268`, `Scripts/check-localization.py:40-45`):**
    Section 4.7 instructs Codex not to edit `PlayerMac/PlayerMac/Music/UI/**` or localization files (mistakenly cited as `Localizable.xcstrings` instead of `Resources/Localization/<locale>.lproj/Localizable.strings`) beyond minimal mechanical fixes. However, `DiscoveryWorkspaceView.reasonDescription(for:)` switches exhaustively on `MusicDiscoveryReasonKind` and is the **only** caller in the repository for 6 localization keys (`"In %@ playlists: %@"`, `"Compilation: %@"`, `"Underground · tag:hipster"`, `"Fresh release · tag:new"`, `"Genre: %@"`, `"Artist: %@"`). `Scripts/check-localization.py` asserts exact set equality between `L10n.text`/`L10n.format` keys in Swift files and `en.lproj/Localizable.strings`. Dropping any of those 6 `L10n` calls or adding new ones in Codex's pass causes `python3 Scripts/check-localization.py` to fail.
  - **CRITICAL 2 — Per-seed SQLite discovery cache loses remote `MusicTrack` metadata after catalog pruning or restart (`PlayerMac/PlayerMac/Music/Spotify/SpotifyLibraryStore.swift:234-291`, `SpotifyLibraryStore+Discovery.swift:170-188`, `SpotifyCacheStore.swift:282-315`):**
    Section 4.2 originally specified persisting only `track IDs + signals` in the 24 h per-seed SQLite cache. However, `SpotifyCacheStore.pruned(_:)` strips all non-library tracks from `catalog_entities`, and `SpotifyLibraryStore.pruneDisposableCatalog` retains `recentDiscoveryTrackIDs` only for the single most recent discovery call. Switching from Seed A to Seed B or restarting the app evicts Seed A's remote `MusicTrack` and `MusicAlbum` models from `catalog`, so a subsequent cache hit for Seed A would return empty/incomplete items unless the per-seed cache entry serializes the candidate `MusicTrack` and `MusicAlbum` payloads and merges them back into `catalog` on restore.
  - **CRITICAL 3 — Radio auto-refill appends to `queue.manual` instead of `queue.source` and races with async `runPlayback` (`Packages/KinroxMusic/Sources/MusicCore/MusicQueue.swift:61-92`, `PlayerMac/PlayerMac/Music/MusicViewModel+Playback.swift:59-68, 288-367`, `SoloistMusicEngine.swift:50-53`):**
    `MusicQueue` currently has no method to append items to `source`; both `queue.add(_:)` and `queue.insert(_:before: nil)` append with `origin: .manual` to `queue.manual`, which would place radio tracks ahead of remaining `source` tracks and leave `queue.source.count < 5` forever (triggering infinite refills). Additionally, `play(_:)` runs asynchronously via `runPlayback` / `PlaybackCoordinator.perform`; checking or editing `model.queue` before `startQueue` finishes fails `SoloistMusicEngine.updateQueue` (`current == queue.current?.id`) or mutates the old queue.
  - **MAJOR 1 — `MusicCatalog.merge`, `SpotifyCacheSummary.digest`, and `SpotifyCacheStore.pruned` drop `isrc` and `releaseDate` (`Packages/KinroxMusic/Sources/MusicCore/MusicCatalog.swift:49-109`, `SpotifyCacheDecoder.swift:123-167`, `SpotifyCacheStore.swift:301-306`):**
    `MusicCatalog.merge` and `SpotifyCacheStore.pruned` reconstruct `MusicAlbum` and `MusicTrack` field-by-field, and `SpotifyCacheSummary.digest` hashes explicit fields for incremental SQLite writes. Because `albumTracks` returns Spotify `SimplifiedTrackObject` items without `external_ids`, `MusicCatalog.merge` must preserve `track.isrc ?? existing?.isrc` and `releaseDate`, and `SpotifyCacheSummary.digest` must hash `isrc` and `releaseDate`.
  - **MAJOR 2 — Album-sourced seed tracks lack `isrc` in `catalog` and `SpotifyClient` lacks `GET /v1/tracks/{id}` (`PlayerMac/PlayerMac/Music/Spotify/SpotifyLibraryStore+Loading.swift:68-134`, `Packages/KinroxMusic/Sources/SpotifyWebAPI/SpotifyLibraryEndpoints.swift`):**
    Tracks loaded from saved or browsed albums are decoded from `SimplifiedTrackObject` without `external_ids.isrc`. Seeding discovery from an album track skips the primary ISRC → MusicBrainz lookup unless `SpotifyLibraryStore.discover` hydrates `client.track(seedTrack.id)` when `seedTrack.isrc == nil`. `SpotifyLibraryEndpoints.swift` also needs a `track(_ id: String)` method.
  - **MAJOR 3 — Play history skip detection cannot rely on `.ended` events, and paused initial/restored queues must not record false skips (`PlayerMac/PlayerMac/Music/MusicViewModel+Playback.swift:17-57, 134-155, 304-326`):**
    `MusicEngine` emits `.ended(id)` only at natural EOF, never when a user skips a track via `next()`, `previous()`, or `play(...)`. Conversely, `MusicViewModel.init` and queue restoration set `queue.current` while paused; recording a skip when replacing a never-unpaused track would falsely penalize initial/restored tracks. Play history must track active playback sessions only after `!paused` and finalize on both `.ended(id)` and manual occurrence transitions.
  - **MAJOR 4 — SQLite schema lifecycle, `destroyAccountCache()`, and 500-line ceiling (`PlayerMac/PlayerMac/Music/Spotify/Cache/SpotifyCacheStore.swift:189-274, 317-326`, `PlayerMacTests/SpotifyCacheTests.swift:62-80`):**
    `SpotifyCacheStore.swift` is already 406 lines, `MusicViewModel+Discovery.swift` is 370 lines, and `MusicViewModel+Playback.swift` is 398 lines (ceiling is 500 lines). `SpotifyCacheStore.write()` wipes tables listed in its `previous == nil` loop, and `destroyAccountCache()` removes only `library.sqlite` and its WAL/SHM/journal sidecars before `SpotifyCacheTests` asserts `cache.directory` is deleted. New tables (`discovery_cache`, `metabrainz_cache`, `play_history`) must reside inside `library.sqlite` (excluded from the `previous == nil` wipe) with methods in `SpotifyCacheStore+Discovery.swift`.
  - **MAJOR 5 — `MetaBrainzAPI` XcodeGen wiring and Spotify request concurrency budget (`PlayerMac/project.yml:57-66, 94-103`, `Packages/KinroxMusic/Sources/SpotifyWebAPI/SpotifyRequestScheduler.swift:41-52`):**
    `MetaBrainzAPI` must be added to `PlayerMac/project.yml` (`PlayerMac` and `PlayerMacTests` targets) followed by `./Scripts/generate.sh`. Because `SpotifyRequestScheduler` allows at most 2 concurrent non-control requests, uncached `GET /v1/tracks/{id}` calls for ListenBrainz recordings must be capped at 8 (not 25), `similar-artists` track searches at 5, and collaborator searches at 4, while excluding `"Various Artists"` from collaborator/compilation harvesting.
  - **MINOR 1 — Local signal extraction in `MusicDiscoveryEngine.build` and `BrowserSelectionTests` (`Packages/KinroxMusic/Tests/MusicCoreTests/BrowserSelectionTests.swift:42-53`):**
    Specified local signal extraction in `MusicDiscoveryEngine.build` (own-playlist IDF co-occurrence, local 2-hop collaborators/remixers in `catalog`, same-day likes, and default seed fallback) and updating `BrowserSelectionTests` to test real playlist mixes rather than the removed synthetic `mix:spirit`.
  - **MINOR 2 — Section mapping, seed-artist penalty across modes, and Spotify document validation (`PlayerMac/PlayerMac/Music/Spotify/SpotifyDocuments.swift:14, 41-58`, `Scripts/build-site.py:140-169`, `Scripts/tests/test_spotify_documents.py:10-46`):**
    Specified deterministic `0...1` signal normalisation, mapping `freshRelease` and `underground` to `.genre`, applying the `×0.35` seed-artist penalty and swapped-billing remix dedupe in all modes, and preserving the exact 8 `terms` / 6 `privacy` section IDs, URL counts, and required keywords across all 30 `Resources/Spotify/SpotifyConnection.<locale>.json` files before running `python3 Scripts/build-site.py`.
- **Changes made:** Updated Sections 4.1–4.8 and Section 5 in this document to incorporate all fixes, file paths, contracts, and verification commands; set status to `Plan review completed; awaiting implementation.` and renamed the file with the `REVIEWED - ` prefix.
- **Checks & results:**
  - Read and verified `AGENTS.md`, `docs/RESEARCHES/README.md`, `docs/runbooks/RUNBOOK-TASK-TESTS.md`, `Packages/KinroxMusic/**`, `PlayerMac/PlayerMac/Music/**`, `PlayerMac/project.yml`, `Scripts/build-site.py`, `Scripts/check-localization.py`, and `Scripts/tests/test_spotify_documents.py`.
  - Executed `swift test --package-path Packages/KinroxMusic` — passed (44 tests in 7 suites).
  - Checked incoming links to `2026-11-10_13-42_Similar-and-discovery-v4` across `docs/`, `AGENTS.md`, and `README.md` — none found.

## Implementation outcomes — 2026-11-10 14:30 Europe/Moscow

Scope: main checkout on `main`; **not released**. The initial worktree had no tracked
changes, with pre-existing `.tmp/` and this reviewed document untracked. Those files,
earlier review evidence and generated artifacts were preserved. No branch, commit,
worktree, push, PR, dependency installation, installed-app replacement, account change,
release/version bump, export, signing-policy change or publication was performed.

| Plan item | Outcome and changed paths |
| --- | --- |
| 4.1 Ranking | Implemented in `Packages/KinroxMusic/Sources/MusicCore/MusicDiscovery.swift`, `MusicDiscoveryRanking.swift`, `MusicDiscoveryIdentity.swift`, `MusicDiscoveryLocalSignals.swift`: weighted confirmed signals, local graph/IDF/likes/transitions, seed/ISRC/remix dedupe, feedback/history penalties, diversity, modes, sections, real mixes and genre provenance. |
| 4.2 Spotify/model/cache | Implemented in `MusicModels.swift`, `MusicCatalog.swift`, `SpotifyModels.swift`, `SpotifyLibraryEndpoints.swift`, `SpotifyLibraryStore+Discovery.swift`, `SpotifyLibraryStore+DiscoverySignals.swift`, `SpotifyLibraryStore+MetaBrainz.swift`, and cache digest/store extensions. Full candidate tracks **and albums** survive pruning/cache restore. Removed discovery playlist search and seed-artist genre fallback; bounded background requests and seed ISRC hydration added. |
| 4.3 History/feedback | `MusicViewModel+History.swift`, `MusicViewModel+DiscoveryState.swift`, playback/library hooks and `SpotifyCacheStore+Discovery.swift`: observed-play sessions, natural/manual endings, local transitions, retention, SQLite lifecycle, persisted negative feedback and LIFO undo. Paused-only queues create no skips. |
| 4.4 MetaBrainz | New Foundation-only `Sources/MetaBrainzAPI/` product and tests; linked only by Mac targets through `Package.swift` and `PlayerMac/project.yml`. Ephemeral HTTPS/no-cookie session, 1-second MusicBrainz limiter, bounded 503 retry, exact fallback matching, 30-/7-day caches, zero calls while off, graceful unavailable status and consent-generation guards. |
| 4.5 Radio | `MusicQueue.appendSource`, `MusicViewModel+Radio.swift` and playback hooks: start after asynchronous queue load, refill source with up to 10 unseen playable recordings, preserve manual order, cancel/invalidate on replacement/stop/shutdown, and reject late responses. |
| 4.6 UI contract | View-model fields/actions and MusicCore DTOs implemented, including bounded seed history with retained metadata, feedback/undo, sections, radio and persisted similarity preference (default revision recorded above). |
| 4.7 UI | **Pending orchestrator**, as explicitly assigned by the plan. Only the exhaustive reason switch in `Music/UI/DiscoveryWorkspaceView.swift` was adapted, retaining all six existing localization calls. No Figma changes or other UI/localization edits were made. |
| 4.8 Documentation | `AGENTS.md` exception/Rule 8, `SpotifyDocuments.currentVersion`, all 30 `Resources/Spotify/SpotifyConnection.*.json`, 60 generated privacy/terms HTML pages, `Scripts/tests/test_spotify_documents.py`, and `docs/runbooks/MUSIC-VERIFICATION.md` updated. Document consent version is `2026-11-10`; app versions remain unchanged. |

New regressions are in `MusicDiscoveryRegressionTests.swift`, `MusicDiscoveryRankingTests.swift`,
`DiscoveryMetadataTests.swift`, `MetaBrainzAPITests/`, `DiscoveryServiceTests.swift`,
`DiscoveryViewModelTests.swift` and the isolated `DiscoveryHTTPStub.swift`.
`BrowserSelectionTests.swift` now uses a real playlist-member seed; the existing Fresh
service test supplies a confirmed genre instead of relying on the removed artist fallback.

### Evidence, checks and limits

Logs are preserved under `.tmp/scratch/research-execute/runs/2026-11-10_17-43-26-BmsgP2/`.
These are task-local artifacts, not release assets. The initial ranking regression
(`swift test --package-path Packages/KinroxMusic --filter MusicDiscoveryRegressionTests`)
failed **before production changes**, with 5 assertions covering invented genres/reasons,
synthetic mix, seed remix and artist flooding (`discovery-red.log`). A second regression
failed 3 album-metadata/cache assertions before its correction (`album-cache-red.log`);
the final service test confirms collaborator-search album metadata survives cache reuse.

| Exact command / check | Result / evidence |
| --- | --- |
| `./Scripts/check-env.sh` | Passed; `environment.log`. Existing toolchain used, nothing installed. |
| `./Scripts/generate.sh` | Passed after package/project wiring and new app test files; `generate-tests.log`. Both generated projects retained. |
| `bash Scripts/make-test-media.sh` | Passed; existing media retained, `test-media.log`. Script inspected before execution. |
| `swift test --package-path Packages/KinroxMusic` | 60 tests / 12 suites passed, `music-final4.log`. |
| `xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData build test` | 334 tests / 63 suites passed, `mac-final3.log`, including the previously failing album-cache regression. Earlier passing full runs (330/332/333 tests) and all failed runs remain preserved. |
| `xcodebuild -workspace Kinrox.xcworkspace -scheme RemoteiOS -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath DerivedData build test` | 62 tests / 12 suites passed; `ios-final.log`. Subsequent changes affect only Mac discovery code/tests. |
| `xcrun swift-format lint --strict <39 changed Swift paths>` | Passed; exact paths in `changed-swift.txt`, `swift-lint-final3.log`. Scoped to touched sources per task instructions. |
| Changed source/config/script 500-line ceiling and `git diff --check` | Passed; changed Swift maximum 416 lines, `line-counts.json`. Existing oversized master specification was not restructured. |
| `python3 Scripts/check-localization.py` | Passed: 30 locales, 419 UI keys, permission prompts and format arguments. |
| `python3 -m unittest discover -s Scripts/tests -p 'test_spotify_documents.py'` | 8 tests passed. |
| `python3 -m unittest discover -s Scripts/tests -p 'test_site_localization.py'` | 9 tests passed. |
| `python3 Scripts/build-site.py` and `python3 Scripts/build-site.py --check` | Generated and verified 120 pages / 30 languages; only the 60 privacy/terms pages changed. No deployment. |
| `xcodebuild -workspace Kinrox.xcworkspace -scheme <PlayerMac or RemoteiOS> -configuration <Debug or Release> -showBuildSettings -json` | All four combinations passed. `build-settings.json`: Swift 6 / complete concurrency, macOS 14.0 and iOS 17.0; Mac 0.5.6 (16), Remote 0.2.1 (3), unchanged. |
| `xcrun vtool -show-build DerivedData/Build/Products/Debug/Kinrox.app/Contents/MacOS/Kinrox` and Info.plist `LSMinimumSystemVersion` | Both report 14.0; `mac-minimum-os.log`. No macOS 14 runtime test. |

Intermediate failures remain preserved: a Swift compiler region-isolation diagnostic
was resolved by capturing the Sendable Spotify client rather than transferring main-actor
closures through task groups; two test-fixture assumptions were corrected (default seed
includes followed artists; diversity may displace a transition in a large demo catalog).
A full-metadata album merge regression preserved existing summary-merge behavior while
adding release-date enrichment. The Czech privacy assertion now allows the grammatical
`iPhonu` spelling. Strict lint rejected one block comment, replaced with a line comment.
No production signing, concurrency, scheduler or timeout setting was weakened.

Implementation choices within scope: caches are bounded (10 in-memory seeds, 256 SQLite
entries per metadata cache); a radio occurrence gets one refill attempt to avoid an empty
result loop; redirects are rejected entirely. Unmatched/null Spotify mappings are empty
results. Failed Labs responses are not persisted as a 24-hour discovery success. MusicBrainz
rate-limit behavior was rechecked against its [official documentation](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting);
public Labs schemas were sampled without credentials or private listening data.

Remaining work: the orchestrator must implement/design Section 4.7 and complete its consent
UX hand-off, then exercise `Refu` with ListenBrainz off/on, record real request counts and
time-to-first-results, and verify radio/feedback/seed navigation in the native UI. Live
Spotify startup/playback/pause/sustained physical-footprint and CPU measurements and command
latencies were **not performed**. An installed Kinrox/Soloist session was active and left
untouched; no system or live Kinrox volume was changed. Automated fake-engine/HTTP results
are not standalone acceptance. Physical iPhone checks and manual app launch were not run.
Sleep/reboot checks remain waived, not passed. No separate macOS 14 runtime test was done.

The document remains at its reviewed root path because this required orchestrator work
and live verification are outstanding. No DONE destination or supporting artifact was
moved/overwritten. All 55 relative links in the changed documents resolve; incoming references from the music runbook point to this unchanged reviewed path (`links-check.log`). The complete path inventory is `changed-paths.txt` in the run directory.

### 2026-11-10 14:30 Europe/Moscow — GPT-6 Astra (xhigh) — `implementation`

- **Operation:** `implementation`
- **Completion time:** 2026-11-10 14:32:05 Europe/Moscow.
- **Model:** `gpt-6-astra` (xhigh), as recorded by this run's orchestrator metadata.
- **Outcome:** Codex engine/services, regression coverage and documentation implemented locally;
  orchestrator UI/live acceptance remain pending. Release status: **not released**.
- **Checks:** Results and preserved failures are listed above. No separate post-implementation review or additional agent was launched.

### Review fixes (2026-11-10)

Backend/view-model review pass on `main`, preserving the existing uncommitted work.
No UI or localization files were edited in this pass; no localization keys were added
or removed. No commit, branch, stash, reset, cleanup, release or installation was performed.

| Finding | Fix and regression coverage |
| --- | --- |
| CRITICAL 1 | Model-lifetime defaults observation with a weak model capture and token cleanup; stored consent rechecked immediately before discovery/refill. URLProtocol regression revokes consent outside Similar during active radio and requires zero MetaBrainz requests; observer lifetime/retention covered. |
| CRITICAL 2 | Similar selection refreshes on init/replacement and connection/library restoration. Disconnected stores render local results without remote authentication errors; connection changes trigger discovery. Restore/replace regression added. |
| MAJOR 1 | Current-track fallback requires no explicit seed. Artist seeds have no track ID; album/playlist titles remain their human titles, and missing collection tracks load before discovery. Unavailable playlists retain a title seed without failing. Artist, unloaded album/playlist and restricted-playlist regressions added. |
| MAJOR 2 | After the initial artist cap, ranking admits remaining eligible candidates with balanced artist counts while retaining the seed-artist cap. Regressions cover 5 artists × 5 tracks, a full first-30 diversity pass, and the seed cap. |
| MAJOR 3 | Remixer extraction rejects qualifier-only/numeric names; local and remote title matching use exact normalized extracted credits. Regressions cover Vocal Mix, years, multiword qualifiers, Dawn Remix and the unrelated Before the Dawn title. |
| MAJOR 4 | Radio awaits the coordinator/engine append before clearing its busy flag or committing seen IDs. Background append bypasses the interrupting-playback guard. Only an exhausted pool blocks an occurrence; removal permits another attempt. Regressions cover delayed/failed commits, transient discovery failure, removal, exhaustion and visible order. |
| MAJOR 5 | Failed Labs recording search falls through to MusicBrainz artist/genre lookup. Recordings/mapping and artist requests fail independently; surviving signals preserve ready status. Cancellation is rethrown. HTTP regressions cover server/schema failures, each independent branch, genre-only success and cancellation. |
| MAJOR 6 | Seed signals cache separately by seed/consent; mode/genre searches have their own keys. Cached inputs rerank synchronously for filters and retain previous remote search sections while replacement searches run. Unoffered selected genres clear. Request-count, feedback, retained-section and consent/genre regressions added; the existing Fresh fixture now supplies its confirmed artist genre. |
| MAJOR 7 (model) | Added snapshot displayItems/displayTracks in section order; model contents/keyboard data and radio consume that order. Ranked items remain available. Visible-order regression added. |
| MINOR 2 | Five artist searches sample three leaders and two lower-half artists, preserving original response indices for lowerHalf. Request-budget/cache and Underground-score regressions added. |
| MINOR 4 | Disconnect clears both negative-feedback sets, undo history and defaults keys. Regression added. |

Verification artifacts: `.tmp/discovery-v4-fixes/` (all intermediate logs retained).
The initial package regressions failed on the original behavior (10 issues); the final
`swift test --package-path Packages/KinroxMusic` passed **65 tests / 12 suites**.
`./Scripts/generate.sh` succeeded. Strict swift-format lint and the 500-line ceiling
passed for all **26** Swift files changed in this pass (maximum 419 lines); scoped
`git diff --check` passed. A standalone Foundation probe also confirmed delivery of
UserDefaults change notifications for the exact dotted consent key.

**Mac verification remains blocked, not passed:** the requested full
`xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData build test`
failed at `PlayerMac/PlayerMac/Music/UI/DiscoveryTrackRow.swift:29:42` with
“the compiler is unable to type-check this expression in reasonable time.” The same
UI failure persisted on retries; that concurrently owned file was left untouched.
`mac-full.log` contains only this compiler diagnostic. New Mac regressions are written
but have not executed; run the full command again after the orchestrator resolves the
UI compilation failure. No live playback or external-service acceptance is claimed.

### 2026-11-10 19:30 Europe/Moscow — Claude Opus 5.5 (orchestrator) — `design_ui_verification`

- **Figma:** new page `11 · Spotify — Discovery v4` (`191:304`): `v4 · 01` (`191:305`) seed card, mode
  segmented control, sectioned results with grey reasons, hover actions, real mixes, queue radio banner;
  `v4 · 02` (`191:789`) radio active, ListenBrainz opt-in card, loading skeleton, row context menu
  (Not interested), undo toast; notes frame with v4 UI rules.
- **SwiftUI (Section 4.7, items 1–10):** `DiscoveryWorkspaceView`, `DiscoveryHeaderViews` (seed card with
  history, reseed drop for track/album/playlist/queue payloads, adaptive full/icon actions, one/two-row
  controls with genre source and edge fade), `DiscoveryTrackRow` (mounted hover actions, keyboard focus,
  VoiceOver actions, shortened grey reasons), `DiscoveryStateViews` (opt-in card, skeleton, empty state,
  real mixes strip, undo toast); `SpotifySettingsSection` ListenBrainz toggle (persisted key observed by
  the model for its lifetime); `SourceColumn` (no Similar count, lock for unreadable playlists, Various
  Artists hidden in list/count/picker/keyboard); `QueueView` (radio banner, drop hint only while dragging,
  Shuffle/Repeat only in the deck); `DeckView` (output label only in wide windows).
- **Localization:** 53 new keys translated into 29 languages, 6 obsolete discovery keys removed.
- **Code review (agy, Gemini 4 Argon High):** 2 CRITICAL / 7 MAJOR / 4 MINOR. Backend findings fixed by Codex
  (table above); UI findings (CRITICAL 1 UI side, MAJOR 1 title, MAJOR 7 menu/focus/accessibility/order,
  MINOR 1 narrow layout, MINOR 3 Various Artists and drop payloads) fixed by the orchestrator. The
  `DiscoveryTrackRow` type-check timeout was resolved by splitting the row body.
- **Checks (final):** PlayerMac `build test` — 349 tests / 64 suites passed; `swift test --package-path
  Packages/KinroxMusic` — 65 passed; RemoteiOS simulator tests — 62 passed; `swift-format lint --strict
  --recursive PlayerMac RemoteiOS Packages Shared` — clean; `check-localization.py` — 30 locales, 466 keys;
  `build-site.py --check` — 120 pages; `test_spotify_documents.py` — OK. Offscreen `NSHostingView`
  render of the workspace on demo data matched the Figma frame (temporary test removed).
- **Not performed:** live run against the owner's Spotify account and live ListenBrainz requests from the
  app — the owner's installed Kinrox was playing music and shares the bundle identifier, so the Debug build
  was not launched over it. Live seed check (`Christian Löffler — Refu`), request counts, time to first
  results and memory remain for the owner/next session. The original opt-in proposal was superseded by the owner’s same-day default-on revision recorded above.

## Owner follow-up (2026-11-10, evening)

- Users do not know ListenBrainz: similarity is on by default; the in-screen invite card, source labels
  ("· ListenBrainz", "· Spotify", "Genres · MusicBrainz") and technical status texts were removed. The only
  explanation and the off switch live in Settings → Spotify: "Recommendations from other listeners".
- "Start radio" renamed to "Listen to similar" (help: "Plays these tracks, then keeps adding similar ones on
  its own"); queue banner "Adding similar tracks as you listen" with Stop; icon `infinity`.
- Figma page 11 updated; new frame `197:305` (Settings → Spotify).
- agy review of the follow-up: 0 critical, 0 major, 4 minor — status reset on store replacement and removal
  of unused v3 shims (codex, with regression tests), Malay "Seting" wording, settings caption now names the
  "Similar & discovery" screen. The reported toast-name mismatch was not a defect: toasts name the screen,
  not the "Similar" action button.
- Verification: PlayerMac 355 tests, KinroxMusic 65 tests, strict lint, 30-locale localization (455 keys),
  site check 120 pages, Spotify document tests.
