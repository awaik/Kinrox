# Standalone Spotify playback without WebView — research brief

Status: Ready for owner review, 2026-11-03. S0–S7 implementation and local packaging are complete with documented owner waivers for physical sleep/reboot and macOS 14 execution. Soloist is the default production engine; Next p95 ≤3.2 s is accepted. Mac 0.5.0 build 9 is signed and notarized locally. The owner requested no commit and review later; no commit, tag, release publication or website deployment has occurred.
The [implementation plan](#soloist-implementation-plan--2026-11-02) extends the original brief below.
Initial status: research requested; architecture selection and implementation plan pending.
At the original research request, no native replacement had been built, authenticated, benchmarked, or integrated; the execution record below supersedes that historical status.
Date: 2026-11-02. Filename time zone: Europe/Moscow.

## Assignment

Investigate how Kinrox can play Spotify music itself while retaining its native
Swift/SwiftUI interface. Produce an evidence-backed engine recommendation and a
file-level implementation plan that another agent can execute. Research the actual
streaming and authentication path before recommending a large integration.

Read [AGENTS.md](../../AGENTS.md) completely and follow the
[research workflow](README.md). The critical owner requirements added on
2026-11-02 supersede the historical decision to control Spotify.app.

This assignment is research and implementation planning. An isolated, minimal
native prototype may establish feasibility and measurements; do not replace the
production engine, redesign the UI, publish a release, or change the website as
part of this assignment. Keep findings and the resulting plan in this document.

## Mandatory product requirements

1. **Spotify.app must be fully terminated.** Kinrox must cold-start, authenticate
   as necessary, start a track, continue playing, pause/resume, seek, change
   volume, and advance tracks without a Spotify.app process. Closing its window,
   hiding it, or launching it automatically does not satisfy the requirement.
2. **No WebView anywhere in either Kinrox app.** No WKWebView, hidden browser,
   Electron/Chromium runtime, or web player used as the playback backend. The
   existing explicit sign-in in the external system browser is not an embedded
   WebView; it must not become a persistent playback dependency.
3. **Retain Swift/SwiftUI.** Do not rewrite the application in Rust. A native
   dependency may use Rust, C, C++, or another suitable language; language choice
   alone is not evidence of speed or low memory use.
4. **Responsive controls and low memory use.** Measure the complete proposed
   playback path and all helper processes. No numerical budget has been approved;
   propose budgets from measured results and clearly label them as proposals.
5. Preserve the library, search, independent favorites and Undo, local queue
   semantics, keyboard/media controls, Now Playing, and encrypted LAN iPhone remote.
   The iPhone must not acquire Spotify credentials, stream music, or call Spotify.

The existing Web API can remain responsible for metadata and library mutations.
The missing capability is native audio playback, not a replacement for every
Spotify-related component.

## How the current implementation works

### Authentication and library

The user supplies their own Client ID. `SpotifyAuthorization` creates a PKCE
request; `SpotifyLoopback` opens the external system browser through NSWorkspace
and receives the callback at `http://127.0.0.1:43821/callback`.
`SpotifyAccount` manages refresh and account generations. The refresh token is
stored in the Mac Data Protection Keychain. Current requested scopes cover
library, playlists, and playback control; they do **not** include `streaming`.

`SpotifyLibraryStore` uses `SpotifyClient` for library/search/favorite operations.
A SQLite metadata cache supports progressive restoration and synchronization.
Keep those improvements unless evidence requires a narrowly scoped change.

### Playback

The current command path is:

```text
SwiftUI / keyboard / media commands / encrypted LAN remote
    -> MusicViewModel and PlaybackCoordinator
    -> MusicEngine = SpotifyConnectMusicEngine
    -> Spotify Web API /me/player commands
    -> external Spotify.app produces audio
```

`PlayerSession` constructs `SpotifyConnectMusicEngine`. The engine selects an
existing Connect device whose type is `Computer` and whose display name exactly
matches `Host.current().localizedName`. Kinrox does not currently create a native
Spotify playback device or decode Spotify audio.

`MusicCore.MusicQueue` tracks individual occurrences, including repeated copies
of one track. The engine mirrors history and current/upcoming items into a private
Spotify playlist named `Kinrox Queue`, then starts that playlist at an offset.
Commands wait for observed state rather than treating HTTP 204 as completion.

The current performance implementation has already removed continuous polling.
Progress advances on a monotonic local clock; commands perform confirmation reads,
and a timer reconciles the expected track boundary. Do not describe the current
code as polling every two seconds; that is historical behavior.

`PlaybackCoordinator` serializes video/music transitions and owns the shared Now
Playing session. `RemoteMusicBridge` publishes confirmed state and paged queue
data to iPhone, including occurrence IDs, revisions, and position-anchor age.

### Why the reported behavior fails

With no matching external device, both Play and Volume fail in `selectDevice`
with `SpotifyError.noDevice`. The UI asks the user to open Spotify. This exposes
an architectural mismatch with the required standalone behavior.

Additional defects identified during diagnosis must be covered by the new plan:

- Transport controls can appear available with an empty queue; Play silently
  returns when `currentTrack == nil`.
- Volume starts at zero as model state, not as a verified device reading. The
  slider clears its draft on release, so a failed command returns it to that value.
- Even a successful, confirmed volume command outside the mirrored helper
  context is discarded by `SpotifyConnectMusicEngine.publish`.
- Exact display-name matching rejects an otherwise available computer. This
  mechanism should not be carried over as native device identity.

Five temporary diagnostic tests used unchanged copies of the engine and the real
HTTP client with synthetic HTTP responses. They reproduced missing-device rejection
for Play/Volume, display-name rejection, and volume publication only inside the
helper context. They establish current behavior, not native playback feasibility.
Local artifacts, if still available:

- `/tmp/kinrox-recording-20261102-141941/diagnostic/`
- `/tmp/kinrox-recording-20261102-141941/diagnostic-tests-complete-fixture.log`

## Code and prior evidence to inspect

Paths below are relative to the repository root.

| Area | Entry points |
|---|---|
| Engine interface and snapshots | `PlayerMac/PlayerMac/Music/MusicEngine.swift` |
| Current engine and device/queue/state handling | `PlayerMac/PlayerMac/Music/Spotify/SpotifyConnectMusicEngine.swift`, `SpotifyConnectMusicEngine+Queue.swift`, `SpotifyConnectMusicEngine+State.swift` in the same directory |
| Engine construction and account lifecycle | `PlayerMac/PlayerMac/App/PlayerSession.swift` |
| Playback model and availability | `PlayerMac/PlayerMac/Music/MusicViewModel.swift`, `MusicViewModel+Playback.swift`, `MusicViewModel+Availability.swift` in the same directory |
| Video/music coordination | `PlayerMac/PlayerMac/Music/PlaybackCoordinator.swift` |
| Authentication and credentials | `PlayerMac/PlayerMac/Music/Spotify/SpotifyAccount.swift`, `SpotifyLoopback.swift`, `SpotifyCredentialStore.swift` in the same directory; `Packages/KinroxMusic/Sources/SpotifyWebAPI/SpotifyOAuth.swift` |
| HTTP transport and control endpoints | `Packages/KinroxMusic/Sources/SpotifyWebAPI/SpotifyClient.swift`, `SpotifyPlayerEndpoints.swift` in the same directory |
| Library and cache | `PlayerMac/PlayerMac/Music/Spotify/SpotifyLibraryStore.swift`, its extensions, and `Cache/` |
| Queue and favorite policy | `Packages/KinroxMusic/Sources/MusicCore/` |
| Deck and sliders | `PlayerMac/PlayerMac/Music/UI/DeckView.swift`, `Shared/MusicSlider.swift` |
| LAN integration | `PlayerMac/PlayerMac/Remote/RemoteMusicBridge.swift`, `Packages/RemoteProtocol/Sources/RemoteProtocol/MusicState.swift`, `RemoteiOS/RemoteiOS/Connection/RemoteAppModel+Music.swift` |
| Build and distribution | `PlayerMac/project.yml`, `Scripts/build-release.sh`, `Scripts/release-source-lock.json`, `docs/runbooks/RUNBOOK-RELEASE.md` |
| Existing regression fixtures | `PlayerMac/PlayerMacTests/SpotifyConnectTests.swift`, `SpotifyLatencyTests.swift`, `SpotifyReviewFixTests.swift`, `MusicPlaybackTests.swift`, `RemoteMusicTests.swift`, `FakeMusicEngine.swift` in the same directory |

Read the [music verification](../runbooks/MUSIC-VERIFICATION.md),
[cache and latency verification](../runbooks/SPOTIFY-PERFORMANCE-VERIFICATION.md),
[review corrections](2026-11-02_Spotify-review-corrections.md), and
[historical music plan](<DONE/DONE - 2026-11-01_09-11_Music-mode-v2-implementation-plan.md>).
Their passing tests do not establish playback with Spotify.app terminated.

## Research questions to resolve

### 1. Native engine feasibility

Evaluate maintained native playback options that can actually authenticate,
obtain audio, decode it, and output it on Apple Silicon/macOS 14+. A library
wrapping `/me/player` is not a streaming engine. Do not propose the Web Playback
SDK: it requires a browser environment and fails the no-WebView requirement.

`librespot` is a candidate, not a selected or integrated dependency. Upstream
describes it as an alternative Spotify client with native playback and Premium
requirements. Verify a pinned released version, source/API behavior, maintenance,
audio backends, transitive dependencies, licensing, and service compatibility.
Distinguish unofficial-client limitations from restrictions of the official Web API.

Starting sources, to recheck rather than treat as a compatibility guarantee:

- [librespot repository and README](https://github.com/librespot-org/librespot)
- [Native playback example at v0.8.0](https://github.com/librespot-org/librespot/blob/v0.8.0/examples/play.rs)
- [OAuth implementation at v0.8.0](https://github.com/librespot-org/librespot/blob/v0.8.0/oauth/src/lib.rs)
- [Official Web Playback SDK description](https://developer.spotify.com/documentation/web-playback-sdk)
- [Official Spotify authorization scopes](https://developer.spotify.com/documentation/web-api/concepts/scopes)

### 2. Authentication without Spotify.app

Determine whether the user's existing Client ID can authorize the native engine,
which scopes and token/session types are required, and whether reconnection needs
fresh consent. Do not assume that a Web API refresh/access token is sufficient
for native playback or that an upstream example's Client ID is suitable for Kinrox.

Specify first sign-in, cold relaunch, expired/revoked credentials, account changes,
and Disconnect. Keep secrets in Keychain and transient protected IPC where needed;
do not put tokens in command-line arguments, logs, repository files, or iPhone data.
The external browser may handle interactive OAuth, then close; audio must remain
independent of that browser. Report any account action that cannot be tested.

### 3. Swift integration and audio ownership

Compare a native library through a small stable C ABI with a bundled native helper
process through bounded local IPC. Assess measured overhead, crash isolation,
threading, cancellation, teardown, build complexity, and distribution. Recommend
one concrete design rather than assuming either process model is inherently better.

Map it to `MusicEngine`: track loading, pause/resume, stop, seek, volume, queue
updates, observed state, end-of-track, errors, and shutdown. Define buffer ownership,
callback lifetime, session generations, command ordering, and Swift 6 actor hops.
Audio/network work must not block MainActor. Late events from retired sessions
must not overwrite the current track or restart audio after shutdown.

Identify the native output backend and who owns buffering, decoding, gain, and
progress. Plan bounded buffering and preloading; avoid retaining an entire library
or queue as decoded audio. Explain recovery from device changes and sleep/wake.

### 4. Queue and existing features

Determine whether native track loading removes the need to mirror the local queue
into a Spotify playlist. Preserve history, manual additions, source order,
duplicate occurrences, Shuffle, Repeat, natural advance, and paused edits.
Do not delete or rewrite old `Kinrox Queue` playlists during research or migration.

Keep official Web API operations for catalog/library/favorites where appropriate.
Preserve SQLite caching, undo transactions, video/music pause coordination,
Now Playing, and LAN confirmation semantics. Explain how local engine events
replace remote confirmation reads and what networking remains necessary.

### 5. Build, release, and migration

Specify pinned dependencies, reproducible build commands, architecture and minimum
OS, bundle location, signing/notarization, license notices, and added binary size.
Do not assume compilation on the development Mac establishes macOS 14 support.

List migration changes to account consent, credential storage, dependency/privacy
disclosures, and localized resources. Identify any genuinely new UI states that
need the existing Figma-first workflow. Plan explicit native-engine failure
handling; launching Spotify.app or embedding a browser is not an acceptable fallback.

## Prototype and measurement plan

Keep any probe isolated from production and retain its source, exact commands,
versions, results, and failed attempts. Do not install global tools, alter unrelated
projects, modify the user's Spotify library, or remove existing artifacts.
Use the available account/sign-in flow only within the authorized research scope;
if live access is unavailable, complete independent work and label the missing
validation instead of claiming success from stubs.

Before a live playback check, establish that Spotify.app is absent and remains
absent. Start with the native player's gain at zero and leave Mac system volume
unchanged. A command acknowledgement or advancing UI timer does not prove audio
playback: instrument decoded frames reaching the real output path at zero gain.

Record Release-mode measurements with hardware, OS, build settings, network state,
track format/quality, cache state, sample count, and tool definitions:

| Measurement | Required distinction |
|---|---|
| Startup | Process start, authenticated engine ready, and first decoded/output frame; cold versus warm |
| Controls | Submit-to-confirmed pause/resume, seek, volume, and next-track latency; p50/p95 where sample count supports them |
| Memory | Idle before login, connected idle, playback, pause, repeated track changes, and teardown; app and every helper |
| Sustained behavior | Memory trend, CPU, wakeups, and HTTP/request rates during at least 30 minutes where live access permits |
| Library scale | Existing small and large synthetic library fixtures; distinguish metadata cache cost from decoder cost |
| Distribution | Added app/helper/framework size and runtime dependencies |

Use consistent macOS memory metrics, including physical footprint where available;
report RSS separately and avoid misleading sums of shared mappings. Report helper
measurements as helper measurements, not as full-app results. Separate network
startup latency from local control latency. Do not invent baseline results or
promise a fixed MB/ms budget without measurements. Existing fixture-based cache
benchmarks are not live audio benchmarks.

## Required output and implementation handoff

Update this document with:

1. A concise feasibility verdict: one recommended architecture, alternatives
   rejected for concrete reasons, and unresolved blockers.
2. A current-versus-proposed data flow, including audio, authentication, metadata,
   queue, Swift boundary, and iPhone state.
3. A compatibility table for each candidate with source/version/date and the
   distinction between documented, locally tested, and unverified behavior.
4. Reproducible prototype results and measured latency/memory, or exact reasons
   those measurements remain unavailable.
5. An ordered implementation plan naming files/modules, interfaces, lifecycle,
   migration, packaging, and validation for each stage. Identify reusable code,
   code to replace, and historical helper state to preserve.
6. Proposed performance budgets with supporting measurements and any owner choice
   that remains necessary. Do not reopen the settled no-WebView or standalone goals.
7. A regression plan that first exposes missing standalone playback and then covers
   empty-queue controls, volume confirmation, repeated URIs, stale events, bounded
   buffers, EOF/Shuffle/Repeat, Disconnect, teardown/reopen, video transitions,
   and iPhone controls. Separate fake-engine contracts from live audio acceptance.

Implementation acceptance must include cold-starting Kinrox while Spotify.app is
fully terminated and exercising local and LAN controls without that process ever
appearing. Research is not implementation acceptance. Leave this document in the
research root while its implementation plan remains pending, and clearly record
that no release or deployment was performed.

---

## Soloist implementation plan — 2026-11-02

### Decision and evidence boundary

The owner selected official Spotify Soloist as the implementation direction. Build a native Swift controller around a separately installed Soloist process, using its loopback WebSocket API. Preserve the existing library, SQLite cache, favorites/Undo, occurrence queue, video coordination, and LAN remote. This is a conditional implementation plan, not a claim of standalone playback or release readiness. The original assignment and diagnostic evidence above remain unchanged.

Repository baseline inspected: `0b6291e`, with pre-existing owner changes to `AGENTS.md` and this untracked brief. No executable was downloaded or run, no account was accessed, and no live measurements were taken in this planning task. A Mac is available; lack of hardware is not the reason for missing measurements. Real-key execution awaits the argv decision and an explicitly arranged pairing test. Version `1.3.10.31` and Team ID `2FNC3A47ZF` from the supplied research are not a verified macOS release pin.

| Evidence checked on 2026-11-02 | Consequence for implementation |
|---|---|
| Official [Soloist overview](https://developer.spotify.com/documentation/soloist) and [CLI](https://developer.spotify.com/documentation/soloist/reference/command-line) describe Apple Silicon support and Core Audio. | Soloist owns audio/network buffers, decoding and output; Swift owns application behavior. Minimum-OS metadata is checked; a macOS 14 execution test is explicitly excluded by the owner on 2026-11-03. |
| [Authentication](https://developer.spotify.com/documentation/soloist/concepts/authentication) requires a personal API key and a separate Connect session; the key creator needs Premium. Sessions persist in the data directory. | Keep Web API PKCE and Soloist credentials separate. Phone-only onboarding is a test requirement, not a documented guarantee that every client discovers the device. |
| [Issues #12](https://github.com/spotify/soloist/issues/12) and [#24](https://github.com/spotify/soloist/issues/24) were open with zero comments when fetched; their reproductions concern Linux. | The CLI-only secret path is unresolved. Test macOS exposure without publishing the key. Keychain, environment expansion and log redaction do not remove argv exposure. |
| [Downloads](https://developer.spotify.com/documentation/soloist/reference/downloads-and-updates) publishes the Mac archive and prohibits redistribution. [Runtime overview](https://developer.spotify.com/documentation/soloist/concepts/overview) documents 90-day build lifetime and expiry exit code 10. | Fetch from Spotify to the user's Mac only; never ship an archive/binary in Kinrox, CI artifacts, releases or a mirror. Record the tested build and plan replacement before expiry. |
| [WebSocket reference](https://developer.spotify.com/documentation/soloist/reference/websocket-api) supplies state events and command acceptance, without documented request IDs, `position_ms` on `play`, EOF, or `stop`. | Correlation, non-zero start seeks, completion and queue ownership need a proven state machine. Acknowledgement alone is insufficient. |
| [Features](https://developer.spotify.com/documentation/soloist/features) states that local WebSocket control has no authentication or Origin validation. Single-track mode exits on completion, stop or item change and restricts remote control. | Loopback is not a user-authentication boundary. Initial persistent-mode selection was superseded by the owner-authorized per-occurrence process investigation on 2026-11-03; long-pause recovery and natural EOF remain explicit acceptance checks. |
| Official [redirect rules](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri) permit HTTP with literal loopback IPs. [Dev Mode migration](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide) requires Premium ownership and limits new apps/users, with grandfathering. [Refresh-token notice](https://developer.spotify.com/blog/2026-06-18-refresh-token-expiration) describes six-month expiry. | Retain `127.0.0.1:43821/callback`; update onboarding accurately and handle reauthentication independently of the engine session. Do not describe all existing apps as retroactively limited to one ID/five users. |

Alternatives are outside this implementation: Web Playback SDK violates the no-WebView requirement; `/me/player` alone supplies no local audio; obsolete/platform-specific SDKs do not solve the Mac requirement. The supplied librespot/go-librespot failure reports were not independently reproduced here. No unofficial playback fallback will be introduced. GPL alone is not a reason to reject a dependency for the GPL Mac app. Spotify's [Terms](https://developer.spotify.com/terms) restrict reverse engineering, subject to legal exceptions; its [Policy](https://developer.spotify.com/policy) restricts streaming and commercialization. Official Soloist availability does not by itself establish permission for every Kinrox distribution/use model; document the applicable terms before release.

### Target flow and module ownership

```text
Mac UI / keyboard / Now Playing / encrypted iPhone commands
  -> PlaybackCoordinator -> MusicViewModel + MusicQueue
  -> SoloistMusicEngine (@MainActor, no blocking I/O)
  -> SoloistRuntime actor -> loopback WebSocket -> Spotify Soloist -> Core Audio
                          -> SoloistProcessSupervisor -> Spotify Soloist (direct child Process)
                                                      -> KinroxSoloistHost (zero-secret sidecar reaper)
Library / search / favorites / device-binding check -> existing SpotifyClient -> Spotify Web API
```

| Concern | Existing implementation | Planned implementation |
|---|---|---|
| Audio | External Connect device, selected by Mac display name | Verified local Soloist installation, owned lifecycle; no Spotify.app dependency |
| Queue | `MusicQueue` plus mirrored private playlist | Existing occurrence IDs/history; load the selected occurrence only; local Next/Previous |
| State | Command confirmation reads and boundary reconciliation, already without continuous polling | Push state reducer and monotonic position anchors; bounded explicit resync |
| Credentials | PKCE refresh token in Keychain | Extend `SpotifyCredentialStore` with Soloist key; separate protected session directory |
| Metadata | Web API and SQLite | Same stores; engine metadata may fill the current deck without mutating library truth |
| iPhone | `RemoteMusicBridge` and encrypted v1 state | Additive v1 availability/unknown-volume fields; same LAN-only credential-free boundary |

Keep `MusicEngine.swift` in `PlayerMac/PlayerMac/Music/` and evolve its existing protocol rather than introducing a second `MusicEngine` in `MusicCore`. Keep the fake in `PlayerMacTests/`. `MusicCore.MusicQueueItem.id` already supplies occurrence identity. Split the engine into focused files under `PlayerMac/PlayerMac/Music/Soloist/` (`SoloistInstaller.swift`, `SoloistProcessSupervisor.swift`, `SoloistProtocol.swift`, `SoloistStateReducer.swift`, `SoloistRuntime.swift`, `SoloistMusicEngine.swift`), keeping each below 500 lines. `Kinrox` spawns `soloist` directly as its child `Process` (preserving direct `terminationStatus` observation for exit code 10 and stderr pipes) and attaches a small, zero-secret `KinroxSoloistHost` sidecar reaper that watches an inherited lifetime pipe and terminates the verified `soloist` PID if `Kinrox` dies via `SIGKILL`.

### Decisions and release gates

All gates start **NOT RUN / NOT APPROVED**, as applicable. Planning may finish while they remain open; product cutover may not. Record evidence and decisions here, preserving failed attempts. Proposed defaults below are not owner approvals.

| Gate | Evidence or decision required | Failure outcome |
|---|---|---|
| G0 — Secret transport | Prefer an upstream non-argv path. Otherwise obtain a scoped, explicit owner exception covering the Soloist child argv, after macOS exposure testing with a non-secret sentinel where possible. Also assess unauthenticated local socket access. | No real-key launch until resolved; never claim redaction fixes the exposure. |
| G1 — Standalone onboarding | Fresh Kinrox-owned profile; pair from Spotify on iPhone with Spotify.app absent. Test external web-player pairing separately only if supported. Quit the pairing client, restart Soloist, and test whether WebSocket `play(uri)` self-activates an inactive (`is_active == false`) session or needs a one-shot Web API device transfer. | Desktop-only pairing blocks this architecture under the current requirement. |
| G2 — Identity and queue correctness | Establish account binding (correlating Soloist's unique device name against `GET /v1/me/player/devices` for the authenticated Web API `userID`), command confirmation, `play`+`seek` for non-zero start positions, duplicates, EOF, final-item stop and takeover from captured traces. | Do not replace the production path with heuristics that silently play the wrong item. |
| G3 — Installation and lifecycle | Verify signer, arm64/minimum OS, download provenance, fresh/expired/update behavior, crash containment, sleep/wake and output changes. | Keep the engine unavailable; no desktop/browser fallback. |
| G4 — Performance and output | Real output-path evidence at Kinrox gain zero, local/LAN latency samples and 30-minute process metrics on Release builds. Owner accepts numerical budgets after measurements. | Report measured failure; do not declare responsiveness from fake tests or Linux figures. |
| G5 — Product and distribution | Figma states, consent/privacy in 30 locales, compatibility fixtures, own-key/download terms, signed app/host and device acceptance. | No release claim; publication remains a separately authorized task. |

Recommended owner choices: permit one-time phone pairing if G1 passes; prefer strict local queue semantics without `add_to_queue`; require Autoplay off for the first version only if G2 proves that sufficient; permit opt-in engine update downloads with activation only when stopped. No automatic acceptance of unexpected autoplay audio. No decision to permanently ban all alternative research is needed to implement the selected Soloist scope.

### S0 — Feasibility probe before production changes

Dependencies: G0 before any real-key launch. Create a later isolated probe under `Tools/SoloistProbe/` and retain sanitized traces/CSV under a timestamped task artifact directory. A future probe run is a separate implementation action; none is performed by this plan.

1. Create a new profile and cache owned by this task, both private. Never delete or reuse `~/Library/Application Support/soloist`, another app's profile, or unknown user files to obtain a clean test. Monitor `pgrep -x Spotify` throughout the run; retain the absence trace, not just a one-time check. Use Soloist initial volume zero and leave system volume unchanged.
2. Download the official Mac archive to staging; inspect archive entries, architecture, minimum OS (`otool -l` / `LC_BUILD_VERSION`) and dependencies. Record SHA-256, `codesign -dvvv`, `codesign --verify --strict --verbose=2`, `spctl -a -vv -t exec`, then verified `soloist --version`/`--help`. Resolve trusted Team ID from the actual signed distribution and independent publisher identity; do not trust a user issue or merely any Apple-signed executable.
3. Run with explicit private data/cache paths, a unique per-instance `--device-name`, finite cache limit (`--cache-size 200`) and loopback binding (`--ws 127.0.0.1:0`). Capture only sanitized arguments. Confirm `ws.addr`/`ws.port` belong to this process. Execute G1: fresh pairing, stored-session relaunch with phone/browser closed, cold start where `is_active == false` followed by WebSocket `play(uri)` (recording whether it self-activates or requires a one-shot Web API `PUT /v1/me/player` transfer), and account-binding verification via `GET /v1/me/player/devices`.
4. Trace initial authentication/snapshot, each transport command, `play(uri)` followed by `seek(position_ms)` for non-zero start offsets, `get_state`, same-URI reload, adjacent `[A#1, A#2]`, `[A#1, B, A#2]`, near-end pause/seek and genuine EOF. Test Autoplay both ways, backend shuffle/repeat settings and external takeover, including a different track selected on the same Soloist device.
5. Verify volume reaches the output path, not just JSON state. At gain zero record available output callbacks/frame counts without retaining audio. A playing event or a silent process tap alone does not prove decoded audio; if the closed binary exposes no adequate zero-gain evidence, leave G4 open and document a separate owner-approved verification method.
6. Exercise Wi-Fi loss, socket loss without process exit, default-output change, sleep/wake, ordinary quit, forced Kinrox termination (`SIGKILL`), reaper failure and relaunch. Measure any surviving Soloist lifetime. Inspect argv visibility without writing actual credentials to logs or copying them into tool output; any second-user test needs an existing authorized test account.

Exit: record exact build/hash, scenarios, traces, failed cases, measurements and G0–G4 status. A fake process/socket proves controller behavior only. If EOF or duplicate attribution cannot be made reliable, stop cutover and revise the design explicitly; do not silently switch to single-track mode or Spotify.app.

### S1 — Engine contract and known model defects

Files: `MusicEngine.swift`, `MusicViewModel.swift`, `MusicViewModel+Playback.swift`, `MusicViewModel+Availability.swift`, `DeckView.swift`, `PlayerCommands.swift`, `PlaybackCoordinator.swift`; extend `PlayerMacTests/FakeMusicEngine.swift`. Dependencies: S0 trace contract for final API; deterministic fake tests can proceed without credentials.

- Evolve `MusicEngine.swift` in-place: add `MusicEngineAvailability` (`notInstalled`, `downloading`, `needsKey`, `needsPairing`, `starting`, `ready`, `reconnecting`, `expired`, `externalTakeover`, `failed(String)`), change `MusicPlaybackSnapshot.volume` to `Double?` (nil when unknown; add `volumeKnown = false` on `MusicViewModel` and keep `"volume"` in `disallowedActions` until confirmed), qualify `MusicEngineEvent.ended(occurrenceID: UUID)` and add `.availability(MusicEngineAvailability)`.
- Simplify generation tracking from five overlapping IDs to three clear scopes: (1) engine instance lifetime (one `SoloistMusicEngine` per connected `SpotifyAccount` session), (2) `sessionEpoch: UInt64` in `SoloistRuntime` (incremented on each WebSocket connection / process start), and (3) `commandID: UInt64` + `occurrenceID: UUID?` in the serialized command worker. Use `ContinuousClock` internally; convert Soloist wall-clock anchors once, bounded for clock skew.
- Preserve completion-after-confirmation semantics. All waits have deadlines/cancellation and exactly one terminal result. A task cancelled after dispatch must reconcile or retire the command before another starts. Actor isolation alone does not serialize operations across suspension points; use an explicit command worker.
- Fix UI availability in `MusicViewModel+Availability.swift`, `DeckView.swift`, and `PlayerCommands.swift`: `DeckView.swift` currently checks only `model.allows(...)` and ignores `model.currentTrack != nil` and queue boundaries, leaving transport controls enabled on an empty queue. Define computed properties on `MusicViewModel` (`hasTrack`, `canPlayLibrary`, `canTogglePause`, `canStop`, `canSeek`, `canNext`, `canPrevious`, `canShuffle`, `canRepeat`, `canAdjustVolume`) and use `canPlayLibrary` in `CollectionHeader`/`TrackTable`/`MusicKeyboard` while binding deck/menu/NowPlaying/LAN transport controls to the queue-aware properties.
- Fix `MusicViewModel.receive(_:)` (`MusicViewModel+Playback.swift:20`): apply device-wide fields (`if let v = state.volume { volume = v; volumeKnown = true }`, `outputName = state.deviceName`, `disallowedActions = state.disallowedActions`) **before** `guard state.occurrenceID == queue.current?.id else { return }`, and call `notifyPlayback()` when device state changes so volume and availability update even when the queue is empty. Keep slider drafts separate from confirmed volume, roll back on failure, and accept external volume events. Coordinator retains source sequencing and one Now Playing owner; changing the visible mode alone never starts or pauses media.

| Existing adapter contract | Soloist implementation rule |
|---|---|
| `events` | Single ordered stream of confirmed snapshots, typed availability, `.ended(occurrenceID:)` and failures; never broadcast raw wire frames. |
| `canResume(queue)` | Synchronous check that the engine is in the same `sessionEpoch`, active on Soloist, and positioned on `queue.current?.id`. |
| `play(queue:position:)` | Require `let current = queue.current` (throw `emptyQueue` if nil), start/activate runtime if needed, load `current.track.uri`, seek if `position >= 1`, and confirm item/playback. |
| `setPaused`, `seek`, `setVolume` | Serialized in the command worker; await the matching observed predicate or typed failure/timeout. |
| `updateQueue` | No-op on the wire when `queue.current?.id` is unchanged (in `MusicQueue`, `editQueue` only mutates `upcoming`, `shuffled`, or `repeatMode`). |
| `stop`, `shutdown` | `stop` confirms pause and seeks to 0 when a track is loaded; `shutdown` cancels waiters, closes socket, terminates the child `Process` and awaits exit. Both are idempotent. |

Exit: regressions reproduce the current no-device, empty-queue and volume defects before the fix; fake-contract tests pass for unknown/confirmed volume, stale epochs, cancellation and availability. Preserve the demo path with deterministic explicit state.

### S2 — Verified installation, credentials and process ownership

New directory: `PlayerMac/PlayerMac/Music/Soloist/` with `SoloistInstaller.swift` and `SoloistProcessSupervisor.swift`; extend existing `PlayerMac/PlayerMac/Music/Spotify/SpotifyCredentialStore.swift` (currently 53 lines); add Kinrox-owned `PlayerMac/SoloistHost/main.c` as a separately signed native executable through `PlayerMac/project.yml`. Dependencies: G0/G3 evidence and S1 types.

- Install under `~/Library/Application Support/Kinrox/Engines/Soloist/<version>-<digest>/`; use separate account-scoped session storage and `~/Library/Caches/Kinrox/Soloist/<binding>/`. Proposed disk cache budget: 200 MB (`--cache-size 200`), distinct from RAM limits. Directories `0700`, private files `0600` where supported; exclude session/cache from backups (`NSURLIsExcludedFromBackupKey`). Extend `SpotifyCredentialStore` to store the Soloist API key under service `app.kinrox.spotify.soloist-key` using `AfterFirstUnlockThisDeviceOnly`; perform blocking file/signature work off MainActor.
- User-initiated download in `SoloistInstaller.swift` follows the official page to the Spotify CDN. Permit only HTTPS and reviewed redirect hosts. Bound archive/download size; reject traversal, escaping links and unexpected executable layouts. Verify Developer ID trust (`SecStaticCodeCheckValidity` against `anchor apple generic` and pinned Team ID), tested binary identity, `arm64` slice and `LC_BUILD_VERSION` minimum OS **before** executing `--version`. Never re-sign or patch Spotify's binary. Stage atomically, keep the active copy intact on failure, and activate only when stopped.
- Proposed expiry policy: warn/check 30 days before the 90-day build deadline, avoid request loops, and transition to `.expired` on exit code 10. Validate build timestamps and clock anomalies. Code 1 is a general failure, not proof of key revocation; do not delete credentials based on that code alone.
- **Direct parent-child process supervision + zero-secret sidecar reaper:** `SoloistProcessSupervisor` launches `soloist` directly via `Foundation.Process`, retaining direct ownership of `terminationHandler` and `terminationStatus` (immediately observing exit code 10 or crashes without a middleman proxy). The API key goes straight from Keychain in `Kinrox` to `soloist` argv under the G0 exception and never crosses an IPC pipe or helper. Immediately after launching `soloist`, `SoloistProcessSupervisor` spawns `KinroxSoloistHost` (`SoloistHost/main.c`), passing **only** an inherited lifetime pipe FD, `soloist`'s PID, start timestamp, and expected binary path (zero secrets). On `Kinrox` abnormal termination (`SIGKILL`), pipe EOF wakes `KinroxSoloistHost`, which verifies `proc_pidpath` and start time before sending `SIGTERM` → 500 ms grace → `SIGKILL`.
- Hold an advisory `flock` on the profile directory. Recovery verifies recorded PID, owner, process start identity and executable path (`proc_pidpath`) before touching a surviving process; `soloist.pid` alone is not authority because PIDs can be reused. Prepare the engine after opt-in setup when Music mode is used or Play is requested; startup stays paused/idle and never resumes stored audio or seizes another device automatically.
- Cap and sanitize diagnostics before persistence, including secrets split across read chunks; disable raw verbose logs by default. Use an asynchronous bounded pipe drain so stderr cannot stall playback. Redaction cannot guarantee that OS crash reports never contain argv; disclose that residual risk in G0.

Exit: malicious archive/signature fixtures rejected; interrupted update leaves a runnable verified installation; wrong/stale PID never killed; socket-start failure times out; normal quit and forced `SIGKILL` of `Kinrox` reap `soloist` within 1 second. No Soloist binary or secret enters the repository or app bundle.

### S3 — WebSocket runtime, correlation and observation

Files under `PlayerMac/PlayerMac/Music/Soloist/`: `SoloistProtocol.swift`, `SoloistStateReducer.swift`, `SoloistRuntime.swift`, `SoloistMusicEngine.swift`; dedicated tests with recorded sanitized frames. Dependencies: S0 protocol traces and S2 supervised startup.

- Connect via `URLSessionWebSocketTask` using owned `ws.addr`/`ws.port` written after the current launch; enforce IPv4 loopback (`127.0.0.1`), valid port, no proxy, and no redirects. Increment `sessionEpoch` on every new socket connection. On connect, await `auth_state` and initial `playback_state` (or request `get_state`), and ensure Soloist's internal `shuffle` (`false`) and `repeat` (`"off"`) are disabled so `MusicQueue` owns progression.
- Serialize mutating commands through one explicit command worker in `SoloistRuntime` and register waiters before send. **Distinguish dispatch timeout from observation timeout:** if `command_result` is not received within the dispatch deadline (2 s on loopback), the socket/daemon is wedged — close and reconnect the WebSocket (`sessionEpoch &+= 1`). If `command_result` **was** received (so no `command_result` remains in flight on the wire) and only the state predicate timed out (e.g., slow stream buffering), keep the healthy socket open and reconcile via `get_state` (or `pause` if cancelling an unconfirmed `play`).
- Because Soloist's WebSocket `play` command accepts `uri` without `position_ms`, when `play(queue:position:)` is called with `position >= 1`, `SoloistRuntime` awaits `track_changed`/`playback_state` confirming the expected URI (or relinked URI) in the current `sessionEpoch`, then dispatches `seek(position_ms)` and confirms position before completing `play`.
- **Single ordered event stream with in-place state coalescing:** Feed `MusicEngine.events` from one ordered buffer in `SoloistRuntime` where a new `.state(snapshot)` overwrites an unconsumed trailing `.state` entry (coalescing rapid `position_sync` frames), while `.ended(occurrenceID)`, `.availability`, and `.failure` remain in exact causal order and are never dropped. Bound message bytes and the redacted diagnostic ring (proposed 256 KiB).
- Apply confirmed volume independently of track context; emit immutable snapshots to MainActor. Treat `device_changed` (`is_active: false` while playing) or an unrequested URI change as `.externalTakeover`: mark `paused = true`, retain `MusicQueue`, and never overwrite external playback automatically. Implement `stop` as confirmed `pause` plus `seek(0)` when an item is loaded. Wake reconnects in a paused state.

Exit: unit tests on `SoloistStateReducer` and `SoloistRuntime` cover response/event reordering, dispatch vs. observation timeout, `play` with `position >= 1`, adjacent duplicate URIs, takeover, reconnection, and 10,000 `position_sync` events/s without dropping `.ended`.

### S4 — Local queue and application cutover

Files: `Packages/KinroxMusic/Sources/MusicCore/MusicQueue.swift`, `MusicViewModel+Playback.swift`, `PlayerSession.swift`, `SpotifyLibraryStore.swift`; retire `SpotifyConnectMusicEngine*.swift` only after replacement coverage passes. Dependencies: S3 and G2.

- Fix seeded RNG in `MusicQueue.next`: add `next<R: RandomNumberGenerator>(automatically: Bool = false, using random: inout R) -> MusicQueueItem?` in `MusicQueue.swift:105` so `repeatMode == .all` reshuffling uses the injected generator instead of unseeded `source.shuffle()`. Local Next/Previous selects an occurrence and loads it; raw Soloist `skip_next` is not used.
- Fix final-item EOF and unify Repeat-One in `MusicViewModel.advance(automatically:)` (`MusicViewModel+Playback.swift:107`):
  - Verify `occurrenceID == queue.current?.id` on `.ended(let occurrenceID)`. Emit `.ended(occurrenceID)` from `SoloistStateReducer` at most once per `(sessionEpoch, commandID, occurrenceID)` cycle when S0 EOF criteria hold; suppress during explicit `pause`, `seek`, `stop`, takeover, and reconnect.
  - When `next.next(automatically: true)` returns an item (including `repeatMode == .one`, which already returns `current`, and `repeatMode == .all`), `startQueue(next)` loads it at position `0` via `play(queue: next, position: 0)`.
  - When `next.next(automatically: true)` returns `nil` (final item finished with `repeatMode == .off`), explicitly set `paused = true`, `position = 0`, call `try? await musicEngine?.stop()`, and `notifyPlayback()` instead of silently returning.
- Revised execution direction (owner instruction 2026-11-03): one `--single-track` process per queue occurrence, no backend prequeue or gapless promise. Initial gain is zero until the requested position is confirmed, then restore only confirmed user gain. Short pause/resume may reuse the process; park long pauses by retaining confirmed position and terminating the owned process. Resume launches a new process and seeks before restoring gain. Intentional termination never emits EOF; exit 0 additionally requires the expected occurrence's natural boundary, with nonzero exits and takeover handled separately. Validate restore latency, long pauses, full natural EOF and duplicate transitions before cutover.
- Remove helper-playlist creation/mirroring from playback. Preserve stored `app.kinrox.spotify.queue.<clientID>.<userID>` IDs as read-only migration tombstones passed into `SpotifyLibraryStore.excludeQueuePlaylist(_:)` at store creation in `PlayerSession.swift`, so bulk favorite/unlike mutations never touch legacy `Kinrox Queue` playlists. Never delete or rewrite legacy Spotify playlists.
- Retain `user-read-playback-state` (for account-binding device verification) and retain `user-modify-playback-state` until G1/S0 proves WebSocket `play(uri)` never needs a one-shot Web API device activation transfer; if S0 proves pure WebSocket activation, drop `user-modify-playback-state` on new authorizations.

Exit: queue/favorite/cache regression suites pass; request recorder proves zero helper-playlist writes and zero polling during Soloist playback; final-item EOF, repeat-one, and repeat-all seeded shuffle tests pass; video/music pause serialization remains intact.

### S5 — Account lifecycle and native setup UI

Files: `SpotifyAccount.swift`, `SpotifyCredentialStore.swift`, `SpotifyDocuments.swift`, `SpotifyStatus.swift`, `PlayerSession.swift`, `UI/SpotifySettingsSection.swift`, `UI/DeckView.swift`, `UI/MusicServiceStatus.swift`, `Shared/MusicSlider.swift`, and localization catalogs. Dependencies: S1–S4; design new setup/recovery/unknown-volume states in the existing Figma file before UI implementation.

- Setup sequence: existing Web API consent/PKCE → Soloist API key entry and official binary download/verification → phone Connect pairing → account-binding verification → ready. Owner clarification 2026-11-03: the key-entry window must show a clickable `https://developer.spotify.com/dashboard/soloist` link and explicitly state that Spotify Premium is required. Keep engine readiness separate from Web API token refresh so a transient Web API expiry does not interrupt active local playback. Never collect a Spotify password or embed an authentication browser.
- **Deterministic account-binding check:** When Soloist reports `auth_state` logged in with its unique per-instance `--device-name`, query `GET /v1/me/player/devices` via the authenticated `SpotifyClient` (`userID`). Because Spotify Connect device visibility is account-scoped, finding that instance device name in `/v1/me/player/devices` confirms Soloist is paired to the same Spotify account as the Web API library; if absent after pairing, surface a clear wrong-account state and require re-pairing (`--pair`).
- On account/Client ID change or `Disconnect`, first settle `PlaybackCoordinator` and shut down `SoloistMusicEngine` (stopping the exact owned process), then delete the Keychain refresh token, Keychain Soloist API key, SQLite cache, and owned Soloist session/cache directories. Preserve remote playlists and non-secret `Kinrox Queue` exclusion tombstones.
- Keep installation, revoked-key, pairing, expiry, network loss and takeover recovery distinct. When `!model.volumeKnown`, disable the volume `MusicSlider` and display `"—"` instead of `0`; on failed volume/seek commits, `MusicSlider` reverts to the last confirmed value.
- Update versioned `Resources/Spotify/SpotifyConnection.*.json`, all 30 app locales and generated public documents via existing generators to explain the official Soloist download, disk session, G0 argv exception (if accepted), 90-day build lifetime and Disconnect cleanup.

Exit: approved Figma states implemented, localization/document checks pass, expired Web API token does not corrupt Soloist session, wrong-account/re-pair/disconnect tests pass, and no token/key/path/audio is exposed to iPhone.

### S6 — LAN protocol and iPhone compatibility

Files: `Packages/RemoteProtocol/Sources/RemoteProtocol/MusicState.swift`, `Message+MusicValidation.swift`, Mac `RemoteMusicBridge.swift`, iOS `RemoteAppModel+Music.swift` and `MusicRemoteView.swift`. Dependencies: S1/S4 state semantics.

- **Preserve protocol v1 and handshake compatibility (`Version.current == 1`):** Do **not** bump the wire envelope or `HandshakeTranscript` to v2. Follow `AGENTS.md` §6.3 (additive v1 optional fields, as used for Screensaver and Music):
  - Add optional `public var volumeKnown: Bool?` to `MusicState` (default `nil`, validated in `Message+MusicValidation.swift`).
  - When Mac music volume is unknown (`!music.volumeKnown`), `RemoteMusicBridge` sets `PlayerState.volume = 0` (satisfying v1 `(0...100)` validation), sets `music.volumeKnown = false`, and includes `"volume"` in `music.disallowedActions`. Un-updated v1 iPhones already check `!store.musicAllows("volume")` (`MusicRemoteView.swift:37`) and automatically disable the volume slider; updated iPhones additionally render `"—"` instead of `0` when `music?.volumeKnown == false`.
- **Engine availability over v1:** When `SoloistMusicEngine` is not `.ready`, `RemoteMusicBridge` populates `music.disallowedActions` with the unavailable transport actions and sets `music.status` to the localized recovery message. Both existing and updated iPhones automatically disable transport buttons and display `music.status` in the deck without protocol version branching.
- **Preserve non-blocking `ack` + confirmed `state` push:** Keep `RemoteServer` `ack` semantics (command accepted/validated on arrival, followed by broadcast of confirmed `PlayerState` when the engine settles or `music.status` on error). This preserves 10 Hz `setVolume` coalescing on iPhone (`RemoteAppModel+Commands.swift:149`) and avoids head-of-line RPC deadlocks.

Exit: v1 codec/handshake vectors remain 100% compatible; old-iPhone/new-Mac and new-iPhone/old-Mac tests pass; unknown volume, engine recovery states, and whitelist serialization checks pass; physical-iPhone controls verified.

### S7 — Measurements, packaging and acceptance

Dependencies: S0–S6; this stage closes remaining gates before release. Files: `PlayerMac/project.yml`, `Scripts/build-release.sh`, `Scripts/release-source-lock.json`, release-script tests, `docs/runbooks/RUNBOOK-RELEASE.md`; create a dedicated Soloist verification runbook when measurements exist. Include only the Kinrox-owned `KinroxSoloistHost` reaper in the app, sign it with Hardened Runtime before signing/notarizing the app, and add no speculative entitlements. Assert absence of the Spotify executable/archive by artifact identity.

Keep Soloist download policy separate from GPL dependency-source entries in `release-source-lock.json`; update consumers/tests if the schema changes. Record expected signer, host, tested version/hash, minimum OS and expiry policy without inventing a pin. Scan artifacts/log fixtures for seeded secret leaks. Record app/host size increase, external installation/cache size and dependencies. Preserve existing portable libmpv release checks and minimum-OS metadata validation; the owner permanently excluded a separate macOS 14 execution test on 2026-11-03.

| Measurement | Method and proposed acceptance target — long-pause, Soloist memory/CPU and bounded short pause approved |
|---|---|
| Physical footprint | Kinrox, host and Soloist separately via `footprint`/`vmmap` or validated rusage probes; Owner approved Soloist ≤120 MiB and ≤3% of one core on 2026-11-03; Kinrox+host increment ≤25 MB remains proposed; report RSS separately and avoid double-counting shared memory. |
| Sustained trend | 30 minutes, at least 10 tracks, samples every 10 seconds; no missing transitions; footprint growth ≤10% after minute 5. Report both trend and peak/cache plateau. |
| Startup | At least 30 cold/warm samples per declared cache condition; separate spawn, authentication, acceptance, confirmed playing and actual output evidence; Owner accepted cold p95 ≤4 s and warm p95 ≤3 s on 2026-11-03. |
| Commands | Owner accepts 2–3 s recovery after a long pause for v1 (2026-11-03); measured warm p50 1.60 s / p95 2.14 s. Owner initially accepted Next p95 ≤3 s, then explicitly approved ≤3.2 s for v1 on 2026-11-03 after the 200-command physical-iPhone run (measured p95 3.095 s). 200 valid samples each, p50/p95/max, failures separately; proposed pause/resume/volume ≤100/250 ms p50/p95 and seek p95 ≤1.5 s. Measure acceptance and observed effect independently. |
| CPU/wakeups | Playing and paused, all processes; Soloist ≤3% of one core approved; owner accepts observed ≈21 interrupt wakeups/s during a short pause, followed by process termination after 20 s (superseding the proposed 5/s short-pause target). Use available Instruments/powermetrics with documented privileges. |
| UI and LAN | No blocking I/O on MainActor; investigate >16 ms stalls. Measure iPhone-to-confirmed-iPhone latency separately from Mac engine latency. |

Record hardware/OS, Release configuration, network/quality, cache state, tool versions and raw sanitized samples. Instrument app/process cost without recording Spotify audio or constructing listening profiles; assess applicable policy before any public service benchmark. External RAM/latency anecdotes are not baselines. If zero-gain output evidence is insufficient, explicitly keep the audio gate incomplete. No budget may be relaxed silently to fit results.

Run relevant package and app tests (`swift test --package-path Packages/KinroxMusic`, `swift test --package-path Packages/RemoteProtocol`, PlayerMac and RemoteiOS Xcode test schemes), strict Swift lint, localization/site-generation checks, release-script tests and `git diff --check`. Retain build/test artifacts; never clean unrelated changes. Full live acceptance: cold start while Spotify.app remains absent; track load, pause/resume, seek, volume, manual/natural Next, local keyboard/media/Now Playing and physical LAN remote; repeat after reboot, sleep, output change and network loss. Also verify normal/forced quit, account change, takeover and expired-build recovery. Record actual results before any release claim.

### Regression matrix and execution order

| Layer | Required scenarios |
|---|---|
| Existing defect baseline | Real HTTP fixtures expose `SpotifyError.noDevice`, empty-queue deck availability, zero-as-unknown volume and helper-context publication loss. A fake Soloist cannot prove these disappear in live audio. |
| Reducer/queue | Adjacent and separated duplicate URIs, relinked track, stale `sessionEpoch`/`commandID`, pause/seek near EOF, repeat-one vs explicit Next, repeat-all seeded shuffle, final-item EOF stop, and wrong-URI takeover. |
| Socket/process | Dispatch timeout (reconnect) vs observation timeout (`get_state` on same socket), `play` with `position >= 1`, in-place `.state` coalescing under 10,000 `position_sync` events/s without losing `.ended`, code 1/10, stale port/PID, and `SIGKILL` parent-death reaping. |
| Installation/lifecycle | Wrong signer/architecture, archive escape, interrupted update, expiry, wrong-account detection via `/v1/me/player/devices`, repeated Disconnect and partial cleanup; legacy `Kinrox Queue` playlists untouched. |
| Product/LAN | Unknown/external/failed volume (`volumeKnown`), disabled empty-queue deck with playable library selection, video/music transitions without double audio, additive v1 iPhone compatibility, no secrets, existing library/cache/favorites/Undo preserved. |
| Live-only | Native output at zero gain with documented evidence limits, standalone phone pairing/restart, cold inactive activation, natural transitions, minimum OS, physical iPhone, 30-minute resources and command latency. |

Execution order: **S0 and owner decisions → S1 → S2 → S3 → S4 → S5/S6 → S7**. Design/consent drafts and deterministic tests may proceed independently of credentials; production cutover waits for G0–G4. Each stage must leave buildable code, focused regression evidence and an updated gate record. No branch, commit, worktree, independent review, release or deployment is implied by this plan.

Planning handoff: repository interfaces and official sources inspected; plan refined in the existing research brief; source code and account state unchanged. Local Markdown links resolve, code fences are balanced, explicit whitespace checks and `git diff --check` pass, and the file remains below 500 lines. Application tests were not run for this documentation-only task. All implementation stages and live gates remain pending; no release or deployment was performed.

### Execution record — 2026-11-02

The preceding handoff describes planning, not the current execution. Owner requested execution of this plan. Baseline `0b6291e`; pre-existing `AGENTS.md` edits and this untracked document are preserved. Reproducible probe sources: [Tools/SoloistProbe](../../Tools/SoloistProbe/). Private local artifacts: `build/soloist-probe/20261102T094052Z/`; no distribution binary is tracked or bundled.

| Check | Actual result |
|---|---|
| Machine | MacBookPro18,2, arm64, 32 GiB RAM; macOS 26.5.2 (25F84). |
| Official distribution | Downloaded over HTTPS from the linked Spotify CDN; archive 10,656,090 bytes, SHA-256 `779e849d1fb2da55623a4fef4079c0cf223f0f0afc1d72245ca42585dcf3026e`. |
| Binary identity | 25,619,440 bytes; SHA-256 `2a4f1b9474b8799c8fe79376e90ae4976afe51e169918497859305baa2df8d40`; `com.spotify.soloist`, Spotify Team `2FNC3A47ZF`, Hardened Runtime. Explicit Apple-anchor/team/identifier requirement passed. Installed Spotify.app independently verifies with the same publisher/team. |
| Version / compatibility | Executed verified `--version` / `--help`: `1.3.10.33`, build `1793599271 (20261102) (g19412df6ea) (macos/aarch64)`. `LC_BUILD_VERSION minos 13.0`; system-library dependencies only. macOS 14 runtime test NOT RUN and permanently excluded by owner decision 2026-11-03; this is not a claim of tested runtime compatibility. |
| Gatekeeper | `spctl -a -vv -t exec` returned 3 (“valid but does not seem to be an app”). Later strict Apple-anchor/team/identifier verification **with `--check-notarization` passed**. A task-owned copy with a newly added quarantine attribute executed verified `--version` successfully; quarantine remained present. The native installer also completed a fresh CDN download, verification, quarantine and version check in 4.33 s; the CDN returned newer 1.3.10.36, which subsequently passed native-driver and ten-distinct-track sustained checks; full product acceptance remains open. No re-signing, quarantine removal or OS security changes. Evidence: `20261103T045157Z/notarization-check.log`, `quarantine-check/`, `download-live.log`; fresh installation `20261103T052700Z-download/`. |
| G0 sentinel | Fixed invalid key, fresh private profile/cache, gain zero, 200 MB cache cap, owned `127.0.0.1` listener. Same-user `ps` sees argv. WebSocket HTTP upgrade accepts `Origin: https://example.invalid` without credentials. Real key never accessed. Child terminated normally; exit 0. Cross-user visibility NOT RUN. |
| Standalone boundary | Spotify.app was already running throughout the sentinel probe. This is explicitly not G1 or an audio test. No Spotify.app launch or system-volume change. |
| Updated upstream contract | The [current WebSocket reference](https://developer.spotify.com/documentation/soloist/reference/websocket-api) additionally documents `activate` / `deactivate`. Add explicit WebSocket activation to G1 before considering Web API transfer. Neither command is live-validated yet. |
| Red regressions | `model-red.log`: empty-queue Seek/Stop dispatch and lost device-volume/output notification failed (4 assertions). `http-red.log`: confirmed volume outside helper context failed (1 assertion); synthetic real-HTTP Play/Volume tests confirmed `SpotifyError.noDevice`. Initial method-only Xcode filters selected no HTTP tests; the full serialized HTTP suite reproduced the failure. |
| S1 foundations | Optional snapshot volume; confirmed `volumeKnown`; typed availability; occurrence-qualified EOF; queue-aware model, deck, menus, keyboard, Now Playing and v1 LAN guards; device fields published independently of track matching. Late retired events/shutdown cannot overwrite the replacement. Final EOF stops/rewinds; repeat modes reload at zero. Existing Connect adapter retained and its lost-volume publication fixed. The independent S4 seeded-RNG prerequisite is also implemented: Repeat All uses the supplied generator, with three-cycle repeatability, duplicate occurrence, removal and manual-priority coverage. |
| Green verification | Full Mac: 228 tests / 45 suites (`mac-green.log`); after retirement/LAN additions, focused 15 tests / 3 suites passed (`model-final.log`). Music package now 37 tests / 7 suites, including seeded Repeat All (red compile failure first proved the planned injected-RNG overload was missing). Protocol 126 tests; probe Python 9 tests; Release trace/audition guard 2 tests. Strict repository Swift lint and changed-file lint pass; `git diff --check` passes; changed source files remain below 500 lines. |
| G1 live probe — 2026-11-03 | Phone pairing passed after moving iPhone to the Mac's Wi-Fi. With the phone app then explicitly closed and Mac Spotify continuously absent, owned-child restart restored login in 1,022 ms; the inactive session became active using only WebSocket `play(uri)` (233 ms to the probe's observed predicate), with no Web API transfer. A subsequent fresh test-host launch also restored the Keychain key/session without a prompt. Debug harness timing is exploratory, not Release product acceptance. Key dialog includes the official key-page button and Premium requirement. |
| G2 live evidence / limitation | Same-account device check, `play` + seek, pause/resume, same-URI reset and A/A/B/A loads confirmed. Full 323-second URI loads still added `autoplay` recommendations after owner-confirmed Autoplay off on iPhone and native restart. Persistent-mode cutover is rejected. `--single-track` accepts short pause/resume/seek and exits 0 near EOF, but long pauses exit 1 after about 60 seconds. Owner subsequently instructed execution of the proposed per-occurrence process with saved-position recovery; validation is in progress, not product acceptance. Native reducer tests cover stale exits, duplicate occurrence identity, early exit, intentional stop, takeover and bounded input. [Probe evidence](../../Tools/SoloistProbe/README.md); raw URI/name/account data is not retained. |
| Native implementation / remaining work | S2 installer/archive validation, native process supervisor, signed C reaper, S3 reducer/serialized runtime/adapter and S6 optional `volumeKnown` are implemented. Native setup is connected to `PlayerSession` behind the local acceptance gate. Figma approved by owner 2026-11-03: key setup `136:3536`, unknown volume `136:3545` / `136:3556`. Native setup/account binding and owned storage are implemented; app wiring is behind the local `KINROX_SOLOIST_INTEGRATION=1` gate pending acceptance. S5 UI strings, versioned documents and public pages now cover all 30 locales. S4 default cutover and full S7 acceptance remain pending. Both 1.3.10.33 and 1.3.10.36 passed the real native-driver restore/duplicate/EOF check; a Release ten-distinct-track soak on 1.3.10.36 passed in `20261103T054722Z-native-soak/`: 1853.62 s, 1685 absence samples, 24.73–27.30 MiB, 0.95–1.06% CPU, +1.80% post-warmup footprint trend. [Current evidence and remaining checks](../runbooks/SOLOIST-VERIFICATION.md). Full natural single-track EOF passed; a timer-teardown/Play race was reproduced (overlap and stale paused state), then fixed and verified. The corrected Release command run (`20261103T064000Z-recovery-benchmark/`) passed 200 samples each with no failures: Next p95 2.28 s, pause 32.75 ms, resume 22.23 ms, seek 87.83 ms and idempotent zero-volume 22.62 ms; four paused-device deactivations recovered on explicit Play, maximum resume 1.96 s. Prior failures at samples 69 and 20 remain recorded. Cold/warm startup p95 2.93/2.23 s and the owner-approved 4/3 s limits are documented in the runbook. |

At the 2026-11-02 handoff, G0 owner approval was pending. On 2026-11-03 the owner explicitly approved passing the personal key through Soloist argv and confirmed readiness for iPhone pairing; do not request that permission again. A test-bundle-only native secure field stores the key in Data Protection Keychain (`app.kinrox.spotify.soloist-key`, account `feasibility-probe-v1`). The live probe suppresses raw child output, uses a zero-secret parent-death reaper, and records only whitelisted protocol fields without account IDs, track URIs/names, credentials or error payloads. New private artifacts: `build/soloist-probe/20261103T005237Z/`.

Current execution status, 2026-11-03: G0 is explicitly approved; native standalone onboarding, same-account binding, per-occurrence queue playback, duplicates, natural EOF and 30-minute resource evidence are recorded in the [verification runbook](../runbooks/SOLOIST-VERIFICATION.md). Owner confirmed hearing the latest native app with Spotify.app fully closed. The reported video-open error was reproduced and fixed; real MP4/MKV frames and time advancement pass at zero gain. Native sleep handling now preserves position and requires explicit Play after wake; actual sleep is deferred at the owner's request, and system reboot has not been exercised. Bluetooth → built-in → Bluetooth recovery and a 25.67-second Wi-Fi interruption/reconnection passed within the documented observation limits. Helper-death and child-SIGKILL recovery failures were reproduced and fixed; the live helper-death check stops Soloist in 331.26 ms and crashed endpoint files are preserved safely. Full Mac verification passed 276 tests / 60 suites before the final fault-path changes, followed by 22 focused tests / three suites, including disconnected-socket recovery and stale-disconnect isolation. Pure runtime and additive v1 protocol tests, all 30 locales, approved Figma states, release-helper checks and prior package/script evidence remain recorded; no branch, commit, release or deployment was performed. Parallel signature verification, Keychain reading and old-process teardown reduced unnecessary startup waits without weakening verification or overlapping audio processes. The final physical-iPhone Release series passed 1003 commands in 503.73 seconds with zero failures: 200 samples each, Next p50/p95/max 2.100/3.095/4.066 seconds; pause/resume/seek p95 159/167/208 ms. The owner explicitly accepted Next p95 ≤3.2 seconds for v1 on 2026-11-03 after reviewing the measured 3.095 seconds; the Next latency criterion is closed. The owner subsequently waived the remaining physical sleep/reboot checks and explicitly authorized release. S4 default cutover is now implemented: Soloist is the only production engine, legacy queue IDs are read-only exclusions and new authorizations omit playback-write permission. G3 is accepted with the documented physical sleep/reboot waiver; these scenarios are not reported as tested. Final default-cutover verification passed 280 Mac tests / 61 suites with portable release libraries, 37 Music tests and 52 script tests. S7/G5 packaging is complete: Mac 0.5.0 build 9, both app and DMG notarized, mounted signature/library/runtime-boundary/startup checks passed. The owner then requested no commit and review later; all changes remain unstaged and uncommitted, with no tag, release publication or website deployment. The prepared DMG and signed appcast are retained in dist/0.5.0-build9/. This document remains in the research root awaiting review and publication.
