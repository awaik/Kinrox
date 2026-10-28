# Kinrox Runbooks

The runbooks describe repeatable procedures and verification suites for implemented milestones M1–M3, M4.1–M4.4, and M5. System architecture, milestone boundaries, and development rules remain in [AGENTS.md](../../AGENTS.md).
All commands execute from the repository root.

By owner decision on 2026-10-27, M4 is completed in scope M4.1–M4.4;
`kinrox-cli` (former M4.5) is an [optional task](../TODO/05-kinrox-cli.md)
that does not block M6 or release builds. Historical references to M4.5 in older reports
reflect previous planning rather than current acceptance criteria.

| Task | Runbook |
|---|---|
| Prepare environment, build, launch, and configure personal code signing | [Build and Signing](RUNBOOK-BUILD-AND-SIGNING.md) |
| Select test suites for a task and verify results | [Task Verifications](RUNBOOK-TASK-TESTS.md) |
| View playback verification results and constraints | [M1 Verification](M1-VERIFICATION.md) |
| View system media keys verification results and constraints | [M3 Verification](M3-VERIFICATION.md) |
| Verify models, JSON codec, and reference fixtures | [M4.1 Verification](M4.1-VERIFICATION.md) |
| Review handshake cryptographic specification agreement | [M4.2 Specification Review](M4.2-SPEC-REVIEW.md) |
| Verify CryptoKit primitives, state machines, and independent vectors | [M4.2 Verification](M4.2-VERIFICATION.md) |
| Verify Bonjour, WebSocket, and encrypted local exchange | [M4.3 Verification](M4.3-VERIFICATION.md) |
| Review transport review findings and regression coverage | [M4.3 Review](M4.3-REVIEW.md) |
| Verify player server, UI, signing, and Data Protection Keychain | [M4.4 Verification](M4.4-VERIFICATION.md) |
| Verify real remote, Keychain, and iPhone testing boundaries | [M5 Verification](M5-VERIFICATION.md) |
| Review remote review findings and regression coverage | [M5 Review](M5-REVIEW.md) |
| Build, sign, notarize, verify, and publish a standalone Mac installer | [Mac Release](RUNBOOK-RELEASE.md) |
| Inspect release packaging, startup regression, and validation boundaries | [M6 Verification](M6-VERIFICATION.md) |
| Evaluate external code reviews and apply justified corrections | [Code Review Process](RUNBOOK-REVIEW.md) |

When modifying commands, configuration, or acceptance criteria, update the corresponding runbook in the same task. Mac distribution uses the M6 release workflow; the iPhone App Store release remains separate.
