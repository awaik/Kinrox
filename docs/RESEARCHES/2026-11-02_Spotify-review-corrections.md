# Spotify performance change review — 2026-11-02

Review scope: the nine supplied findings about the uncommitted SQLite cache and latency
implementation. No release, deployment, live Spotify mutation or unrelated refactoring.

| Finding | Assessment and correction |
|---|---|
| Major 1: saved albums lose paginated tracks | Confirmed. Embedded first pages preserve an existing complete, longer track list. A first-page-only cache loses its completeness marker and remains eligible for pagination. Freshness is not extended by a partial response. |
| Major 2: HTTP cancellation stops at an unstructured task | Confirmed. Non-coalesced requests execute in the caller task. Shared reads have independently cancellable continuations; removing the last subscriber cancels the HTTP task. A generation ID prevents an older completion from removing a replacement read. Cancellation is checked again after token acquisition. |
| Major 3: seek/end state | All three scenarios confirmed. Paused seeks cannot trigger advancement or EOF, including through a later paused observation. Rewind and confirmed playing states rearm EOF detection. Equal track URIs cannot by themselves confirm a transition after seeking; distinct next-track confirmation also requires a near-start position. |
| Major 4: insertion confirms a rewritten paused context | Confirmed, also in the repeat-only fast path. Both retain an unconfirmed context until an explicit positioned start. The 10,000-occurrence limit is checked before incremental queue writes. |
| Major 5: playlist selection and row publication | Confirmed. Selection requests playlist readiness and shares any existing load. Library changes as well as catalog changes refresh browser rows outside full synchronization. |
| Minor 1: Retry during normal refresh | Confirmed. Retry is hidden while refresh is active. |
| Minor 2: disconnected favorite buttons | Confirmed. Album/source/header buttons use canMutate. The header previously had no disabled modifier, rather than an isMutating modifier. |
| Minor 3: demo pause resets elapsed progress | Confirmed. Pause saves displayedPosition before stopping the monotonic clock. |
| Minor 4: first-page ETag reused for a full collection | Confirmed. Paginated resource results do not retain a first-page validator. Single-page conditional reads remain supported. |

The security observations were not actionable findings and did not require changes to OAuth,
Keychain, cache permissions or the iPhone network boundary. This is not a new comprehensive
security audit.

## Regression evidence

Before the fixes, new package tests failed for cancellation (both live and shared reads) and
multi-page ETags. The Mac regression run failed with ten assertions covering seven tests:
partial albums, playlist selection, paused EOF, duplicate occurrences, rewind, both incremental
queue paths, and demo progress. These are behavior tests through the existing HTTP fixtures,
not live Spotify calls.

Additional tests cover cancellation of a queued request, slot release after the last subscriber,
isolated cancellation while another subscriber waits, warm-resume EOF rearming and the queue
size boundary. UI disabled/retry modifiers are checked through compilation and strict lint;
no tests assert exact visual styling.

The initial Mac build in the existing DerivedData directory found stale MusicCore modules.
A fresh DerivedData/ReviewFix20261102 build avoids the conflict without deleting artifacts.

## Limitations

No live Spotify or physical-iPhone verification. Consecutive equal URIs remain ambiguous when
Spotify skips the observable seek position and only reports the next identical occurrence.
The client declines to infer an occurrence transition from that ambiguous response. Existing
confirmation timeout/recovery behavior applies. No iOS or protocol behavior was changed.

## Validation results

- Full PlayerMacTests: 217 tests in 43 suites passed after the behavior fixes.
- Final focused SpotifyLibraryTests run, including the two additional boundary tests and
  first-page cache repair: 41 tests passed.
- KinroxMusic package: 36 tests in 7 suites passed, including cancellation and ETag regressions.
- Strict Swift lint across PlayerMac, RemoteiOS, Packages and Shared passed.
- `git diff --check` passed. New and edited Swift files remain below 500 lines.

Logs are retained at `/tmp/kinrox-review-mac-green.log`,
`/tmp/kinrox-review-mac-final-albums.log`, `/tmp/kinrox-review-package-final.log`,
`/tmp/kinrox-review-lint-final.log`; Xcode result bundles remain in
`DerivedData/ReviewFix20261102/Logs/Test/`. The failing baseline logs are
`/tmp/kinrox-review-mac-red-fresh.log` and `/tmp/kinrox-review-package-red.log`.
