# Kinrox

Kinrox is a minimalist video player for macOS with a native iPhone remote.
Open a movie on your Mac and control it from the couch over your local network.
No cloud, user accounts, analytics, or telemetry.

## Features

- Local video playback, including MP4 and MKV, powered by libmpv, OpenGL,
  and VideoToolbox hardware acceleration.
- Glass controls, keyboard shortcuts, native fullscreen, and drag-and-drop.
- Recent files, naturally sorted folder playlists, and automatic next-file playback.
- System media keys and Now Playing integration.
- iPhone discovery over Bonjour, six-digit PIN pairing, encrypted commands,
  Keychain token storage, and reconnection.
- Remote playback, seeking, volume, fullscreen, and recent-file controls.
- Shared localization in 30 languages with English fallback.

## Project Status

This is a source release of an in-development project. The Mac player and real
iPhone remote are implemented through M5; verification results and remaining
limitations are recorded in the [M5 report](docs/runbooks/M5-VERIFICATION.md).
Standalone libmpv bundling, Developer ID distribution, notarization, and DMG
creation are planned for M6. Development builds currently load libmpv from Homebrew.

The `kinrox-cli` executable is a stub; its implementation is an
[optional task](docs/TODO/05-kinrox-cli.md). Track selection, network streams,
custom playlists, and playback position memory are outside the initial scope.
Architecture and roadmap are in [AGENTS.md](AGENTS.md).

## Requirements

Requires Xcode 26.5, Swift 6, and XcodeGen 2.46.0 or newer. Minimum deployment
targets — macOS 14 and iOS 17. Builds target arm64.
Player requires libmpv and headers in `/opt/homebrew`, test media requires ffmpeg.
Scripts do not install dependencies automatically. Current Homebrew libmpv is built for macOS 26:
macOS 14 support must be validated with standalone compiled libraries in M6.

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
Debug argument `-KinroxScreen pairing|remote|recents` functions only alongside
`-KinroxDemo`. Network errors never switch the app into demo mode.
Installation and tests on a physical iPhone — [per runbook](docs/runbooks/RUNBOOK-BUILD-AND-SIGNING.md#real-iphone).

Generated `.xcodeproj` files are git-ignored. After modifying `project.yml`,
rerun `./Scripts/generate.sh`. Common configuration is in
`Config/Shared.xcconfig`: Swift 6, complete strict concurrency, and OS versions.
App Intents metadata extraction is disabled as no intents are present.

Since M4.4, Mac requires Apple Development signing and a macOS provisioning profile for Data Protection
Keychain. For iOS simulator, a developer team is not required. Personal template is
`Config/Signing.local.xcconfig.example`; file `Signing.local.xcconfig` is git-ignored.
Platform signing configurations are defined in `Config/PlayerMac.xcconfig` and
`Config/RemoteiOS.xcconfig`, including shared and local configs.
For custom Bundle IDs, specify `KINROX_BUNDLE_ID_PREFIX` in personal config;
app and test suffixes remain intact, common `PRODUCT_BUNDLE_IDENTIFIER` is not required.
`Config/MPV.xcconfig` is linked to Mac project; MPVKit resides inside PlayerMac.
The verified development setup uses mpv 0.41.0. `pkg-config --modversion mpv`
reports `2.5.0` — libmpv client API version. Headers reside in
`/opt/homebrew/include/mpv`. Dylibs are currently loaded from Homebrew; bundling is M6.
Library validation is temporarily disabled for Homebrew dylibs. Mac distribution
via Developer ID, notarization, and DMG is scheduled for M6.

## Design

All design work is done in Figma file
[Kinrox — Design](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U):
[01 · UI v1 — Player & Remote](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox-%E2%80%94-Design?node-id=0-1)
and [02 · M4 — Connection & states](https://www.figma.com/design/vvWQ5IQdSuOFw2BebZkS8U/Kinrox-%E2%80%94-Design?node-id=13-352).
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

`site/` holds the GitHub Pages landing in English and Russian: plain HTML and CSS,
no build step, no analytics. Preview locally:

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

Kinrox is open source under GNU GPL v3
(`GPL-3.0-only`). The license applies to player, remote, shared packages,
and scripts. Full text in [LICENSE](LICENSE).
Third-party libraries retain their respective licenses.
