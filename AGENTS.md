# Kinrox — Master Project Specification

> This document is the source of truth for any agent or developer. Read it completely before beginning work.
> Documentation, specifications, code comments, identifiers, diagnostics, and source keys remain English. User-facing localization resources may contain translations, authorized by the owner on 2026-10-27.
>
> **Status:** M1 implemented 2026-10-25: libmpv + OpenGL, opening via ⌘O, playback of MP4/MKV, events and clean teardown. MPVKit placed inside PlayerMac with bridging header per owner confirmation. Checks and limitations — [M1 Report](docs/runbooks/M1-VERIFICATION.md).
> M2 implemented 2026-10-26 in design from Figma: controls panel, shortcuts, fullscreen, drag-and-drop, menus, recent files, folder playlist and auto-advance. Remote screens (M5) built in advance on demo data, without network; server and protocol — M4.
> M3 implemented 2026-10-26: MediaPlayer system commands, "Now Playing", artwork, and teardown cleanup. Automated tests and manual limits — [M3 Report](docs/runbooks/M3-VERIFICATION.md).
> M4.1 implemented 2026-10-26 and handed off for review: message models, JSON codec, version negotiation, and reference JSON fixtures. Checks — [M4.1 Report](docs/runbooks/M4.1-VERIFICATION.md).
> M4.2 implemented 2026-10-26 after dedicated specification approval (§6.5.1): CryptoKit, handshake state machines, protected frames, and independent test vectors. Checks — [M4.2 Report](docs/runbooks/M4.2-VERIFICATION.md).
> M4.3 implemented 2026-10-26 after M4.2 review: Bonjour, Network.framework WebSocket, secure exchange, heartbeat, and local subnet enforcement. Player integration — M4.4; [M4.3 Report](docs/runbooks/M4.3-VERIFICATION.md).
> M4.4 implemented 2026-10-27: server connected to player, remote preferences and real PIN, tokens in Data Protection Keychain. Team signing with macOS profile configured, pairing and revocation verified. Results and limitations — [M4.4 Report](docs/runbooks/M4.4-VERIFICATION.md). M4 accepted by owner task assignment for M5 on 2026-10-27; transition authorized.
> M4 completed in scope M4.1–M4.4. By owner decision 2026-10-27 `kinrox-cli` (former M4.5) moved to [a separate optional task](docs/TODO/05-kinrox-cli.md); its absence does not block M6 or app release.
> M5 implemented 2026-10-27: real remote, Bonjour, Keychain, control, and reconnection. Automated tests passed; owner confirmed manual checklist of Mac + physical iPhone: "Double-checked everything, everything works." Results and remaining limitations — [M5 Report](docs/runbooks/M5-VERIFICATION.md). Changes ready for review; M6 not yet started.
> Tasks for contributors (M3, M4, localization, updates) — in [docs/TODO](docs/TODO/).
> All design work is done in Figma file [Kinrox — Design](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U) (owner decision 2026-10-27), see Section 3.5.
> Landing site added 2026-10-27: static GitHub Pages site in `site/` (English + Russian), deployed by `.github/workflows/pages.yml`; see Section 3.6.
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
| git | 2.51.2. Local repository, sole branch `main`; changes left uncommitted for review, no remote configured |
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
| Remote Control | Protocol server (Section 6) |

### 2.2. iPhone Remote

Discovery of players on local network, PIN pairing, controls: pause, ±10/±30s, scrub to position, volume, next/previous file, open from recents, fullscreen. Detailed in Section 6.

### 2.3. Excluded from v1

In-UI audio/subtitle track selectors (mpv renders default embedded subtitles automatically), playback position memory, custom playlists, network streams and URLs, YouTube (`ytdl` disabled), video filters and custom shaders, custom cover art, picture-in-picture, iPad/Apple Watch remote targets, multi-player simultaneous routing.

---

## 3. Architecture and Repository Structure

### 3.1. Components

- **PlayerMac** — macOS application (SwiftUI + AppKit). Contains **MPVKit** — wrapper around C API of libmpv in a subdirectory inside PlayerMac with bridging header (approved by owner 2026-10-25, see 3.3).
- **RemoteiOS** — iPhone remote application (SwiftUI).
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
├── .gitignore
├── .swift-format                 # formatting rules
├── Kinrox.xcworkspace            # unites both applications and shared package
├── Resources/
│   └── Branding.xcassets         # logo and design tokens (bg/*, text/*, accent/* …) for both apps
├── Shared/                       # Swift files compiled into both applications
│   ├── Design/KinroxTheme.swift  # Palette, KinroxFont, kinroxGlass — Figma tokens (3.5)
│   └── TimeFormat.swift          # "0:42:15", "−1:15:48"
├── Config/
│   ├── Shared.xcconfig           # common settings, OS deployment targets, Swift 6
│   ├── PlayerMac.xcconfig        # Mac signing + shared settings
│   ├── RemoteiOS.xcconfig        # iOS automatic signing + shared settings
│   ├── MPV.xcconfig              # libmpv search paths and library flags
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
│   │   ├── Settings/
│   │   ├── Resources/
│   │   └── Info.plist
│   └── RemoteiOSTests/
├── Packages/
│   └── RemoteProtocol/
│       ├── Package.swift
│       ├── Sources/
│       │   ├── RemoteProtocol/   # Message, Command, PlayerState, Codec, Version, Crypto
│       │   ├── RemoteTransport/  # BonjourAdvertiser, BonjourBrowser, Server, Client
│       │   └── kinrox-cli/       # CLI diagnostic tool
│       └── Tests/
│           ├── RemoteProtocolTests/
│           └── RemoteTransportTests/
├── docs/runbooks/                # build, signing, and verification runbooks
├── site/                         # static landing page for GitHub Pages (3.6)
│   ├── index.html                # English, default
│   ├── ru/index.html             # Russian
│   └── assets/                   # css, js, Figma icons and stills, remote screenshots
├── .github/workflows/pages.yml   # deploys site/ to GitHub Pages
├── Scripts/
│   ├── check-env.sh              # environment verification script
│   ├── generate.sh               # project generator
│   ├── capture-landing-screenshots.sh # remote screenshots for site/
│   └── bundle-libmpv.sh          # dylib packaging in .app (M6)
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

Working with the file:
- new screens and states are designed in this file before implementation; existing pages follow `NN · <milestone> — <topic>`;
- mockup copy in Figma is currently Russian; app source strings stay English (Section 9);
- for the Figma MCP server: page ids `0:1` and `13:352`, component library in section `3:2`.

Design tokens reside in `Shared/Design/KinroxTheme.swift` and `Resources/Branding.xcassets`.
Liquid Glass aesthetic with fallback materials on pre-macOS 26 systems. System fonts: SF Pro and SF Pro Rounded.

### 3.6. Landing Site

Static page in `site/`, published to GitHub Pages by `.github/workflows/pages.yml`
(repository Settings → Pages → Source: GitHub Actions). No build step, frameworks, external fonts,
analytics, or cookies, in line with principle 4. English is the default page, Russian lives in `site/ru/`.

- First screen states the pain: getting up to pause a movie playing from a MacBook on a projector.
  The hero illustration `site/assets/img/scene.svg` shows a person on a couch with an iPhone,
  a MacBook and a projector; the real remote screenshot sits next to it.
- iPhone screenshots are captured from the real app in demo mode by `Scripts/capture-landing-screenshots.sh`.
- Mac screens are HTML recreations of Figma frames 5:23 and 6:215 using real localized app strings.
- Icons and video stills are exported from the Figma component library.
- Claims on the page must match shipped behavior. Until M6 the page links to source and releases on GitHub
  instead of a download. Details — [site/README.md](site/README.md).

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

```swift
public protocol PlayerEngine: AnyObject, Sendable {
    @MainActor func load(url: URL)
    @MainActor func play()
    @MainActor func pause()
    @MainActor func togglePause()
    @MainActor func seek(to position: Double)
    @MainActor func seek(by delta: Double)
    @MainActor func setVolume(_ volume: Double)
    @MainActor func stop()
}
```

UI components and remote server interact with `MPVPlayer` exclusively through this interface.

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
- Message types:
  - `hello` / `helloAck`: initial version negotiation;
  - `key` / `keyAck`: X25519 public keys and salt exchange;
  - `pairProof` / `paired`: PIN validation and token generation;
  - `auth` / `authOk`: token authentication;
  - `command` / `ack`: control commands and acknowledgements;
  - `state`: player playback state snapshot;
  - `recent`: recent files list;
  - `error`: protocol or application errors;
  - `bye`: clean disconnection.

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

1. **Transcript:** Both endpoints accumulate a canonical binary transcript:
   - `clientHello` + `serverHelloAck` + `clientKey` + `serverKeyAck`.
2. **Key Derivation (HKDF-SHA256):**
   - Ephemeral shared secret `Z = X25519(clientPrivate, serverPublic)`.
   - `PRK = HKDF-Extract(salt: transcriptHash, IKM: Z)`.
   - `K_c2s = HKDF-Expand(PRK, info: "kinrox c2s key", L: 32)`.
   - `K_s2c = HKDF-Expand(PRK, info: "kinrox s2c key", L: 32)`.
   - `K_confirm = HKDF-Expand(PRK, info: "kinrox confirm key", L: 32)`.
3. **PIN Proof:**
   - `K_pin = HKDF-Expand(PRK: K_confirm, info: "pin:" + PIN, L: 32)`.
   - `clientProof = HMAC-SHA256(K_pin, transcript)`.
   - Server verifies client proof, generates auth token, derives `serverProof`, and returns encrypted `paired` frame.
4. **Token Authentication:**
   - For subsequent connections: `K_auth = HKDF-Expand(PRK: K_confirm, info: "token:" + token, L: 32)`.
   - Mutual verification via HMAC-SHA256 proofs.
5. **Encrypted Frames:**
   - ChaCha20-Poly1305 AEAD with directional keys (`K_c2s`, `K_s2c`).
   - 96-bit big-endian monotonic frame counters starting at 0. Replay or omission terminates connection.

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
- Upcoming: Bundle libmpv and dependencies into `Kinrox.app`, Developer ID signing, notarization, DMG creation.

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
8. Local network operations exclusively; no external internet queries, telemetry, or analytics.

---

## 10. License

Kinrox is published under GNU General Public License v3 (`GPL-3.0-only`).
The license covers the Mac player, iPhone remote, shared packages, and repository scripts.
Full text is located in [LICENSE](LICENSE).

---

## 11. Open Questions and Risks

### Owner Decisions
- Update distribution mechanism (Option A: Sparkle 2 recommended).
- Target architectures: Apple Silicon (arm64) primary; Intel x86_64 deferred.

### Technical Risks
- Homebrew libmpv deployment target warning resolved during M6 packaging.
- Local Network permission prompts on iOS require explicit Info.plist keys.
