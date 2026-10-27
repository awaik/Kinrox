# Task Verifications

## Selecting Verifications

Before making code edits, review [AGENTS.md](../../AGENTS.md), touched files, and corresponding test suites.
Per owner directive (2026-10-26), volume must be set to minimum **within Kinrox itself** during all playback checks; do not change Mac system volume.
Automated tests with libmpv set `volume = 0` prior to loading files.

| Touched Area | Verification Scope |
|---|---|
| Documentation Only | Links, commands, consistency with code and milestone |
| RemoteProtocol / RemoteTransport | Package test suite; consumer app builds if public API changed |
| PlayerMac | Build and test PlayerMac; manual launch if UI modified |
| RemoteiOS | Build and test RemoteiOS; manual launch if UI modified |
| project.yml / Config / generator | Project generation, Debug/Release build settings, both app scheme builds and tests |
| Swift or Scripts | Corresponding test suites, Swift format lint, shell syntax checks, line length ceiling |

## Complete Verification Cycle

With M4.4, ensure Mac signing is configured with matching provisioning profile per
[build runbook](RUNBOOK-BUILD-AND-SIGNING.md#keychain-and-mac-signing-since-m44).

```sh
./Scripts/check-env.sh
./Scripts/generate.sh
bash Scripts/make-test-media.sh
swift test --package-path Packages/RemoteProtocol

xcodebuild -workspace Kinrox.xcworkspace -scheme PlayerMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData build test

xcodebuild -workspace Kinrox.xcworkspace -scheme RemoteiOS \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath DerivedData build test

xcrun swift-format lint --strict --recursive PlayerMac RemoteiOS Packages Shared
bash -n Scripts/check-env.sh Scripts/generate.sh Scripts/make-test-media.sh

find . \( -name '*.swift' -o -name '*.h' -o -name '*.sh' -o -name '*.yml' -o -name '*.xcconfig' \) \
  -not -path '*/.build/*' -not -path '*/DerivedData/*' \
  | xargs wc -l | awk '$1 > 500 && $2 != "total"'
```

All commands must terminate successfully with `TEST SUCCEEDED`, and lint/line checks must exit cleanly.

## Manual Testing Checklist

Physical iPhone + Mac testing covers:
1. Discovery and 6-digit PIN pairing.
2. Playback commands (play, pause, seek forward/back, slider scrub, volume).
3. Monotonic position tracking without skips.
4. Recent files sheet loading and opening.
5. Reconnection without PIN after app restarts.
6. Background/foreground lifecycle.
7. Wi-Fi disconnect and reconnect tolerance.
8. Server shutdown and unpairing/revocation via Keychain.
