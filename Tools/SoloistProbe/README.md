# Soloist feasibility probes

These tools implement distribution inspection and the protected S0 probe in the
[active implementation plan](../../docs/RESEARCHES/2026-11-02_10-34_Standalone-Spotify-research-brief.md).
They are not a production installer, playback engine, or product acceptance suite.
Production playback now uses the native Soloist integration by default. Historical
probe results below describe the evidence collected before that cutover; final
acceptance and owner waivers are in the [verification report](../../docs/runbooks/SOLOIST-VERIFICATION.md).

No global packages are required. Use a fresh ignored directory for each attempt;
failed attempts are retained. Never commit, bundle, upload or redistribute the
downloaded Spotify archive or executable. Spotify's
[download policy](https://developer.spotify.com/documentation/soloist/reference/downloads-and-updates)
requires users to obtain their own distribution.

```sh
python3 Tools/SoloistProbe/inspect_distribution.py build/soloist-probe/<run>/distribution
```

The inspector restricts HTTPS redirects to the reviewed Spotify CDN, caps download
and expanded size at 256 MiB and headers at 1,000, rejects links/special files and
path escapes, extracts only the binary with non-executable permissions, and saves
SHA-256, architecture, Mach-O load commands, dependencies, signature and Gatekeeper
results. It does not execute Spotify code. Inspect every result before proceeding.
The limits are probe safety bounds, not app resource budgets.

For the distribution inspected on 2026-11-02, the signature identifies Spotify
Team `2FNC3A47ZF`, independently corroborated by a strict signature check of the
installed Spotify.app. After verifying that identity:

```sh
codesign --verify --strict '-R=anchor apple generic and certificate leaf[subject.OU] = "2FNC3A47ZF" and identifier "com.spotify.soloist"' build/soloist-probe/<run>/distribution/soloist
chmod 700 build/soloist-probe/<run>/distribution/soloist
build/soloist-probe/<run>/distribution/soloist --version
build/soloist-probe/<run>/distribution/soloist --help
python3 Tools/SoloistProbe/sentinel_probe.py build/soloist-probe/<run>/distribution/soloist build/soloist-probe/<run>/sentinel
```

The sentinel runner cannot accept a real API key. It launches a directly owned
child with a fixed invalid marker, private new profile/cache, initial gain zero,
200 MB cache limit and ephemeral loopback listener. It checks only that child's
argv, records a boolean exposure result, verifies listener ownership with `lsof`,
and attempts an unauthenticated WebSocket upgrade with a foreign Origin. Child
termination uses the retained process handle, never a PID read from disk.
It records Spotify.app presence throughout but does not launch or quit that app.
Its RSS samples are **unauthenticated probe RSS**, not physical footprint, decoder
memory, a Release Kinrox baseline or a playback performance result.

The sentinel's raw diagnostics are safe only because its key is a fixed invalid
marker and its profile is new. Do not adapt that logging path for real credentials.
Real-key work requires the plan's G0 exception and a separate protected runner.
Do not put a real key in shell history, this README, logs, tool inputs or chat.

```sh
python3 -m unittest discover -s Tools/SoloistProbe -p 'test_*.py'
```

Local evidence for the first run is under
`build/soloist-probe/20261102T094052Z/`. The authoritative status and unresolved
gates remain in the implementation plan. The standalone CLI shape produces `spctl` exit 3, but the later strict publisher
check with `codesign --check-notarization` passed. A task-owned quarantined copy
executed `--version` with quarantine retained; the native installer subsequently
passed a fresh download/signature/notarization/quarantine/version check. No binary
was re-signed and no OS security setting was changed. The owner permanently
excluded a separate macOS 14 runtime test on 2026-11-03; only minimum-OS metadata
and deployment targets are checked for that version.

## Protected live probe (owner authorized 2026-11-03)

The native Swift harness lives in `PlayerMac/PlayerMacTests/SoloistProbe/` and is
compiled into the test bundle only. Ordinary tests skip it. Use the signed Mac
test host to access Data Protection Keychain; do not pass the key to xcodebuild,
Python, an environment variable or this tool's command line.

The first run opens an `NSSecureTextField`, includes the official key-page link
and Premium requirement, and saves under service `app.kinrox.spotify.soloist-key`,
account `feasibility-probe-v1`, with `AfterFirstUnlockThisDeviceOnly`. Subsequent
runs use that entry. The owner authorized Soloist's argv exposure on 2026-11-03.
The key is sent only to the verified Spotify child. Raw child stdout/stderr are
discarded; traces whitelist flags, command names, timing and numeric positions.
Track URIs, names, user IDs, error text and credentials are never persisted.

Compile `reaper.c` and `resources.c` with `xcrun clang -O2 -Wall -Wextra -Werror
-mmacosx-version-min=14.0`. The reaper receives only the child PID and binary path,
records its owner/start identity, and watches an inherited lifetime pipe. Its
fixture tests verify EOF cleanup, wrong-path refusal and invalid-PID refusal.
`resources` reads `proc_pid_rusage(RUSAGE_INFO_V4)`: physical footprint and resident
bytes separately, Mach CPU ticks converted with `mach_timebase_info` to ns, and
cumulative interrupt/package-idle wakeups. The conversion is checked against an
independent `getrusage` fixture. Historical samples without `timebase_numer` have
misnamed `user_ns`/`system_ns` containing raw ticks: multiply by 125/3 on this Mac.
Preserve these raw samples; do not treat their original fields as nanoseconds.
`monitor.py` samples them once per second and records `pgrep -x Spotify` absence.
These are native process counters, not an audio-output instrument. Test-host
measurements include XCTest and are not Release Kinrox app measurements.

For the actual GUI app, `monitor_app.py <run> <pid> <resources>` verifies the
exact executable and process start identity against `<run>/app-process.json`
(`pid` and `binary` fields). It samples that app and its direct Soloist/reaper
children, never argv or the environment. Optional `phase.json` supplies a phase
label. `monitor-stopped.json`, process exit or the bounded interval ends sampling;
the output is created exclusively so an earlier run is never overwritten.

`count_frames.swift` is a separate 15-second read-only WebSocket observer. Compile
with `xcrun swiftc -parse-as-library -O -swift-version 6`, then pass the port and
exact owned Soloist PID. It confirms loopback listener ownership with `lsof`,
sends no control commands and records only counts of whitelisted event types.
It retains no payloads or track/account identifiers. This can distinguish native
event traffic from excessive GUI clock/render activity; it is not audio evidence.

`audio_status.c` uses the SDK's public Core Audio PID-to-process lookup and
`kAudioProcessPropertyIsRunningOutput`, without a tap, recording, device changes
or gain changes. Compile with the same flags plus `-framework CoreAudio` and
invoke with the owned Soloist PID. It also reports whether the process uses the
current default output, without recording device identifiers or audio samples.
Registration/active output IO is supporting
evidence only: neither proves decoded Spotify frames reached the output. Keep
G4 open unless stronger zero-gain evidence or an owner-approved alternative exists.

Run only `PlayerMacTests/SoloistLiveProbeTests` with these non-secret variables
prefixed `TEST_RUNNER_` when invoking xcodebuild:

- `KINROX_SOLOIST_LIVE=1`
- `KINROX_SOLOIST_ROOT`: fresh private artifact/control directory
- `KINROX_SOLOIST_BINARY`: previously verified Soloist executable
- `KINROX_SOLOIST_REAPER`: compiled task-owned reaper
- optional `KINROX_SOLOIST_PROFILE_ROOT`: prior profile from this task, for an
  explicitly intended stored-session restart; never point at another app's profile

The live harness refuses startup if Spotify.app is running and checks throughout
its control loop. Initial gain is zero; nonzero volume commands are rejected.
`ready.json` gives the precise device name. Select it in Spotify on the iPhone
on the same LAN. Keep the Mac Spotify app terminated throughout. If discovery
fails, examine Bonjour and the owned Connect endpoint before changing anything.

Submit one sequential `command-NNNN.json` at a time, starting at 0001, then read
its `reply-NNNN.json`. Examples (never include keys):

Prefer `python3 Tools/SoloistProbe/control.py <root> <operation>`: it locks out
concurrent writers, refuses unsettled commands, and publishes complete JSON
without overwriting history. `capture_track` / `play_captured` accept `--slot 0`
or `--slot 1` for duplicate/interleaved track experiments, retaining URIs in memory.

```json
{"operation":"snapshot"}
{"operation":"set_volume","fields":{"volume":0}}
{"operation":"capture_track"}
{"operation":"pause"}
{"operation":"restart"}
{"operation":"play_captured"}
{"operation":"seek","fields":{"position_ms":10000}}
{"operation":"bind_account"}
{"operation":"shutdown"}
```

`capture_track` retains the URI only in memory. `bind_account` reads the existing
Kinrox Web API refresh token, refreshes it through the existing client, and checks
the unique Soloist device name in the account's devices list; only booleans/counts
are recorded. It never changes the library or starts the Connect desktop engine.
Command acceptance and observed predicates are recorded separately. A predicate
that was already true cannot establish a same-URI reload; inspect the trace before
claiming occurrence attribution. No `playing` state proves decoded audio output.

Do not reuse a control/artifact directory across harness executions: commands
would replay and old traces must be preserved. The optional profile root permits
session restoration while each new run has independent commands and artifacts.
The `started.json` exclusive marker also prevents automatic test-runner retries
from replaying a control directory or overwriting its traces.

The separately gated `audition` operation is **not authorized or enabled by
default**. It requires an explicit owner exception to AGENTS.md's zero-gain test
rule and `KINROX_SOLOIST_AUDITION=1` in a subsequent test run. The prepared method
resumes the loaded track, confirms 5% gain, waits five seconds, restores confirmed
zero gain and pauses. A failure terminates the exact owned audio process. No Mac
system-volume setting changes; the owner must independently confirm hearing audio.

## Observations on 2026-11-03

These results use the verified `1.3.10.33` Spotify distribution on this Mac.
They do not complete the production integration or release gates.

| Check | Result |
|---|---|
| Fresh phone pairing | Passed after moving iPhone to the Mac's Wi-Fi; Spotify.app absent throughout. |
| Stored session / inactive activation | Passed with the phone app closed: owned restart restored login in one observed 1,022 ms attempt; WebSocket `play(uri)` activated the inactive session without a Web API transfer. A fresh test-host launch also restored the key/session. |
| Account binding | Existing Kinrox Web API account sees exactly one device with the probe's unique name. No playlist or library writes were made. |
| Commands / repeated URI | Confirmed play, pause/resume, seek to 10 seconds, zero gain, same-URI reset, and A/A/B/A loading. This is native protocol evidence, not a production occurrence reducer. |
| End of selection | A full 323-second URI load advanced to a foreign item with queue `source: autoplay`, even after the owner confirmed Autoplay off on iPhone and after native restart. Shuffle/repeat were off. Persistent mode does not satisfy strict local queue ownership in this setup. |
| Output | Owner authorized one 5%/five-second test and confirmed hearing music. The Release test host observed gain returning to zero and pause; Spotify.app remained absent. Core Audio IO status alone remains insufficient zero-gain evidence. |
| Forced parent death | After SIGKILL of the exact owned Release test host, its Soloist child disappeared in an observed 140 ms and runtime endpoint files were removed. The corresponding Xcode test intentionally fails because its host was killed. |
| Exploratory resources | Corrected counters over 143 playing samples / 152 seconds: 23.67–23.86 MiB footprint, 1.43% of one core, 135.5 interrupt wakeups/s. After commands, 117 paused samples / 124 seconds: 26.78–27.39 MiB, 0.63%, 120.6 interrupt wakeups/s. |

Resource windows use trace/monitor file birth times plus monotonic offsets with
five-second guards. They are short exploratory windows under a Debug XCTest host
and concurrent Release compilation. They exclude the host/reaper from the Soloist
figures and do not establish a 30-minute trend or Release Kinrox incremental cost.
Paused interrupt wakeups exceed the plan's proposed 5/s target; do not silently
relax it or substitute package-idle wakeups (a different counter). The owner later
accepted 2–3 seconds for long-pause recovery, 120 MiB/3% CPU for Soloist, bounded
short-pause wakeups, and cold/warm/Next p95 limits of 4/3/3 seconds. Current
native-runtime results and remaining app-level acceptance are tracked in the
[verification runbook](../../docs/runbooks/SOLOIST-VERIFICATION.md).

Artifacts: `build/soloist-probe/20261103T005237Z/` and
`build/soloist-probe/20261103T013421Z/`. Preserve `resources-red.log` (unit mismatch)
and `resources-green.log`; the original mislabeled CPU samples remain available.
The original probe and the subsequent Debug run shut down normally with exit 0.
Additional artifacts: `20261103T035759Z/` (Release audition, Autoplay-off and forced
parent death), `20261103T040923Z/` and `20261103T041528Z/` (single-track experiments),
under `build/soloist-probe/`.

After these failures were reported, the owner instructed execution of the revised
per-occurrence `--single-track` design. Production cutover remains gated by live
validation and the account/setup lifecycle. `control.py <root> single_track` restarts with the captured
URI held in memory and initial gain zero. Its first attempt accepted a very early
pause before buffering completed, then exited with code 1 at 60.6 seconds. That
result is retained; it is not evidence of usable long pauses or normal EOF.
The corrected readiness check waits for a full matching `playback_state` with
advancing speed. A synthetic regression reproduces the misleading initial
`playing` flag followed by `track_changed` before real readiness. Process exits
are recorded separately; nonzero single-track exits fail the harness test.

The second attempt (`20261103T041528Z/`) still exited with code 1 at 61.75 seconds
while paused at 104 ms, despite confirmed readiness. This rules out treating the
first failure as merely premature readiness. In the third attempt
(`20261103T042009Z/`), short pause/resume, 10-second seek and a zero-volume command
passed. After a near-end seek, the process exited with code 0 while the next
recommendation was still buffering; no subsequent `playing` event was observed.
That is protocol/process evidence, not an audible test of single-track mode or
a full uninterrupted single-track EOF run. Observed restart-to-ready times in
the latter two attempts were 1.83 and 1.60 seconds (Debug host, small sample).

The owner-authorized design uses one Soloist process per queue occurrence. Short
pauses keep the process; long pauses retain the confirmed position and terminate
it before the native 60-second pause failure. Resume starts a new process at gain
zero, seeks, then restores confirmed gain. Intentional termination cannot emit EOF.
`control.py` supports `suspend` and `resume_captured`; `bench_recovery.py` and
`soak.py` drive the zero-gain experiments without storing any track identifier.

Additional Release evidence (`20261103T044219Z/`, `20261103T045157Z/`): a full
309.953-second natural single-track run exited 0 without a foreign `playing`
event. Its terminal buffering snapshot froze about 942 ms early; a recorded-trace
regression now verifies the native reducer's boundary handling. After 70 seconds
with the process stopped, warm saved-position recovery passed 30 cycles; one
additional recovery started the command benchmark. All 800 control commands passed.

| Operation | Samples | Median / p95 / maximum |
|---|---:|---|
| Saved-position recovery | 31 | 1596.61 / 2135.00 / 2407.80 ms |
| Suspend | 31 | 175.73 / 275.14 / 279.35 ms |
| Pause | 200 | 22.21 / 43.95 / 65.72 ms |
| Short resume | 200 | 42.55 / 44.03 / 51.18 ms |
| Seek | 200 | 43.16 / 44.97 / 65.02 ms |
| Zero-volume confirmation | 200 | 22.07 / 24.34 / 40.59 ms |

These are warm stored-session/cached-track Release harness results, not cold
startup, LAN latency or production-app acceptance. Zero-volume requests were
idempotent confirmations, not gain-change measurements. The owner accepted 2–3 s
long-pause recovery for v1 on 2026-11-03. The 30-minute soak uses ten occurrences of
one captured track, not ten distinct tracks. `summarize_soak.py` separates physical
footprint, RSS, CPU and both wakeup counters for Soloist, test host and reaper.
Two monitors and development builds were concurrent; report that limitation.

Prepared production code now includes the bounded installer/archive parser,
supervisor, separately signed C reaper, state reducer, serialized runtime and
MusicEngine adapter. `SoloistNativeDriverTests` is a separately opt-in real-driver
check (`KINROX_SOLOIST_DRIVER_LIVE=1` plus the same paths above); never run it against
a profile concurrently used by another probe. `SoloistDownloadTests` uses only
`KINROX_SOLOIST_DOWNLOAD_LIVE=1` and a fresh `KINROX_SOLOIST_ROOT`, without credentials.
The native download test passed in 4.33 s, downloading rolling build 1.3.10.36; playback measurements still refer to 1.3.10.33. A delayed-teardown regression exposed
process overlap/stale paused state during Play; the corrected command-chain test
passes. Keep failed logs and all artifacts. No production cutover, commit or
release has been performed.


### Actual-app and physical-phone acceptance

`app_audition.swift` is a separate, explicitly authorized, one-shot diagnostic.
It operates only on an already playing child with verified loopback listener,
PID/start-time/parent identity and observed zero gain. It uses a seven-second
owned-child shutdown watchdog and restores zero gain plus pause after the
five-second 5% interval. `KINROX_SOLOIST_APP_AUDITION=1` is required; that switch
is not permission to repeat an already consumed owner approval. It reads no key.

`SoloistLANAcceptanceTests` in RemoteiOSTests is disabled unless
`KINROX_SOLOIST_LAN_LIVE=1` and refuses simulator acceptance. It uses the existing
physical iPhone pairing, requires a playing zero-gain queue with at least twelve
items, and sends ten pause/resume/seek/idempotent-zero-volume/Next sequences by
default. `KINROX_SOLOIST_LAN_COUNT=200` runs the full command sample, temporarily
enables Repeat All and restores the previous repeat setting after the final pause.
Monotonic timestamps distinguish command acceptance from received confirmed
state. JSON test attachments contain only operation names, durations and failure
classes; no tokens, device IDs or music metadata. Zero-volume timing is explicitly
not a gain-change measurement. The normal RootView does not connect in XCTest.

`KINROX_SOLOIST_TIMING=1` enables fixed-stage OSLog durations in the native Mac
app (`app.kinrox.player`, category `SoloistTiming`). It records no credentials,
identifiers, URIs or protocol payloads. Leave it unset for normal use.

`fault_reaper.py` reproduces helper-death containment against an exact recorded
app and its owned children. It requires `KINROX_SOLOIST_REAPER_FAULT=1` plus
`--confirmed-zero-gain` after observing the current app gain. It checks parent,
executable and start identity, kills only that reaper, measures child exit and
stops the verified child itself if the regression fails. See `--help` for paths.
