# Build, Launch, and Local Code Signing

## When to Use

On initial repository setup, after modifying `project.yml` or `Config/*.xcconfig`,
when resolving build failures, or when configuring signing profiles for personal devices.

## Preparation

1. Read [AGENTS.md](../../AGENTS.md), inspect `git status --short`.
2. Run `./Scripts/check-env.sh`. libmpv, headers, and pkg-config are required.
   The script does not install tools automatically. Test media is generated via
   `bash Scripts/make-test-media.sh` using installed ffmpeg.
3. Run `./Scripts/generate.sh`. Project specs are in `project.yml`;
   do not edit generated `.xcodeproj` files manually.

## Build and Execution

Build workspace schemes sequentially:

```sh
xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData build

xcodebuild -workspace Kinrox.xcworkspace -scheme RemoteiOS \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath DerivedData build

open DerivedData/Build/Products/Debug/Kinrox.app
```

To run the remote, open `Kinrox.xcworkspace`, select `RemoteiOS` and iPhone 17, and click Run.
If that simulator is unavailable, select an available device from
`xcrun simctl list devices available` and adjust destination accordingly.
In M1 the player opens video via ⌘O; in M4.4 Mac includes the server, and in M5 iPhone connects by default.
Demo mode is explicitly enabled in remote settings or via `-KinroxDemo`.
An absolute path can be passed as argument:
`open -n DerivedData/Build/Products/Debug/Kinrox.app --args /path/to/video.mkv`.
The path must be the first application argument.

## libmpv in M1–M5

`PlayerMac.xcconfig` includes `MPV.xcconfig` before shared/local configs.
Bridging header is configured only for the application. iOS does not link libmpv.
The Homebrew library is used locally; the [release workflow](RUNBOOK-RELEASE.md)
uses pinned portable libraries and bundles the full dependency graph.
Current Homebrew dylib specifies minimum OS 26.0: linker issues a warning when targeted at macOS 14.0.
Do not silence this warning or treat such builds as validated on macOS 14.

App Sandbox is disabled in v1 by owner decision 2026-10-26.
Homebrew dylibs use `com.apple.security.cs.disable-library-validation`.
Hardened Runtime is configured, but Xcode disables it under ad-hoc signing.
Developer ID distribution and notarization are handled by `Scripts/build-release.sh`.
The distribution app keeps library validation enabled and has no Homebrew runtime dependency.

Logs: Console.app or
`log stream --level info --predicate 'subsystem == "app.kinrox.player"'`.

## Keychain and Mac Signing Since M4.4

M4.4 relies on macOS Data Protection Keychain for paired device token storage.
Local ad-hoc signing (`-`) does not support Keychain access group entitlements.
Mac builds and tests require an Apple Development identity with matching provisioning profile:

```xcconfig
DEVELOPMENT_TEAM = <Team ID>
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
```

Configure personal settings in `Config/Signing.local.xcconfig` (ignored by git).

## Real iPhone

For physical iPhone testing, specify device signing in `Config/Signing.local.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM[sdk=iphoneos*] = <Team ID>
CODE_SIGN_STYLE[sdk=iphoneos*] = Automatic
CODE_SIGN_IDENTITY[sdk=iphoneos*] = Apple Development
```

Run test suite on device:

```sh
xcodebuild -workspace Kinrox.xcworkspace -scheme RemoteiOS \
  -configuration Debug -destination 'id=<iPhone UDID>' \
  -derivedDataPath DerivedData build test
```
