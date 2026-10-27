# Contributing to Kinrox

Kinrox focuses on local video playback on macOS and a native iPhone remote.
Before proposing a change, read the scope and architecture in [AGENTS.md](AGENTS.md)
and the relevant task in [docs/TODO](docs/TODO).

## Getting Started

Follow the [README](README.md#requirements) and
[build and signing runbook](docs/runbooks/RUNBOOK-BUILD-AND-SIGNING.md).
Use your own signing team, provisioning profiles, and bundle identifier prefix
in `Config/Signing.local.xcconfig`. Never include that file or signing credentials
in a contribution. Generated `.xcodeproj` files are ignored; edit `project.yml`
and regenerate them with `./Scripts/generate.sh`.

## Proposing a Change

- Use issues for reproducible bugs and feature proposals. Include the app version,
  macOS or iOS version, reproduction steps, and expected and actual behavior.
- Discuss changes to product scope, the wire protocol, dependencies, or distribution
  before starting a large implementation.
- Submit focused pull requests from your fork. Explain the problem, resulting
  behavior, tests run, and any remaining limitations.
- Remove tokens, PINs, personal file paths, and device identifiers from shared
  logs and screenshots. Use [SECURITY.md](SECURITY.md) for sensitive reports.

The owner's checkout and automated agents follow the repository workflow in
[AGENTS.md](AGENTS.md). Do not create commits, branches, or worktrees there unless
the owner explicitly requests them.

## Implementation and Validation

Use Swift 6 with complete concurrency checking. UI models use `@Observable` and
`@MainActor`. Keep source files under 500 lines and keep documentation, identifiers,
comments, diagnostics, and localization keys in English. Translated user-facing
strings belong in `Resources/Localization`.

Use [the verification runbook](docs/runbooks/RUNBOOK-TASK-TESTS.md) to select tests
for the touched area. In particular:

- Protocol or transport changes: run `swift test --package-path Packages/RemoteProtocol`.
- App changes: build and test the affected Xcode scheme.
- Localization changes: run `python3 Scripts/check-localization.py`.
- Swift changes: run the formatting check documented in the README.
- Documentation changes: verify links and commands against the current source.

Add regression coverage for behavior fixes. Tests involving video must set volume
to zero inside Kinrox and leave the Mac system volume unchanged. State clearly when
signing, hardware, simulator, or local network constraints prevent a check.

Kinrox uses GPL-3.0-only; see [LICENSE](LICENSE). Identify the origin and applicable
license of any third-party code or assets included in a contribution.
