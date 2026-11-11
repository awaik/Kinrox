# Kinrox

**Two native Mac players in one free app: a video player you control from your
iPhone, and a lightweight Spotify player that finds similar tracks and keeps the
music going.** No Kinrox account, no trackers, no analytics. Written in Swift 6
and SwiftUI, with all source code on GitHub.

[Download for Mac (0.5.8, DMG)](https://github.com/awaik/Kinrox/releases/download/v0.5.8/Kinrox-0.5.8-arm64.dmg) ·
[iPhone remote on the App Store](https://apps.apple.com/us/app/kinrox-remote/id6827926471) ·
[Website](https://kinrox.app/) ·
[Blog](https://kinrox.app/blog/)

Mac: Apple Silicon, macOS 14 or later. iPhone: iOS 17 or later.
Signed with Developer ID and notarized by Apple; updates arrive through Sparkle.

## Spotify, natively

A Spotify player for people who do not want a 2 GB desktop client.

- **Similar tracks that keep playing.** Start from any track, artist, album or
  playlist. Kinrox groups suggestions by why they fit — listened together,
  collaborators, your library, genre — and **Listen to similar** keeps adding
  matching music to the queue. **Not interested** hides tracks or artists you
  do not want; listening history stays on your Mac.
- **Works with Spotify.app fully closed.** Audio plays through Spotify Soloist,
  which Kinrox downloads from Spotify at your request.
- **Light.** Native SwiftUI, no WebView or Electron: about 193 MB after 12 hours of
  playback, versus up to 2 GB for the desktop Spotify client.
- **Your library.** Albums, playlists, liked tracks, search, artist and album
  previews, favorites with ⌘Z undo, a local queue with drag and drop, sorting.
- **iPhone controls.** Skip tracks, browse the queue, change volume and toggle
  favorites from the couch.

Requires Spotify Premium, your own Spotify developer Client ID and a personal
[Soloist API key](https://developer.spotify.com/dashboard/soloist). Kinrox guides
you through setup. Similarity data from ListenBrainz/MusicBrainz is on by default
and can be turned off in Settings → Spotify.

## Video player with an iPhone remote

MacBook on the projector or TV, you on the couch.

- **Plays almost anything.** MKV, MP4, MOV, AVI, WebM, TS and more, on libmpv
  (the engine behind mpv and IINA) with VideoToolbox hardware decoding.
- **A remote made for a dark room.** [Kinrox Remote](https://apps.apple.com/us/app/kinrox-remote/id6827926471)
  finds your Mac over Wi-Fi and pairs once with a six-digit code. Play/pause,
  ±10/±30 s, scrubbing, volume, next/previous episode, recent files, fullscreen.
- **Ready for a series.** The folder becomes a playlist in Finder order, and the
  next episode starts automatically.
- **Audio and subtitles.** Embedded and external tracks, found in nested folders,
  with your choice remembered for the next episode.
- **Minimal interface.** Glass controls that hide after three seconds, keyboard
  shortcuts, media keys, Control Center / Now Playing, drag and drop.
- **Matrix screensaver.** Falling green code over a paused movie, started from the
  Mac or the iPhone.

## Privacy

- No Kinrox account, server, analytics or trackers.
- Mac and iPhone talk directly over your local network, encrypted
  (X25519, HKDF-SHA256, ChaCha20-Poly1305). Public addresses and cellular are refused.
- The remote sees titles and durations, never file paths. Videos stay on the Mac.
- Local video and the remote work offline. The internet is used only for the daily
  update check, the optional Spotify connection and the ListenBrainz/MusicBrainz
  similarity you can turn off. The iPhone never calls Spotify.
- 30 languages, including right-to-left layouts.

Details: [privacy policy](https://kinrox.app/privacy/).

## Project Status

Current Mac release: **0.5.8, build 18** ([release notes](docs/releases/0.5.8.md)).
The DMG bundles libmpv and its dependencies; Homebrew is only needed for development.
Users of Mac 0.2.0 or earlier install 0.3.0 manually once to enable update reminders.
The iPhone remote is on the [App Store](https://apps.apple.com/us/app/kinrox-remote/id6827926471)
and can also be built from source.
Spotify setup, limitations and measured performance are in the
[release notes](docs/releases/0.5.8.md) and
[Soloist Verification](docs/runbooks/SOLOIST-VERIFICATION.md).
The Soloist engine is not bundled with Kinrox and needs periodic updates from Spotify.

The `kinrox-cli` executable is a stub; its implementation is an
[optional task](docs/TODO/05-kinrox-cli.md). Network streams,
custom local-video playlists, and playback position memory are outside the initial scope.
Architecture and roadmap are in [AGENTS.md](AGENTS.md).

The folder playlist updates as videos appear or disappear, including Next/Previous
on the iPhone. Temporary download suffixes (`.part`, `.crdownload`, `.!qB`)
are excluded until renamed to a video filename. If a downloader writes directly
to the final filename, Kinrox cannot determine whether that download is complete.
A video arriving after the final EOF check enables Next without starting playback.

## Requirements

Requires Xcode 26.5, Swift 6, and XcodeGen 2.46.0 or newer. Minimum deployment
targets — macOS 14 and iOS 17. Builds target arm64.
Player requires libmpv and headers in `/opt/homebrew`, test media requires ffmpeg.
Scripts do not install dependencies automatically. Current Homebrew libmpv is built for macOS 26.
Distribution instead uses pinned portable libraries; see the
[release runbook](docs/runbooks/RUNBOOK-RELEASE.md). Runtime testing in this session
was on macOS 26.5.2; minimum-version checks cover every bundled Mach-O library.

Install the command-line dependencies if they are not already available:

```sh
brew install xcodegen mpv pkg-config ffmpeg
```

Xcode must be installed and selected as the active developer directory.
Mac remote pairing requires Apple Development signing with a matching macOS
provisioning profile. An iOS simulator build does not require a developer team;
installation on a physical iPhone requires device signing.

## Build and Tests

After cloning, create your local signing configuration if it does not exist:

```sh
cp -n Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
```

Set your own team and bundle identifier prefix in that file, and configure the
Mac provisioning profile per the
[signing runbook](docs/runbooks/RUNBOOK-BUILD-AND-SIGNING.md#keychain-and-mac-signing-since-m44).
Then, from the project root, run sequentially:

```sh
./Scripts/check-env.sh
./Scripts/generate.sh
bash Scripts/make-test-media.sh
swift test --package-path Packages/KinroxMusic
swift test --package-path Packages/RemoteProtocol

xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData build test

xcodebuild -workspace Kinrox.xcworkspace -scheme RemoteiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath DerivedData build test
```

If iPhone 17 is unavailable, choose an installed simulator from
`xcrun simctl list devices available` and update the destination.
The package tests can run independently of app signing. Local transport tests
require local network access. Playback tests use synthetic media with Kinrox's
volume set to zero; do not change the Mac system volume for testing.

Launching the player:

```sh
open DerivedData/Build/Products/Debug/Kinrox.app
```

Open a video via **⌘O**, drag it into the window, or drop onto the Dock icon.
Keybindings: Space — pause, ←/→ — 5s, ⇧←/⇧→ — 30s, ↑/↓ — volume,
⌘←/⌘→ — adjacent file in folder, F or double-click — fullscreen.
Use the caption-bubble button or the **Audio** / **Subtitles** menus to select tracks.
Choose **Screensaver → Matrix** to show falling code over the player. A playing
movie pauses first. The exit hint disappears after three seconds; **Esc** exits
Matrix while preserving the movie's paused position and fullscreen state.
The iPhone remote has a **Screensavers** section with start/stop controls.
See [screensaver verification](docs/runbooks/SCREENSAVER-VERIFICATION.md).
**⌃⌘A** and **⌃⌘S** cycle audio and subtitles. **All files in folder** shows external
tracks from every nested folder, including unmatched files and other episodes.
Choose a common search folder when audio and subtitles are outside the video's folder.
To launch with a file argument:

```sh
open -n DerivedData/Build/Products/Debug/Kinrox.app --args /full/path/to/video.mkv
```

Closing the window tears down the player; ⌘O creates a new window.

To run the remote, open `Kinrox.xcworkspace`, select scheme `RemoteiOS`
and simulator iPhone 17, and click Run. Player scheme is `PlayerMac`,
built application is `Kinrox.app`.

Standard remote launch searches for Macs on the local network. Enable "Remote" in Kinrox
Mac settings, allow local network access on iPhone, select the Mac, and enter the code
from its screen. Subsequent launches authenticate via Keychain token.
Demo mode without Mac is available in remote settings via "Try demo without Mac" button
or launch argument `-KinroxDemo`; real pairings are unavailable in demo.
Debug argument `-KinroxScreen pairing|remote|recents|music|music-queue|music-like` functions only alongside
`-KinroxDemo`. Network errors never switch the app into demo mode.
Installation and tests on a physical iPhone — [per runbook](docs/runbooks/RUNBOOK-BUILD-AND-SIGNING.md#real-iphone).

Generated `.xcodeproj` files are git-ignored. After modifying `project.yml`,
rerun `./Scripts/generate.sh`. Common configuration is in
`Config/Shared.xcconfig`: Swift 6, complete strict concurrency, and OS versions.
App Intents metadata extraction is disabled by default and enabled for RemoteiOS and
RemoteLockScreen to support Lock Screen buttons.

Since M4.4, Mac requires Apple Development signing and a macOS provisioning profile for Data Protection
Keychain. For iOS simulator, a developer team is not required. Personal template is
`Config/Signing.local.xcconfig.example`; file `Signing.local.xcconfig` is git-ignored.
Platform signing configurations are defined in `Config/PlayerMac.xcconfig` and
`Config/RemoteiOS.xcconfig`, including shared and local configs.
For custom Bundle IDs, specify `KINROX_BUNDLE_ID_PREFIX` in personal config;
app and test suffixes remain intact, common `PRODUCT_BUNDLE_IDENTIFIER` is not required.
`Config/MPV.xcconfig` is linked to Mac project; MPVKit resides inside PlayerMac.
The verified development setup uses mpv 0.41.0. `pkg-config --modversion mpv`
reports `2.5.0` — libmpv client API version. Development headers reside in
`/opt/homebrew/include/mpv`. Library validation is disabled for development with
Homebrew dylibs. Distribution uses pinned libraries, signs every dylib with the
same Developer ID, and keeps library validation enabled. See the
[release runbook](docs/runbooks/RUNBOOK-RELEASE.md).

## Design

All design work is done in Figma file
[Kinrox — Design](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U):
[01 · UI v1 — Player & Remote](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox-%E2%80%94-Design?node-id=0-1)
and [02 · M4 — Connection & states](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox-%E2%80%94-Design?node-id=13-352).
Mac track selection follows [04 · Tracks — Audio & subtitles](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox?node-id=30-304).
Tokens from the file live in `Shared/Design/KinroxTheme.swift` and `Resources/Branding.xcassets`.

## Logo and Icons

Master logo is stored in
`Resources/Branding.xcassets/KinroxLogo.imageset/kinrox-logo.png`.
Shared catalog is included in both applications; asset `KinroxLogo` is used
on player and remote splash screens.

App icons are in `Resources/Assets.xcassets/AppIcon.appiconset`
inside each application. For macOS, sizes 16–1024 pixels are provided;
for iOS — an opaque 1024×1024 PNG from which Xcode generates required assets.
PNGs were downscaled from source via `sips -z <size> <size> <source> --out <file>`.
Both `project.yml` specify `AppIcon` via `ASSETCATALOG_COMPILER_APPICON_NAME`.

## Localization

Both apps support 30 locales and follow the system app-language preference, with English as fallback. Translations are shared in `Resources/Localization`.
See [supported languages and verification](docs/TODO/03-localization.md).
Run `python3 Scripts/check-localization.py` after changing user-facing strings.

## Code Style

Format touched Swift files; verify entire tree:

```sh
xcrun swift-format lint --strict --recursive PlayerMac RemoteiOS Packages Shared
```

## Contributing and Security

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, scope, and validation guidance.
The master project specification and agent workflow are in [AGENTS.md](AGENTS.md).
For sensitive vulnerability reports, follow [SECURITY.md](SECURITY.md).

Keep signing settings, certificates, private keys, `.env` files, generated
projects, and build artifacts out of commits. The repository includes a signing
template; each developer supplies their own ignored local configuration.

## Landing Site

`site/` holds the GitHub Pages landing in 30 languages: static HTML and CSS
generated offline from `Website/`, no analytics. It also includes [privacy](site/privacy/index.html)
and [support](site/support/index.html) pages linked from the landing and iPhone app.
Preview locally:

```sh
python3 -m http.server 8080 --directory site
```

Workflow `.github/workflows/pages.yml` deploys it on every push to `main` that touches `site/`
(enable Settings → Pages → Source: GitHub Actions once). Refresh remote screenshots with
`./Scripts/capture-landing-screenshots.sh` after building RemoteiOS for a booted simulator.
Details — [site/README.md](site/README.md).

## Runbooks

Repeatable runbooks are organized in [docs/runbooks](docs/runbooks/README.md):

- [Build, Launch, and Signing](docs/runbooks/RUNBOOK-BUILD-AND-SIGNING.md).
- [Task Verifications](docs/runbooks/RUNBOOK-TASK-TESTS.md).
- [M1 Results and Constraints](docs/runbooks/M1-VERIFICATION.md).
- [External Review Process](docs/runbooks/RUNBOOK-REVIEW.md).

## License

The **Mac player** remains open source under [GNU GPL v3 only](LICENSE), including
commercial use and redistribution under the GPL. Attribution and modified-build
notices are described in [NOTICE](NOTICE); branding follows [TRADEMARKS.md](TRADEMARKS.md).

New **iPhone remote** revisions accompanying [Kinrox Remote Personal Use License 1.0](RemoteiOS/LICENSE.txt)
are free for personal, noncommercial use. Personal modifications and free forks
with corresponding source are allowed; business use, sales, paid access, and
paid subscriptions are prohibited. The remote is source-available, not OSI open source.

Shared material remains GPL-licensed with an [exception](SHARED-LICENSE-EXCEPTION.md)
for inclusion in the remote. Earlier GPL releases retain their original rights;
third-party libraries retain their own licenses. See [the scope and transition](LICENSING.md).
