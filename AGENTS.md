# Kinrox — Master Project Specification

> This document is the source of truth for any agent or developer. Read it completely before beginning work.
> Documentation, specifications, code comments, identifiers, diagnostics, and source keys remain English. User-facing localization resources may contain translations, authorized by the owner on 2026-10-27.
>
> **Critical requirements — mandatory owner decisions, 2026-11-02:**
> - **Spotify playback must work with Spotify.app fully terminated.** Kinrox must start and continue playback, pause/resume, seek, skip tracks, and change volume without a running Spotify.app process. Closing only Spotify's window or keeping its process hidden does not meet this requirement.
> - **Never use WebView anywhere in Kinrox.** This applies to both applications and all features, including authentication and playback. Embedded `WKWebView`, hidden WebViews, and embedded browser runtimes used for UI or audio playback are prohibited.
> - **Keep the native Swift/SwiftUI application.** Rust is not required; a native playback dependency may use another language, provided it satisfies the requirements above.
> - **Spotify must be responsive and use little memory.** Measure command latency and memory during startup, playback, pause, and sustained use before claiming the replacement meets this requirement; Owner accepted Soloist ≤120 MiB physical footprint, ≤3% of one core, and approximately 21 interrupt wakeups/s during a short pause with process termination after 20 seconds (2026-11-03). Long-pause recovery of 2–3 seconds, cold startup p95 ≤4 seconds, warm startup ≤3 seconds and Next ≤3.2 seconds are accepted.
>
> **Owner decision, 2026-11-03:** Release authorized with the remaining physical sleep/reboot checks waived (not passed). Do not perform or request a separate macOS 14 runtime test. Continue checking minimum-OS metadata and build deployment targets; actual runtime verification is limited to the macOS version tested.
>
> These requirements supersede earlier decisions that require Spotify.app or permit an embedded web player. The historical Connect-only releases described below do **not** establish standalone acceptance. The default production path now uses separately downloaded Soloist; live evidence and accepted limits are in [Soloist Verification](docs/runbooks/SOLOIST-VERIFICATION.md).
>
> **Status:** M1 implemented 2026-10-25: libmpv + OpenGL, opening via ⌘O, playback of MP4/MKV, events and clean teardown. MPVKit placed inside PlayerMac with bridging header per owner confirmation. Checks and limitations — [M1 Report](docs/runbooks/M1-VERIFICATION.md).
> M2 implemented 2026-10-26 in design from Figma: controls panel, shortcuts, fullscreen, drag-and-drop, menus, recent files, folder playlist and auto-advance. Remote screens (M5) built in advance on demo data, without network; server and protocol — M4.
> M3 implemented 2026-10-26: MediaPlayer system commands, "Now Playing", artwork, and teardown cleanup. Automated tests and manual limits — [M3 Report](docs/runbooks/M3-VERIFICATION.md).
> M4.1 implemented 2026-10-26 and handed off for review: message models, JSON codec, version negotiation, and reference JSON fixtures. Checks — [M4.1 Report](docs/runbooks/M4.1-VERIFICATION.md).
> M4.2 implemented 2026-10-26 after dedicated specification approval (§6.5.1): CryptoKit, handshake state machines, protected frames, and independent test vectors. Checks — [M4.2 Report](docs/runbooks/M4.2-VERIFICATION.md).
> M4.3 implemented 2026-10-26 after M4.2 review: Bonjour, Network.framework WebSocket, secure exchange, heartbeat, and local subnet enforcement. Player integration — M4.4; [M4.3 Report](docs/runbooks/M4.3-VERIFICATION.md).
> M4.4 implemented 2026-10-27: server connected to player, remote preferences and real PIN, tokens in Data Protection Keychain. Team signing with macOS profile configured, pairing and revocation verified. Results and limitations — [M4.4 Report](docs/runbooks/M4.4-VERIFICATION.md). M4 accepted by owner task assignment for M5 on 2026-10-27; transition authorized.
> M4 completed in scope M4.1–M4.4. By owner decision 2026-10-27 `kinrox-cli` (former M4.5) moved to [a separate optional task](docs/TODO/05-kinrox-cli.md); its absence does not block M6 or app release.
> M5 implemented 2026-10-27: real remote, Bonjour, Keychain, control, and reconnection. Automated tests passed; owner confirmed manual checklist of Mac + physical iPhone: "Double-checked everything, everything works." Results and remaining limitations — [M5 Report](docs/runbooks/M5-VERIFICATION.md).
> M6 release workflow implemented 2026-10-28: pinned portable libmpv dependencies, Developer ID export, library signing, notarization, stapling, DMG, dependency sources, and checksums. First Mac version: 0.1.0, Apple Silicon, macOS 14+. Procedure and validation boundaries — [release runbook](docs/runbooks/RUNBOOK-RELEASE.md), [release notes](docs/releases/0.1.0.md). iPhone App Store publication is separate.
> Mac track selection implemented 2026-10-29 after owner approval of Figma page 04: audio/subtitle selectors, recursive external-track discovery, search scope, and folder preferences. Included in Mac release 0.2.0, build 4, requested by the owner on 2026-10-29. Checks — [Tracks Verification](docs/runbooks/TRACKS-VERIFICATION.md); [release notes](docs/releases/0.2.0.md).
> Mac update reminders implemented 2026-10-29 after owner approval of Figma page 05: Sparkle 2 with gentle reminders — welcome banner, paused-player pill, and "Check for Updates…" with a version badge; Sparkle's standard windows download and install. The HTTPS appcast is an approved exception to principle 4. Released in Mac 0.3.0 (build 5) on 2026-10-30; users of earlier versions install this first checker build manually once. Checks — [Updates Verification](docs/runbooks/UPDATES-VERIFICATION.md).
> Tasks for contributors (M3, M4, localization, updates) — in [docs/TODO](docs/TODO/).
> Matrix screensaver implemented 2026-10-29 after owner approval of Figma page 07: Mac Screensaver → Matrix, animated falling code, pause before activation, Esc exit, and iPhone start/stop controls. The exit hint appears once for 3 seconds per activation. Released in Mac 0.3.0 (build 5); checks — [Screensaver Verification](docs/runbooks/SCREENSAVER-VERIFICATION.md).
> Music mode v2 included in Mac 0.4.0 (build 6), release authorized 2026-11-01: Spotify library, independent favorites with undo, private Kinrox Queue playback, Mac three-column UI and LAN iPhone controls. Owner approved own Client ID, Mac-only Spotify requests, official Connect playback, attribution and inline recovery states; physical iPhone check confirmed working. Evidence and limits — [Music Verification](docs/runbooks/MUSIC-VERIFICATION.md).
> Mac 0.4.1 (build 7) released 2026-11-01 at the owner's request: superseded Spotify poll responses no longer overwrite completed commands or stop polling, and fullscreen video hides the mode picker. Signed/notarized app and DMG, automated checks, and the interactive verification limitation are documented in the [release notes](docs/releases/0.4.1.md). SQLite and latency optimization were implemented on 2026-11-02; see [performance verification](docs/runbooks/SPOTIFY-PERFORMANCE-VERIFICATION.md).
> Mac 0.4.2 (build 8) released at the owner's request on 2026-11-02: welcome-screen overflow fix plus the committed Spotify metadata-cache and playback-latency improvements. Signed/notarized app and DMG, portable-library tests and interactive MP4/MKV checks passed; see [release notes](docs/releases/0.4.2.md).
> Mac 0.5.0 (build 10) released at the owner's request on 2026-11-04: native standalone Spotify via separately downloaded Soloist, local queue, setup/recovery and 30-language documents. Signed/notarized app and DMG; source tag `v0.5.0`. Checks and accepted limitations — [release notes](docs/releases/0.5.0.md) and [Soloist Verification](docs/runbooks/SOLOIST-VERIFICATION.md).
> Mac 0.5.1 (build 11) released at the owner's request on 2026-11-04: default audible Soloist volume with persistence, Spotify setup/consent status recovery, cached queue playlist filtering, and titlebar traffic-light hover stability. Signed/notarized app and DMG; source tag `v0.5.1`; see [release notes](docs/releases/0.5.1.md).
> Mac 0.5.2 (build 12) released at the owner's request on 2026-11-04: Music CPU and memory optimizations, Added date column and per-collection track sorting, artist/album preview popovers and navigation, persisted browsing state, and optimistic favorite updates. Signed/notarized app and DMG; source tag `v0.5.2`; see [release notes](docs/releases/0.5.2.md).
> Mac 0.5.3 (build 13) and iPhone Remote 0.2.1 (build 3, TestFlight) released at the owner's request on 2026-11-04: startup Soloist transport activation after cached library restore, natural EOF vs. near-end pause/seek handling, and LAN remote state consistency across mode switches and window closure. Signed/notarized Mac app and DMG; source tag `v0.5.3`; see [release notes](docs/releases/0.5.3.md).
> Mac 0.5.4 (build 14) released at the owner's request on 2026-11-07: uninterrupted long Spotify album playback (broadened terminal-buffering and boundary detection, exit-vs-disconnect race prevention, startup/resume reconciliation guards, macOS playback activity assertion, and automatic skipping of restricted tracks). Signed/notarized Mac app and DMG; source tag `v0.5.4`; see [release notes](docs/releases/0.5.4.md).
> Mac 0.5.5 (build 15) released at the owner's request on 2026-11-07: Spotify v3 three-column navigation with left-column drill-down (`Show all →` / `‹ Back to library`, ownership and theme filters), dynamic center workspace (`AlbumsWorkspaceView`, `DiscoveryWorkspaceView`), persistent right-hand `CompactQueueColumn` with drag-and-drop album/playlist expansion, and post-2026 Similar & Discovery engine (`09 · Spotify — v3`, `166:304`). Signed/notarized Mac app and DMG; source tag `v0.5.5`; see [release notes](docs/releases/0.5.5.md) and [research](<docs/RESEARCHES/DONE/DONE - 2026-11-07_11-12_Spotify-v3-three-column-queue-and-discovery.md>).
> All design work is done in Figma file [Kinrox — Design](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U) (owner decision 2026-10-27), see Section 3.5.
> Landing site added 2026-10-27: static GitHub Pages site in `site/` (English + Russian), deployed by `.github/workflows/pages.yml`; see Section 3.6.
> Website localization implemented 2026-10-30 at the owner's request: landing, support and privacy pages in all 30 app locales, localized screenshots, language navigation, RTL and offline generation. Owner authorized deployment on 2026-10-30; [verification](docs/runbooks/SITE-LOCALIZATION-VERIFICATION.md).
> Spotify connection terms and privacy supplement translated into all 30 app languages on 2026-11-01. Shared versioned JSON resources drive offline Mac documents and generated public pages; language selection, completeness and RTL checks are verified. Prepared locally for the music release; [verification](<docs/RESEARCHES/DONE/DONE - 2026-11-01_12-23_Spotify-document-localization.md>).
> Licensing split authorized 2026-11-01: Mac remains GPL-3.0-only; new RemoteiOS revisions use a personal-use license prohibiting commercial use, with free source-sharing forks allowed. Shared-code permission, attribution and branding rules are in [LICENSING.md](LICENSING.md). Earlier GPL grants remain valid; App Store rollout is separate.
> Open questions are compiled in Section 11. Until closed, proposals marked "proposal" are non-final.

Legend:

- ✅ — verified against headers and documentation of mpv v0.41.0 or IINA source tree (`develop` branch), see Section 4.6;
- ⚠️ **unverified** — based on memory or indirect data; verify during implementation.

---

## 0. Development Environment (Verified 2026-10-25)

| Component | Version / State |
|---|---|
| macOS | 26.5.2 (build 25F84), Apple Silicon (arm64) |
| Xcode | 26.5 (build 17F42), path `/Applications/Xcode.app/Contents/Developer` |
| SDK | macOS 26.5, iOS 26.5 |
| Swift | 6.3.2 (`swift-driver 1.148.6`) |
| `swift-format` | 6.3.0, bundled with Xcode (`xcrun swift-format`) |
| `devicectl` | 518.31 (`xcrun devicectl`), for terminal installations to iPhone |
| iOS Simulators | runtimes 18.1, 18.2, 18.4, 18.5, and 26.5; iPhone 17, 17 Pro, Air, etc. present |
| Homebrew | 7.0.10, `/opt/homebrew` |
| **mpv / libmpv** | mpv 0.41.0 (Homebrew `0.41.0_11`), libmpv API 2.5.0; headers `/opt/homebrew/include/mpv` and `mpv.pc` installed per owner request |
| ffmpeg | 9.0.2 (Homebrew `9.0.2_1`), upgraded as dependency of mpv; built with `--enable-gpl --enable-version3` |
| Python | Homebrew `python3` switched to 3.15.1 on mpv dependency installation; replaced files preserved by Homebrew in `~/Library/Caches/Homebrew/Backup` |
| pkg-config | 2.5.1, `/opt/homebrew/bin/pkg-config` |
| git | 2.51.2. Sole branch `main`; changes left uncommitted for review. Remote `origin` — public [github.com/awaik/Kinrox](https://github.com/awaik/Kinrox) (created 2026-10-28), landing at [awaik.github.io/Kinrox](https://awaik.github.io/Kinrox/) |
| XcodeGen, Tuist, xcbeautify, SwiftLint | XcodeGen 2.46.0 installed by owner; others not installed |
| macOS Firewall | disabled (may be enabled on user machines, see 6.8) |
| Code Signing | M0: Sign to Run Locally for Mac, simulator for iOS; device team and distribution team not yet finalized |
| Reference | IINA 1.5.0 installed (bundles 45 dylibs, including `libmpv.2.dylib`) and VLC 3.0.24 |

**Installing Dependency for M1** (only upon explicit request from owner; verification scripts do not install anything):

```sh
brew install mpv          # libmpv + headers + pkg-config file mpv.pc
```

Installed and verified 2026-10-25. Verification commands:

```sh
mpv --version                           # player version: 0.41.0
pkg-config --modversion mpv              # client API version of libmpv: 2.5.0
ls /opt/homebrew/include/mpv             # client.h render.h render_gl.h stream_cb.h
```

---

## 1. Goals and Concept

**Kinrox** — minimalist video player for macOS in Swift with libmpv core and a dedicated companion remote app for iPhone controlling playback over the local network.

**Target audience.** For viewers watching movies and series from a Mac connected to a TV or projector, or simply from the couch, who do not want to reach for the keyboard. Secondary audience — anyone looking for a clean and responsive player for diverse media formats (including mkv) without cluttered options.

**Principles.**

1. Native feel: Swift 6, SwiftUI, AppKit only where SwiftUI does not suffice (video window, fullscreen mode, application menus).
2. Minimalist UI: everything not essential for viewing is hidden or omitted.
3. Remote as first-class product component: network discovery, PIN pairing, instant feedback.
4. Local network exclusively. No cloud, user accounts, analytics, or telemetry.
   Exception (owner decision 2026-10-29): the Mac player's Sparkle update check reads
   the HTTPS appcast at most once a day, without identifiers or system profile.
   Additional exception (owner decision 2026-11-01): optional Spotify access on
   Mac, disabled until the user connects an account using their own Client ID.
   OAuth, catalogue and library use Spotify's official services; standalone audio
   uses separately downloaded Spotify Soloist with the user's own key and one-time
   phone pairing (owner decisions, 2026-11-03). No Kinrox server or analytics.
   The iPhone sends controls over the LAN and never calls Spotify’s API. Owner decision
   2026-11-01 additionally permits user-initiated contextual links to Spotify on iPhone.

**Comparison with IINA and VLC.**

| | Kinrox | IINA | VLC |
|---|---|---|---|
| Core Engine | libmpv | libmpv | Custom (libVLC) |
| Interface | SwiftUI, minimal | AppKit, feature-heavy | Custom Cocoa on macOS, extensive options |
| iPhone Remote | Built-in native app, PIN pairing, encrypted | No official app (⚠️ unverified, third-party options exist) | Web interface via HTTP with password or third-party apps |
| Focus | "Open and watch from the couch" | Universal player for enthusiasts | Universal all-in-one media workbench |

Kinrox does not attempt to replicate IINA's feature breadth (filters, plugins, complex subtitle tuning). Its core value is the friction-free pairing: "simple player + convenient remote" that works without setup.

---

## 2. Initial Version Features (v1)

### 2.1. Mac Player

| Feature | Implementation |
|---|---|
| Open File | `NSOpenPanel`, drag-and-drop into window or Dock icon, "Open With" (document types in `Info.plist`: mkv, mp4, m4v, mov, avi, webm, ts, and "any video" via UTI `public.movie`) |
| Play / Pause | Space, on-screen button, media keys, remote. Controls overlay displays on mouse move and auto-hides after 3s while video plays |
| Seeking | Position scrubber (seeks on release, hover time indicator); ←/→ for 5s, ⇧←/⇧→ for 30s; remote ±10/±30s |
| Volume | Slider, ↑/↓ with step 5; range 0–100 (no amplification beyond 100 in v1) |
| Fullscreen | Native `NSWindow.toggleFullScreen(_:)`, double-click, `F` key, remote |
| Recent Files | Up to 20 entries, stored as security-scoped bookmarks (see 3.4); synced with system menu "Open Recent" via `NSDocumentController.noteNewRecentDocumentURL(_:)` |
| Next / Previous File | Playlist from video files in same directory, natural Finder sort order ("2" before "10"); ⌘←/⌘→ and controls bar buttons. Auto-advances to next file upon finish; on final item player remains on last frame, and "Play" restarts from beginning (owner decision 2026-10-26) |
| System Media Keys | `MPRemoteCommandCenter` + `MPNowPlayingInfoCenter` (Section 5) |
| Screensaver | `Screensaver → Matrix`: falling green code replaces the video after mpv confirms pause. Esc exits without resuming or leaving fullscreen. The hint appears only for the first 3 seconds; mouse movement does not restore it. Also works without media. Owner approved 2026-10-29. |
| Remote Control | Protocol server (Section 6) |
| Updates | Sparkle 2: a daily background check; reminder banner on the welcome screen, compact pill only on pause, "Check for Updates…" with a version badge; Sparkle's windows download, verify, and install. Owner approved 2026-10-29; see [verification](docs/runbooks/UPDATES-VERIFICATION.md). |
| Audio and Subtitles | Embedded and external tracks, subtitles Off, native Audio/Subtitles menus, and control-bar selector. Recursive discovery under the video folder by default; selectable common root, searchable full list, manual file loading, and per-folder preferences. Owner approved 2026-10-29; see [verification](docs/runbooks/TRACKS-VERIFICATION.md). |

### 2.2. iPhone Remote

Discovery of players on local network, PIN pairing, controls: pause, ±10/±30s, scrub to position, volume, next/previous file, open from recents, fullscreen, and Matrix screensaver start/stop. Detailed in Section 6.

### 2.3. Excluded from v1

Playback position memory, custom playlists, network streams and URLs, YouTube (`ytdl` disabled), video filters and custom shaders, custom cover art, picture-in-picture, iPad/Apple Watch remote targets, multi-player simultaneous routing. Track selection is currently a Mac feature; remote protocol track commands are not included.

---

## 3. Architecture and Repository Structure

### 3.1. Components

- **PlayerMac** — macOS application (SwiftUI + AppKit). Contains **MPVKit** — wrapper around C API of libmpv in a subdirectory inside PlayerMac with bridging header (approved by owner 2026-10-25, see 3.3).
- **RemoteiOS** — iPhone remote application (SwiftUI); music metadata and controls use only the encrypted LAN protocol.
- **KinroxMusic** — shared package: `MusicCore` contains models, favorites policy, occurrence-based queue and selection; `SpotifyWebAPI` is linked only into PlayerMac.
- **Mac Music services** — account/PKCE/Keychain, cached library and favorites transactions, native Soloist engine and `PlaybackCoordinator`. The coordinator serializes observed pauses between video and music and owns one Now Playing session. View switching alone never starts or pauses audio.
- **RemoteProtocol** — shared Swift Package. Targets within:
  - `RemoteProtocol` — command and state models, JSON codec, versioning, handshake cryptography (Foundation + CryptoKit, free of Network.framework, making it straightforward to test);
  - `RemoteTransport` — Network.framework abstractions: Bonjour advertiser and browser, server and client;
  - `kinrox-cli` — optional command-line diagnostic tool; separate task outside M0–M6.

```
          iPhone                                   Mac
┌───────────────────────┐            ┌──────────────────────────────────┐
│ RemoteiOS (SwiftUI)   │            │ PlayerMac (SwiftUI + AppKit)     │
│  ├ DiscoveryView      │            │  ├ PlayerViewModel (@MainActor)  │
│  ├ PairingView        │  Bonjour   │  ├ RemoteServer ──────────────┐  │
│  └ RemoteView         │◄──────────►│  ├ NowPlayingController       │  │
│        │              │  TCP + WS  │  ├ RecentFilesStore           │  │
│ RemoteClient          │◄──────────►│  └ MPVKit                     │  │
│        │              │ (encrypted)│      ├ MPVPlayer (client API)  │  │
│ RemoteProtocol ───────┼── shared ──┼──────┤ └ VideoLayer (render)   │  │
│ RemoteTransport       │   package  │ RemoteProtocol / Transport ◄──┘  │
└───────────────────────┘            └──────────────────────────────────┘
```

Data flow on Mac: command (keyboard, media key, or remote) → `PlayerViewModel` → `MPVPlayer` (`mpv_command_async`) → mpv mutates property → `MPV_EVENT_PROPERTY_CHANGE` event → `PlayerViewModel` on `@MainActor` → UI refresh; `MPNowPlayingInfoCenter` and remote `state` dispatch. Source of truth for playback state is mpv, not UI state.

### 3.2. Directory Layout

```
Kinrox/
├── AGENTS.md                     # master project document
├── CLAUDE.md                     # link to AGENTS.md
├── README.md                     # summary and build instructions
├── LICENSE                       # GNU GPL v3 (GPL-3.0-only)
├── LICENSING.md                  # component scope, remote license, and shared-code exception
├── NOTICE                        # attribution and modified-version notices
├── TRADEMARKS.md                  # name and logo policy
├── .gitignore
├── .swift-format                 # formatting rules
├── Kinrox.xcworkspace            # unites both applications and shared package
├── Resources/
│   └── Branding.xcassets         # logo and design tokens (bg/*, text/*, accent/* …) for both apps
├── Shared/                       # Swift files compiled into both applications
│   ├── Design/KinroxTheme.swift  # Palette, KinroxFont, kinroxGlass — Figma tokens (3.5)
│   ├── ProjectLink.swift         # localized website, source, license, support, issues, and privacy links
│   └── TimeFormat.swift          # "0:42:15", "−1:15:48"
├── Config/
│   ├── Shared.xcconfig           # common settings, OS deployment targets, Swift 6
│   ├── PlayerMac.xcconfig        # Mac signing + shared settings
│   ├── RemoteiOS.xcconfig        # iOS automatic signing + shared settings
│   ├── MPV.xcconfig              # libmpv search paths and library flags
│   ├── Updates.xcconfig          # Sparkle feed URL and EdDSA public key
│   ├── Signing.local.xcconfig.example # local template
│   └── Signing.local.xcconfig    # signing team, NOT committed (.gitignore)
├── PlayerMac/
│   ├── project.yml               # XcodeGen specification (.xcodeproj not committed)
│   ├── PlayerMac.xcodeproj
│   ├── PlayerMac/
│   │   ├── App/                  # KinroxPlayerApp, AppDelegate, PlayerSession, PlayerCommands
│   │   ├── Player/               # PlayerViewModel(+Commands), PlayerView, window, OverlayController
│   │   │   ├── Controls/         # ControlsBar, Scrubber, VolumeControl, buttons, popovers
│   │   │   └── Welcome/          # splash screen, recent cards, placeholder artwork
│   │   ├── MPVKit/               # libmpv wrapper
│   │   │   ├── PlayerMac-Bridging-Header.h
│   │   │   ├── MPVPlayer.swift          # mpv_handle, commands, properties
│   │   │   ├── MPVEventLoop.swift       # background mpv_wait_event thread
│   │   │   ├── MPVEvent.swift           # C API event translation, property formats
│   │   │   ├── MPVLifetime.swift        # ordered asynchronous teardown
│   │   │   ├── MPVRenderContext.swift   # CGL and mpv_render_context
│   │   │   ├── MPVError.swift
│   │   │   ├── VideoLayer.swift         # CAOpenGLLayer + mpv_render_context
│   │   │   └── VideoView.swift          # NSView layer host + NSViewRepresentable
│   │   ├── NowPlaying/           # MPRemoteCommandCenter, MPNowPlayingInfoCenter
│   │   ├── Remote/               # PairingCodeView, PairingCenter, RemoteServer, Keychain store
│   │   ├── Library/              # RecentFilesStore, FolderPlaylist, VideoFiles
│   │   ├── Music/                # domain model adapter, coordinator, Spotify services and UI
│   │   ├── Updates/              # UpdateCenter, SparkleUpdater, update banner and pill
│   │   ├── Resources/            # Assets.xcassets, Localizable.xcstrings
│   │   ├── Info.plist
│   │   └── PlayerMac.entitlements
│   └── PlayerMacTests/
├── RemoteiOS/
│   ├── project.yml
│   ├── RemoteiOS.xcodeproj
│   ├── RemoteiOS/
│   │   ├── App/                  # KinroxRemoteApp, RootView
│   │   ├── Connection/           # RemoteAppModel, TransportClient, clocks, commands
│   │   ├── Storage/              # ServerCredentialStore, deviceId, selected Mac
│   │   ├── Demo/                 # isolated RemoteDemoStore
│   │   ├── Discovery/            # local network player discovery
│   │   ├── Pairing/              # PIN entry
│   │   ├── Remote/               # remote control screen, recents
│   │   ├── Music/                # music deck, queue and favorites sheet
│   │   ├── Settings/
│   │   ├── Resources/
│   │   └── Info.plist
│   └── RemoteiOSTests/
├── Packages/
│   ├── KinroxMusic/              # MusicCore and Mac-only SpotifyWebAPI, with tests
│   └── RemoteProtocol/
│       ├── Package.swift
│       ├── Sources/
│       │   ├── RemoteProtocol/   # Message, Command, PlayerState, Codec, Version, Crypto
│       │   ├── RemoteTransport/  # BonjourAdvertiser, BonjourBrowser, Server, Client
│       │   └── kinrox-cli/       # CLI diagnostic tool
│       └── Tests/
│           ├── RemoteProtocolTests/
│           └── RemoteTransportTests/
├── docs/RESEARCHES/              # research evidence, bug investigations, and correction plans
├── docs/runbooks/                # build, signing, and verification runbooks
├── site/                         # static landing page for GitHub Pages (3.6)
│   ├── index.html                # English, default
│   ├── ru/index.html             # Russian
│   ├── appcast.xml               # Sparkle update feed for the Mac player
│   └── assets/                   # css, js, Figma icons and stills, remote screenshots
├── .github/workflows/pages.yml   # deploys site/ to GitHub Pages
├── Scripts/
│   ├── check-env.sh              # environment verification script
│   ├── generate.sh               # project generator
│   ├── capture-landing-screenshots.sh # remote screenshots for site/
│   ├── bundle-libmpv.py          # verified dylib packaging in .app (M6)
│   └── update-appcast.py         # EdDSA-signed appcast item for a Mac release
└── Vendor/                       # compiled dylibs for M6, in .gitignore
```

### 3.3. Technical Decisions

- **Playback Engine — decided (2026-10-25): libmpv + OpenGL**, following IINA. Alternatives evaluated:
  - AVFoundation/AVPlayer alone — lacks mkv support;
  - libmpv with Vulkan/Metal — only via unmerged PR #7857;
  - FFmpeg reading + `AVSampleBufferDisplayLayer` — modern, but extensive implementation overhead;
  - Third-party packages (KSPlayer, VLCKit 4) — licensing and maturity constraints.

  To facilitate future engine transitions if needed, player modules communicate with mpv exclusively via the `PlayerEngine` protocol (4.5). C types (`mpv_handle`, `mpv_event`) never escape `MPVKit/`.
- **Language:** Swift 6, complete concurrency check mode (`SWIFT_STRICT_CONCURRENCY = complete`, Swift language mode 6). UI models use `@Observable` (Observation framework, macOS 14 / iOS 17 minimum).
- **Project Structure:** XcodeGen (`project.yml`) for `PlayerMac` and `RemoteiOS`. Project files (`.xcodeproj`) are generated and git-ignored. `Kinrox.xcworkspace` ties both projects and the `RemoteProtocol` package together.
- **Code Signing:** M0–M3 used ad-hoc signing (`-`). M4.4+ requires Apple Development team signing with macOS provisioning profile to support Data Protection Keychain. iOS simulator builds without developer team. Personal overrides reside in `Config/Signing.local.xcconfig` (git-ignored).
- **Application Sandbox:** Disabled in v1 for PlayerMac (`com.apple.security.app-sandbox = false`) by owner decision 2026-10-26, permitting arbitrary local file access without complex bookmark hierarchies. Hardened Runtime enabled. RemoteiOS runs sandboxed per iOS rules.
- **Distribution:** PlayerMac distributed as notarized DMG from official site; RemoteiOS via App Store.
- **Mac updates — decided (2026-10-29): Sparkle 2** (`exactVersion` in `project.yml`). Gentle reminders show Kinrox's own banner and pill; Sparkle's standard windows handle download, EdDSA and code-signature checks, and installation. The feed is `site/appcast.xml` on GitHub Pages; enclosures are GitHub Release DMGs. Builds without `KINROX_UPDATE_PUBLIC_KEY` have no updater and make no requests.
- **UI Localization:** English (`en`) remains the base and fallback language. Both apps support 30 system-selected locales (owner request, 2026-10-27); see [localization scope](docs/TODO/03-localization.md).

### 3.4. Recent Files

Security-scoped bookmarks stored in `UserDefaults` (`app.kinrox.player.recents`). Up to 20 entries.
Each record:
```swift
struct RecentFileItem: Identifiable, Codable, Sendable {
    let id: UUID
    let bookmarkData: Data
    let title: String
    let duration: Double?
    let lastOpened: Date
}
```

Duplicated to system menu via `NSDocumentController.noteNewRecentDocumentURL(_:)`.
When opened via remote, path is resolved on Mac without sending filesystem paths across the network.

### 3.5. Design (Figma)

All design work for Kinrox — Mac player, iPhone remote, and the landing site — is done in one Figma file,
[Kinrox — Design](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U) (owner decision 2026-10-27).
The file is the source of truth for layouts, texts in mockups, components, and tokens; code follows it.

| Page | Contents |
|---|---|
| [01 · UI v1 — Player & Remote](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox-%E2%80%94-Design?node-id=0-1) | Cover with principles, palette and type; Mac player screens (M2); iPhone remote screens (M5); component library |
| [02 · M4 — Connection & states](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox-%E2%80%94-Design?node-id=13-352) | Remote settings on Mac, "Connect iPhone" window, search hints, local network denied, wrong code, reconnecting, connection failed, nothing playing, incompatible version |
| [04 · Tracks — Audio & subtitles](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox?node-id=30-304) | Mac entry point, audio/subtitle panels, recursive file browser, native menus, folder scope, scanning/empty/error states |
| [05 · Updates — Update banner](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox?node-id=48-304) | Welcome-screen update banner, paused-player pill, Kinrox menu item, Sparkle flow states and display rules (approved 2026-10-29) |
| [06 · About — Project links](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox?node-id=60-304) | Native Mac About credits and Help menu, iPhone Settings/About: website, GitHub, component license, support, issues, and privacy links (owner requested 2026-10-29; license copy updated 2026-11-01) |
| [07 · Screensaver — Matrix](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox?node-id=63-304) | Mac menu and animation, iPhone entry/ready/active/paused states; approved 2026-10-29 with a one-shot 3-second exit hint (`67:491`) |
| [08 · Music — Spotify](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox?node-id=88-304) | Three-column Mac library, fixed deck, narrow window, iPhone remote/queue/favorites; official attribution and inline recovery variants approved 2026-11-01 (`116:3116`) |
| [09 · Spotify — v3 · Навигация, Похожее и Очередь](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox?node-id=166-304) | Renamed `Spotify` tab, expandable Left Column (`Show all →` + `‹ Back to library`, ownership & theme filters), dynamic Center Workspace (`TrackTable`, `AlbumsWorkspaceView`, `DiscoveryWorkspaceView`), persistent Right Column (`CompactQueueColumn` with album/playlist expansion on drop), and post-2026 Discovery Engine (`166:304`) |

Working with the file:
- new screens and states are designed in this file before implementation; existing pages follow `NN · <milestone> — <topic>`;
- mockup copy in Figma is currently Russian; app source strings stay English (Section 9);
- for the Figma MCP server: page ids `0:1`, `13:352`, `30:304`, `48:304`, `60:304`, `63:304`, `88:304`, and `166:304`; component library in section `3:2`.

Project information links share one destination catalog in both apps and open in
the system browser only when activated. The license label, description and destination
depend on the app: GPL for Mac, personal-use terms for the remote (Section 10).
The Mac Help menu replaces the unavailable
default Help Book command; its native About panel retains the app icon and version.

Design tokens reside in `Shared/Design/KinroxTheme.swift` and `Resources/Branding.xcassets`.
Liquid Glass aesthetic with fallback materials on pre-macOS 26 systems. System fonts: SF Pro and SF Pro Rounded.

### 3.6. Landing Site

Static pages in `site/`, published at `https://kinrox.app/` to GitHub Pages by
`.github/workflows/pages.yml` (repository Settings → Pages → Source: GitHub Actions).
All 30 app locales cover the landing, support and privacy pages (owner request, 2026-10-30).
English uses the root routes; other languages use their locale prefix, such as `/ru/support/`.
Shared templates and complete catalogs in `Website/` generate committed HTML offline with
`Scripts/build-site.py`; deployment verifies the output. No runtime frameworks, translation
requests, external fonts, analytics or cookies. Navigation works without JavaScript.
The language menu preserves the current page, with RTL layout for Arabic, Persian, Hebrew and Urdu.

- First screen states the pain: getting up to pause a movie playing from a MacBook on a projector.
  The hero illustration `site/assets/img/scene.svg` shows a person on a couch with an iPhone,
  a MacBook and a projector; the real remote screenshot sits next to it.
- iPhone screenshots are captured from the real app in demo mode by `Scripts/capture-landing-screenshots.sh`.
- Mac screens are HTML recreations of Figma frames 5:23 and 6:215 using real localized app strings.
- Icons and video stills are exported from the Figma component library.
- Claims on the page must match shipped behavior. Mac download buttons target the versioned GitHub
  Release DMG; publish and verify the asset before the page. Details — [site/README.md](site/README.md).

---

## 4. libmpv Core (MPVKit)

### 4.1. Lifecycle

1. `mpv_create()` → handle initialization.
2. `mpv_set_option_string()`:
   - `vo=libmpv` — render API integration;
   - `hwdec=videotoolbox` — VideoToolbox hardware decoding;
   - `input-media-keys=no` — avoid intercepting keyboard media keys (handled via MPRemoteCommandCenter);
   - `keep-open=always` — stay on final frame upon stream end;
   - `ytdl=no` — disable network stream probing.
3. `mpv_initialize()`.
4. Create background thread executing `mpv_wait_event()` loop.
5. Setup `mpv_render_context` bound to OpenGL context.
6. Teardown:
   - `mpv_render_context_free(render_ctx)`;
   - `mpv_wakeup(mpv)` and terminate event loop thread;
   - `mpv_destroy(mpv)`.

### 4.2. Properties, Commands, and Events

Key observed properties:
- `time-pos` (`MPV_FORMAT_DOUBLE`) — current position in seconds;
- `duration` (`MPV_FORMAT_DOUBLE`) — total duration;
- `pause` (`MPV_FORMAT_FLAG`) — pause state;
- `volume` (`MPV_FORMAT_DOUBLE`) — volume (0–100);
- `eof-reached` (`MPV_FORMAT_FLAG`) — end of file indicator;
- `track-list` (`MPV_FORMAT_NODE`) — audio and subtitle tracks.

Commands executed via `mpv_command_async`:
- `loadfile <url> replace`
- `cycle pause`
- `seek <seconds> relative|absolute`
- `set volume <0-100>`

Events translated into `PlaybackEvent: Sendable` and processed on `@MainActor`.

### 4.3. Video Output via Render API

Render pipeline:
- `CAOpenGLLayer` hosted inside `NSViewRepresentable`.
- OpenGL 3.2 Core profile.
- Context creation and frame drawing managed via `mpv_render_context_render`.
- `mpv_render_context_set_update_callback` notifies layer when a new frame is ready.

### 4.4. Threading in Render API

libmpv callbacks are non-blocking and trigger on internal background threads.
- `update_cb` must never perform rendering directly; it signals `setNeedsDisplay` on the layer.
- Drawing occurs on the render thread within `draw(inCGLContext:pixelFormat:forLayerTime:displayTime:)`.
- UI interactions and state observations isolate strictly to `@MainActor`.

### 4.5. Engine Protocol (`PlayerEngine`)

Defined in `PlayerMac/PlayerMac/Player/PlayerEngine.swift` together with
`PlaybackProperty`, `PlaybackValue` and `PlaybackEvent`:

```swift
@MainActor
protocol PlayerEngine: AnyObject {
    var events: AsyncStream<PlaybackEvent> { get }
    func load(url: URL) throws
    func setPaused(_ paused: Bool) throws
    func seek(relative seconds: Double) throws
    func seek(absolute seconds: Double) throws
    func setVolume(_ volume: Double) throws
    func selectTrack(kind: MediaTrackKind, number: Int64?, requestID: UInt64) throws
    func addTrack(url: URL, kind: MediaTrackKind, requestID: UInt64) throws
    func cancelTrackCommand(id: UInt64)
    func stop() throws
    func shutdown() async
}
```

`MPVPlayer` is the production conformer; tests use `FakePlayerEngine`. Methods submit
commands and throw only when submission fails. Results and state changes arrive as
`PlaybackEvent` values on `events`, which `PlayerViewModel` consumes on `@MainActor`.
Play, pause and toggle are expressed with `setPaused(_:)`; the user-level commands
(`togglePause`, `seek(by:)`, `next` and others) live in `PlayerViewModel+Commands.swift`.
Views, Now Playing and the remote server go through `PlayerViewModel`; only the model
calls the engine. The one exception is rendering: `PlayerWindowController` passes
`MPVPlayer.videoLayer` to `PlayerView`.

### 4.6. Source References

- mpv 0.41.0 header documentation: `client.h`, `render.h`, `render_gl.h`.
- IINA source code (`develop` branch): reference implementation for `CAOpenGLLayer` + CGL context binding.

---

## 5. System Media Keys

Control Center "Now Playing" and keyboard media keys (⏯︎, ⏭︎, ⏮︎) coordinate with Kinrox playback:
- Backed by `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`.
- Metadata published: title (`displayTitle`), folder name or "Kinrox", total duration, elapsed time, playback rate (1.0 or 0.0), artwork (`KinroxLogo`).
- Position update rate throttled to 2 Hz or state changes; system extrapolates time continuously based on playback rate.
- Inactive when no media is loaded (`playbackState = .stopped`).
- Window closure tears down Now Playing info immediately.

---

## 6. iPhone Remote Control

### 6.1. Discovery (Bonjour)

- Service type: `_kinrox._tcp` in domain `local.`.
- TXT Record:
  - `v`: protocol version string ("1");
  - `id`: persistent server UUID (`serverId`);
  - `pv`: human-readable player version ("1.0").
- `BonjourBrowser` on iOS monitors local network for active players. Offline players persist in UI based on stored Keychain credentials.

### 6.2. Transport

- WebSocket over TCP via Network.framework (`NWListener` on Mac, `NWConnection` on iPhone).
- Max 4 concurrent connections per player.
- Framing: Single binary WebSocket frame per protocol message (up to 65,536 bytes).
- Heartbeat: Ping every 5s; 15s timeout on client, 20s timeout on server. Pong response is automatic.

### 6.3. Message Format and Versioning

- Envelopes encode as canonical sorted-key JSON:
```json
{
  "v": 1,
  "id": "A1B2C3D4-E5F6-7A8B-9C0D-1E2F3A4B5C6D",
  "type": "command",
  "body": { ... }
}
```
- Message types (`Message.MessageType` in `Packages/RemoteProtocol/Sources/RemoteProtocol/Message.swift`):
  - `hello` / `helloAck`: version negotiation; `helloAck` also carries the server's
    ephemeral X25519 public key, a 32-byte nonce and `needsPairing`;
  - `pairRequest`: client's ephemeral X25519 public key when pairing;
  - `pairChallenge`: empty body; the Mac shows the PIN;
  - `pairProof` / `paired`: PIN proof, then the token and server proof;
  - `auth` / `authOk`: reconnection with a stored token (`auth` carries the device id,
    the client's ephemeral public key and the proof);
  - `command` / `ack`: control commands and acknowledgements;
  - `requestState`: asks the Mac for a fresh `state`;
  - `state`: player playback state snapshot;
  - `recent`: recent files list;
  - `error`: protocol or application errors;
  - `bye`: clean disconnection.
- Handshake messages before `paired` / `authOk`, and handshake `error` replies, travel
  as plain JSON frames. `paired`, `authOk` and all application messages (`command`,
  `requestState`, `bye`, `state`, `recent`, `ack`, and `error` after the handshake)
  travel only inside the encrypted channel (6.5.1).

Screensaver support is an additive v1 extension: `state.screensaver` is optional
(`off` or `matrix`), and `setScreensaver` carries the requested value. A missing
state field identifies an older Mac, so the new remote disables start/stop and
offers an update explanation. Old clients ignore the additional state field.
The Mac publishes an active screensaver only after mpv confirms the movie is paused;
an acknowledgement alone never changes the remote's displayed state.

Music support is also additive v1: optional `state.source` / `state.music`, eight
music commands and paged `requestQueue` / `queue` and `requestLikeOptions` /
`likeOptions` messages. Replies carry revisions; stale pages restart at zero.
Credentials, filesystem paths and Spotify API access never cross to iPhone.
Queue pages reserve the protected-frame overhead within the 64 KiB limit.

### 6.4. PIN Pairing

- 6-digit random decimal code generated via `SystemRandomNumberGenerator`.
- 120-second validity period.
- 3 failed attempts lockout.
- Server permits exactly one active pairing negotiation at a time.
- Successful pairing outputs an authentication token (32 bytes cryptographically secure random data).
- Token persistence:
  - Mac: macOS Data Protection Keychain under `app.kinrox.remote.paired-devices`.
  - iPhone: iOS Keychain under `app.kinrox.remote.servers`.

### 6.5. Channel Protection — CryptoKit Handshake

Channel security uses authenticated Diffie-Hellman with ephemeral keys (ECDH over Curve25519) and symmetric framing (ChaCha20-Poly1305 AEAD).

#### 6.5.1. Handshake Format

Implementation: `Packages/RemoteProtocol/Sources/RemoteProtocol/Crypto/`
(`HandshakeTranscript`, `HandshakeKeys`, `ClientHandshake`, `ServerHandshake`,
`SecureChannel`). Independent vectors: `Tests/RemoteProtocolTests/Fixtures/crypto/v1.json`,
generated by `Scripts/generate-crypto-vectors.py`.

Notation: `label(x)` is the UTF-8 string `"kinrox/v1/" + x` followed by one zero byte;
integers are 32-bit big-endian; a UUID is its 16 raw bytes; a string is its UTF-8 byte
count followed by the bytes.

1. **Flows:**
   - Pairing: `hello` → `helloAck` → `pairRequest` → `pairChallenge` → `pairProof` →
     `paired` (encrypted). A wrong PIN returns `authFailed` and allows a new `pairProof`;
     the third failure returns `tooManyAttempts` and closes the connection.
   - Reconnection: `hello` → `helloAck` → `auth` → `authOk` (encrypted).
   - Both sides generate a new X25519 key pair for every connection.
2. **Transcript:** `label("transcript")`, a mode byte (0 pairing, 1 reconnection), then
   from `hello`: header `v` and `id`, `minVersion`, `maxVersion`, `deviceId`,
   `deviceName`, `appVersion`; from `helloAck`: header `v` and `id`, `version`,
   `serverId`, `serverName`, the `needsPairing` byte, `serverPublicKey` (32 bytes) and
   `nonce` (32 bytes); from `pairRequest` or `auth`: header `v` and `id`, and
   `clientPublicKey` (32 bytes). `transcriptHash = SHA-256(transcript)`.
3. **Key derivation (HKDF-SHA256, 32-byte outputs):**
   - `Z = X25519(ownPrivate, peerPublic)`; an all-zero `Z` fails with `authFailed`.
   - `K_c2s`, `K_s2c`, `K_confirm = HKDF(IKM: Z, salt: helloAck.nonce,
     info: label("key/c2s" | "key/s2c" | "key/confirm") + transcriptHash)`.
4. **PIN proof (pairing):**
   - `K_pin = HKDF(IKM: PIN as 6 ASCII digits, salt: K_confirm, info: label("pin") + transcriptHash)`.
   - `clientProof = HMAC-SHA256(K_pin, label("pair/client") + transcript + pairProof.id)`.
   - The server verifies it, creates a 32-byte token, stores it, and replies with encrypted
     `paired { token, serverProof }`, where
     `serverProof = HMAC-SHA256(K_pin, label("pair/server") + transcript + pairProof.id + clientProof + token)`.
   - The client stores the token only after verifying `serverProof`.
5. **Token authentication (reconnection):**
   - `clientProof = HMAC-SHA256(key: token, label("auth/client") + transcript)`, sent in `auth`.
   - `K_auth = HKDF(IKM: token, salt: K_confirm, info: label("auth/server-key") + transcriptHash)`.
   - `serverProof = HMAC-SHA256(K_auth, label("auth/server") + transcript + clientProof)`,
     sent in encrypted `authOk`.
6. **Encrypted frames:**
   - ChaCha20-Poly1305 with `K_c2s` (iPhone → Mac) and `K_s2c` (Mac → iPhone).
   - Frame = 12-byte nonce + ciphertext + 16-byte tag (28 bytes overhead); plaintext is at
     most 65,536 − 28 bytes.
   - The nonce is a 96-bit big-endian counter per direction starting at 0; the receiver
     accepts only the next expected value, so replay or omission terminates the connection.
   - AAD = `label("frame") + transcriptHash` plus a direction byte (0 iPhone → Mac,
     1 Mac → iPhone).

### 6.6. Local Network Policy

Strictly restricted to local networks:
- `acceptLocalOnly = true` on `NWParameters`.
- Cellular interfaces disabled.
- Verification of client IP against active local subnet interfaces (`getifaddrs`).
- Public IP addresses rejected immediately.

### 6.7. System Permissions

- Mac: Local Network permission prompt on first socket listen.
- iPhone: `NSLocalNetworkUsageDescription` in `Info.plist`, `_kinrox._tcp` in `NSBonjourServices`.

### 6.8. Disconnections and Reconnection

- Reconnection backoff on client: 0.5s, 1s, 2s, 4s, 8s, 10s (max 120s total).
- Backgrounding sends `bye` frame with 0.25s budget, then closes socket.
- Foregrounding resumes connection using stored Keychain token.

### 6.9. Remote UI Design

Implements Figma layout [Kinrox — Design](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U):
- Glass card aesthetics, glowing accents (`Palette.ember`, `Palette.flame`).
- Scrub bar, large play/pause toggle, ±10/±30s jumps, volume slider, recent files sheet.

---

## 7. Development Milestones

### M0. Documentation and Project Scaffolding
- Initial configurations, `.xcconfig`, XcodeGen project definitions, toolchain verifications.

### M1. libmpv Wrapper, Window Playback
- Completed 2026-10-25: libmpv integration, OpenGL rendering, window opening, hardware decoding.

### M2. Controls Overlay in Player
- Completed 2026-10-26: Liquid Glass controls bar, keyboard shortcuts, folder playlists, recent files.

### M3. System Media Keys
- Completed 2026-10-26: MPRemoteCommandCenter, Now Playing metadata, Control Center controls.

### M4. Protocol, Transport, and Server in Mac Player
- Completed 2026-10-27: RemoteProtocol, CryptoKit handshake, Network.framework WebSocket server, Keychain token storage, pairing modal.

### M5. iPhone Remote Application
- Completed 2026-10-27: Real remote app, Bonjour discovery, PIN pairing, full playback controls, reconnection resilience, Keychain storage.

### M6. libmpv Bundling and Distribution
- Implemented 2026-10-28: portable arm64 libmpv and 43 dependent dylibs, Developer ID signing with library validation, app/DMG notarization and stapling, source archives, and download links. Runtime verification on macOS 26.5.2; macOS 14 remains the minimum deployment target, without a separate macOS 14 manual test in this session.

---

## 8. Build and Execution

```sh
# Environment Check
./Scripts/check-env.sh

# Project Generation
./Scripts/generate.sh

# Build Player
xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData build

# Run Player
open DerivedData/Build/Products/Debug/Kinrox.app

# Player Tests
xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData test

# Protocol Tests
swift test --package-path Packages/RemoteProtocol

# Remote Simulator Build & Tests
xcodebuild -workspace Kinrox.xcworkspace -scheme RemoteiOS -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath DerivedData test

# Formatting
xcrun swift-format lint --strict --recursive PlayerMac RemoteiOS Packages Shared

# Landing site preview
python3 -m http.server 8080 --directory site
```

### 8.1. Installing Remote on iPhone with Personal Apple ID

See [signing runbook](docs/runbooks/RUNBOOK-BUILD-AND-SIGNING.md#real-iphone) for device installation commands.

---

## 9. Rules for Agents

1. **English Source Language:** Documentation, code, comments, identifiers, diagnostics, and localization keys remain English. Translated user-facing resources and translation test expectations are permitted (owner request, 2026-10-27).
2. Swift 6 complete concurrency checking (`SWIFT_STRICT_CONCURRENCY = complete`).
3. Single repository branch `main`. Do not create git branches, commits, or git worktrees. Changes are left uncommitted for owner review.
4. UI models use `@Observable` and isolate to `@MainActor`.
5. Max file length is 500 lines. Split large files logically.
6. Verify changes with unit and integration tests before handoff.
7. Set playback volume to 0 within Kinrox during test media verifications; do not touch Mac system volume.
8. Local network operations exclusively, except the Mac player's approved Sparkle appcast check and opt-in Spotify integration (principle 4). No telemetry or analytics.
9. **No WebView:** follow the critical requirements at the top of this document. Never introduce an embedded WebView or browser runtime, including a hidden one, into either application.
10. **Standalone Spotify acceptance:** verify playback and controls with Spotify.app fully terminated, including a cold start of Kinrox in that state. Do not launch Spotify.app as a dependency or workaround. Record latency and memory measurements; tests with Spotify.app running do not establish acceptance of this requirement.

---

## 10. License

Licensing is split by component, authorized by the owner on 2026-11-01:

- Mac player and other default repository material: GNU GPL v3 only (`GPL-3.0-only`),
  with permitted attribution/origin terms in [NOTICE](NOTICE). Commercial use remains allowed.
- New iPhone remote revisions accompanied by [RemoteiOS/LICENSE.txt](RemoteiOS/LICENSE.txt):
  Kinrox Remote Personal Use License 1.0. Personal use, private modifications, and
  free forks with corresponding source are allowed; business/commercial use,
  sales, paid access, and subscriptions are prohibited.
- Kinrox-owned shared code and resources remain GPL, with the explicit
  [shared-code exception](SHARED-LICENSE-EXCEPTION.md) allowing inclusion in the remote.
- [TRADEMARKS.md](TRADEMARKS.md) governs branding within applicable trademark rights.

See [LICENSING.md](LICENSING.md) for exact path scope and contribution requirements.
Earlier GPL releases and independently granted GPL rights remain unchanged.
Third-party licenses are not altered. Do not describe the remote as GPL or OSI
open source, or apply remote restrictions to the Mac player. Store rollout is
separate; see [AppStore/LICENSE-ROLLOUT.md](AppStore/LICENSE-ROLLOUT.md).

---

## 11. Open Questions and Risks

### Owner Decisions
- Update distribution mechanism — decided 2026-10-29: Sparkle 2 (Option A). EdDSA signing key created by the owner on 2026-10-29 ([runbook](docs/runbooks/RUNBOOK-RELEASE.md#update-signing-key)); first shipped in Mac 0.3.0 on 2026-10-30.
- Target architectures: Apple Silicon (arm64) primary; Intel x86_64 deferred.

### Technical Risks
- Release builds use pinned portable libmpv dependencies. Default Homebrew development libraries still require macOS 26; do not use them in the macOS 14 distribution bundle.
- Local Network permission prompts on iOS require explicit Info.plist keys.
