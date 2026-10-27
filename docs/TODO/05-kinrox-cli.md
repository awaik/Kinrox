# Optional Task — kinrox-cli for Development and Diagnostics

> **Status:** Postponed, implementation not started; stub remains in the package.
> **Owner Decision from 2026-10-27:** Former subtask M4.5 has been extracted
> from the mandatory scope of M4. M4 is completed in scope M4.1–M4.4; the CLI does not block
> M6 or application releases. Commencing implementation is a separate owner task.
> **Assignee:** Agent or developer. **Review & commit:** Owner.

## Purpose

The console client allows testing the Mac server without an iPhone, reproducing bugs
with specific commands, and automating verifications. The Mac and iPhone applications
use RemoteTransport directly and do not depend on the CLI. Currently, the server is verified
by TransportClient integration tests and the real iOS remote.

## Scope of Future Implementation

Sources: `Packages/RemoteProtocol/Sources/kinrox-cli/`.
The existing executable target in Package.swift is preserved. The commands below are planned;
the current stub does not execute them.

- `discover` — find players via Bonjour and display their identifiers and names;
- `pair` — select a Mac, prompt for PIN in the terminal, and save the pairing;
- `toggle-pause`, `seek ±N`, `seek-to N`, `volume N`, `next`, `previous` — playback control;
- `watch` — receive and print state updates until Ctrl+C.

Use existing RemoteProtocol and RemoteTransport: no secondary codec,
no new cryptography, and no protocol version changes for the sake of the CLI. Provide explicit
Mac selection when multiple servers exist, along with a stable client deviceId.

Token — in Keychain with `service = "app.kinrox.cli.servers"`, `account = serverId`.
When implementing, verify macOS requirements for access from a console executable
and its signing; do not weaken application storage for the sake of running the CLI.
Never print PIN, tokens, or keys in diagnostic output, and never store them in regular files.
Output must be human-readable; errors contain protocol codes and non-zero
exit codes. Ctrl+C cleanly terminates connection and discovery.

## Acceptance Criteria for Future Task

1. Discovery -> PIN -> command -> state works with real PlayerMac.
2. Restarting client and player preserves ability to authenticate without a new PIN.
3. Unrecognized/revoked tokens are rejected; "Forget" on Mac revokes CLI access.
4. Invalid arguments, ambiguous Mac selection, missing server, timeouts,
   and protocol errors terminate clearly with appropriate exit codes.
5. Command parsing tests and significant error handling tests, transport integration checks,
   consumer builds, and runbook checks pass cleanly.

## Work Rules

Before implementation, read [AGENTS.md](../../AGENTS.md),
[test runbook](../runbooks/RUNBOOK-TASK-TESTS.md), and
[signing runbook](../runbooks/RUNBOOK-BUILD-AND-SIGNING.md).
Work in the existing `main`, preserve other changes, do not create git commits.
Local network only, no new third-party dependencies; Swift 6 strict concurrency.
During playback tests set volume to 0 in Kinrox, leave system volume untouched.
Upon completion, document factual verifications and limitations in a separate report;
do not rewrite historical reports of M4 and M5 as if the CLI existed at that time.
