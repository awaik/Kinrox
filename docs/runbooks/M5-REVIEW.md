# M5 Review Analysis

Date: 2026-10-27. Corrections applied on top of uncommitted M5 implementation on `main`.
Uncommitted changes preserved; no commits or extra branches created.

## Decisions on Comments

| No. | Assessment | Fix and Scope |
|---|---|---|
| 1 | Confirmed | Bonjour discovery is asynchronous; absence of immediate result was prematurely counted as a failed attempt. Initial discovery wait accommodates up to 10 seconds before backoff. Found server triggers immediate auth/pair. Overall 120-second timeout preserved. |
| 2 | Confirmed | Selection persists only when a valid token exists or after successfully writing a new token to Keychain. Launch discards stale selection without token; tokens preserved. |
| 3 | Confirmed | `select` ignores `.unavailable` rows prior to triggering state side-effects. Context menu retains "Forget this Mac" action. |
| 4 | Confirmed | Command completion explicitly notifies outcome via callback upon ack, error, timeout, synchronous rejection, send failure, or cancellation. Sheet dismisses only on successful ack; error displayed inline. |
| 5 | Confirmed | Stopped discovery restarts upon reconnect attempt and network recovery. Active browser untouched; background state inhibits discovery. |
| 6 | Confirmed | Pairing screen retries pair directly, including following incompatible version errors; main remote view retains auth. |
| 7 | Confirmed | Auth rejection acts before command replyTo timeout lookup, disconnecting controls and recording failure while preserving stored token. |
| 8 | Confirmed | Background task termination unified: successful bye, watchdog timer, and background lease expiration share single completion callback. |

## Verification

Automated tests across all suites, real iOS Keychain, and TransportClient executed on physical iPhone: **43 tests across 8 suites passed, TEST SUCCEEDED**. Swift formatting and file limit checks passed.
