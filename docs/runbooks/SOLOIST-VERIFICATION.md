# Standalone Spotify verification

Status: native playback is the default production path, 2026-11-03. The owner
accepted Next p95 ≤3.2 seconds, waived the remaining physical sleep/reboot checks
and authorized release. Those scenarios remain untested on the real Mac; the
waiver is not a passing result. Mac 0.5.0 build 9 is signed and notarized locally.
The owner initially deferred publication for review, then explicitly requested
commit and release on 2026-11-04. The publication candidate is build 10, rebuilt
to include the subsequent review fixes; build 9 is retained as historical evidence.

The [research and implementation plan](../RESEARCHES/2026-11-02_10-34_Standalone-Spotify-research-brief.md)
defines gates G0–G5. Historical Connect-only release checks do not establish
standalone playback. No WebView or Spotify.app fallback is used by the native path.

## Owner decisions

- Personal Soloist keys may be passed directly to the verified signed Soloist
  child in argv. Other same-user processes can read argv. The local Soloist
  socket has no authentication or Origin validation; this is disclosed.
- Each user supplies their own key; the setup includes the official key link and
  Spotify Premium requirement. Phone pairing has been completed and the owner
  subsequently closed Spotify on iPhone.
- One process per queue occurrence replaces persistent mode. Persistent mode
  produced recommendations even with phone Autoplay disabled and is rejected.
- Long-pause recovery of 2–3 seconds is accepted for the first version.
- Cold startup p95 ≤4 seconds, warm startup and Next p95 ≤3 seconds were
  accepted after the first 30 cold/30 warm and 68 successful Next samples.
- After the 200-command physical-iPhone run, the owner explicitly accepted
  Next p95 ≤3.2 seconds for v1 on 2026-11-03. Startup limits remain 4/3 seconds.
- Soloist physical footprint up to 120 MiB and CPU up to 3% of one core are
  accepted. Approximately 21 interrupt wakeups/s during a short pause is accepted;
  the process is stopped after 20 seconds of inactivity.
- The remaining physical sleep/reboot acceptance checks were explicitly waived
  on 2026-11-03 with release authorization; do not reopen them for this release.
- A separate macOS 14 execution test is permanently excluded. The deployment
  target and Mach-O minimum OS are still checked; runtime evidence is for
  macOS 26.5.2 only.
- Setup, pairing, unknown-volume and recovery designs in the existing Figma file
  were approved on 2026-11-03.

## Environment and artifacts

MacBookPro18,2, Apple Silicon, 32 GiB RAM; macOS 26.5.2 (25F84), Xcode 26.5.
Live tests use the owner's network and Spotify account. No track names, URIs,
account IDs, audio samples or credentials are retained in measurement logs.
All playback after the separately authorized audition uses native gain zero.
Mac system volume is never changed.

The rolling official CDN returned two versions during execution. Exact hashes,
signer, download host and lifetime are recorded in
[`Scripts/soloist-policy.json`](../../Scripts/soloist-policy.json). This external
runtime policy is separate from GPL dependency source archives.

| Artifact | Verified evidence |
|---|---|
| Soloist 1.3.10.33 | Spotify Team `2FNC3A47ZF`, identifier `com.spotify.soloist`, arm64, minimum OS 13.0; strict signature and notarization check; quarantined copy executes without removing quarantine. |
| Soloist 1.3.10.36 | Fresh native installer download and verification completed in 4.33 s; same publisher/architecture/minimum OS; native-driver restore/commands/duplicate/EOF and ten-distinct-track soak passed. |
| KinroxSoloistHost | Own C executable, signed as `app.kinrox.soloist-host` with the app's team and Hardened Runtime; no credential in its arguments. |
| App bundle boundary | Own helper present and signing identity verified; known or renamed Spotify binaries and rolling-layout archives rejected. Spotify is not embedded in the app. |

`spctl` returns “valid but does not seem to be an app” for this command-line
binary. This is recorded separately from successful strict
`codesign --check-notarization` and quarantined execution. No OS security setting
was changed and Spotify's executable was not re-signed.

Private raw artifacts are retained under `build/soloist-probe/`; they are ignored
by Git. Profiles contain session credentials and must not be published. Probe
sources are in [Tools/SoloistProbe](../../Tools/SoloistProbe/) and the opt-in
`PlayerMacTests/SoloistProbe` test directory. Keys are read by native signed code
from Data Protection Keychain; shell commands and test environment variables
carry only paths and opt-in switches.

## Standalone and queue evidence

Phone pairing succeeded after iPhone joined the Mac's Wi-Fi network. Read-only
account-scoped device discovery confirmed the unique Soloist device belonged to
the Web API account. A fresh native restart restored the stored session with
Spotify on Mac and iPhone closed. WebSocket playback activated the inactive
session without Web API playback transfer.

The production runtime gives each load a new process epoch and queue occurrence
ID. It waits for observed playing state, seeks before restoring gain, and retains
one local queue. Upcoming edits do not write a Spotify playlist. Legacy Kinrox
Queue playlists remain untouched; non-secret exclusion identifiers survive
Disconnect.

The native driver passed stored-session load at a nonzero position, short pause,
parked resume, adjacent duplicate URI as a new occurrence, zero-volume command,
near-end seek and occurrence-qualified natural exit on both tested versions.
An independent full natural single-track run lasted 309.953 s, exited 0 and
observed no foreign playing item. EOF is qualified by occurrence and natural
boundary, not merely by exit code. Nonzero exit, takeover and intentional stop
are separate outcomes.

An idle-teardown/Play race was reproduced before its fix: the old process could
overlap a replacement and publish stale paused state. Timed parking now joins
the command chain and checks the retired epoch after teardown. Regression tests
verify saved position, gain restoration and no overlap.

## Release ten-track sustained run

`20261103T054722Z-native-soak/`: native production supervisor and runtime, Soloist
1.3.10.36, Release XCTest host (`ENABLE_TESTABILITY=YES`). Ten distinct playable
tracks were selected in memory from one bounded read-only library page. Each
occurrence played for 150 seconds, paused for 22 seconds, then remained parked
for 8 seconds. Intentional per-occurrence restarts are part of this architecture.

The run completed in **1853.62 seconds**, with **1685 Spotify-absence samples**
and **zero samples containing Spotify.app**. No missing load, pause or parked
transition was detected. The test checked confirmed zero volume throughout.

| Process/state | Physical footprint | CPU, one core | Interrupt wakeups/s |
|---|---:|---:|---:|
| Soloist, playing | 24.73–27.30 MiB | 0.95–1.06% | 35.13–38.18 |
| Soloist, short pause | 25.52–26.91 MiB | 0.07–0.13% | 20.24–23.16 |
| Own reaper, playing | 0.92–0.95 MiB | 0% | 0 |
| XCTest host, playing | 45.45–47.30 MiB | 0.23–0.26% | 9.90–10.13 |

Post-warmup playing footprint median changed **+1.80%** from occurrence 3 to 10.
Ten load-to-confirmed-playing samples had median **3373.67 ms**, maximum
**4793.30 ms**. These include process replacement and differ from resuming an
already running process. They do not meet the proposed 1.5-second Next target.
The owner subsequently accepted Next p95 ≤3 s based on the expanded Release
series. The ten-track maximum is retained as an observed result, not discarded.

Counters are obtained with `proc_pid_rusage`, using the Mach timebase conversion
validated independently against `getrusage`. RSS is retained separately in raw
and summary data; shared mappings are not summed. Phase guards exclude five
seconds at playing boundaries and two seconds at other boundaries. The end of a
parked window can include the following startup, so parked-window totals must
not be used to claim a steady-state cost. Development builds and one resource
monitor ran concurrently. XCTest-host footprint is not a measurement of the
production app's incremental memory.

Earlier `20261103T045157Z/` completed 1825.44 seconds with ten occurrences of
**one** distinct track using the earlier harness. It is preserved as separate
evidence, not substituted for the ten-distinct-track native run.

## Earlier control measurements

The earlier Release harness measured 31 warm stored-session recoveries after a
70-second stopped interval: p50 **1596.61 ms**, p95 **2135.00 ms**, maximum
**2407.80 ms**. These are cached-track recovery samples, not 30 cold starts.
For 200 samples each: pause p50/p95 22.21/43.95 ms, short resume 42.55/44.03 ms,
seek 43.16/44.97 ms, idempotent zero-volume 22.07/24.34 ms. The old seek predicate
observed position; the production runtime now also waits for playing readiness
when seeking during playback. Results must not be conflated.

The stricter native-driver test on 1.3.10.36 measured nonzero-position load
2989.18 ms, pause 32.25 ms, parked resume 1458.05 ms, adjacent duplicate load
1780.71 ms, idempotent zero-volume 21.75 ms and near-end seek 834.51 ms.
This was a Debug functional run with one sample per operation.

Expanded Release startup measurements in `20261103T061835Z-native-benchmark/`
completed 30 cold and 30 warm loads. Cold p50/p95/max was
2206.59/2926.35/2933.58 ms; warm was 1822.51/2225.35/2471.22 ms. “Cold” means a
new empty audio cache with a stored authenticated session; OS caches were
uncontrolled. The following command series failed after 68 successful sets and
is retained as a failed run, not a complete acceptance series.

A second run, `20261103T063130Z-native-trace/`, identified the cause after 19
sets: Soloist occasionally relinquishes its active-device state immediately
after confirming pause. Treating that event as takeover retired an in-flight
command. The reducer now preserves the paused occurrence and allows only an
explicit Play to reload its saved position. Inactivity while playing remains a
takeover. A deterministic regression failed before the fix and passed afterward.

The corrected Release series in `20261103T064000Z-recovery-benchmark/`
completed **200 samples of every command with zero failures**, in 418.27 s.
All 390 process-presence samples confirmed Spotify.app absent:

| Confirmed operation | p50 | p95 | Maximum |
|---|---:|---:|---:|
| Pause | 22.13 ms | 32.75 ms | 63.91 ms |
| Resume | 11.13 ms | 22.23 ms | 1957.35 ms |
| Seek | 11.12 ms | 87.83 ms | 657.48 ms |
| Idempotent volume zero | 21.98 ms | 22.62 ms | 55.23 ms |
| Next | 1760.17 ms | 2284.44 ms | 2764.47 ms |

There were four inactive-device notifications and four additional native starts
besides 210 explicit loads (ten cache-prime loads plus 200 Next commands).
Consequently, even a short pause can occasionally need a full recovery; the
1.96-second resume maximum is retained. These timings end at confirmed native
state, not decoded audio. Volume-zero measurements do not establish a gain
change. p95 uses nearest rank; raw failures and successful samples are separate.

## Output evidence and remaining acceptance

The owner accepted the updated connection terms in the actual app. Release GUI
run `20261103T083954Z-release-app/` then restored the account, key and paired
session after Spotify.app was fully quit. At confirmed gain zero, album playback,
button pause/resume, Shift-Right seek, manual Next, natural Next and saved-position
resume after process parking worked. Switching the visible mode preserved audio.
All 437 presence samples found no Spotify.app. One unintended favorite addition
during coordinate navigation was immediately undone using Command-Z; the UI and
library count returned to their prior state. No playlists were changed.

Actual UI verification exposed a Space-key routing defect: a focused mode button
could receive Space before the Playback menu. A regression reproduced the missing
pause; the music keyboard monitor now consumes unmodified Space outside text
editing and popovers. Held-key repeats do not toggle playback repeatedly. Eight
keyboard/coordination tests passed after the fix.

The same GUI run exposed excessive main-process CPU, despite the low Soloist
cost: a stationary playing window used 93.96% of one core over 43.04 s, with
365.56 MiB median footprint. A native stack sample showed continuous SwiftUI
layout/render work. Changing the animation timeline to a periodic timeline did
not help (93.17% in `20261103T084952Z-release-ui/`). A passive socket observer
received only two state/auth frames in 15 seconds, ruling out a native push flood.
A cancellable 250 ms task clock reduced CPU to 9.96% over 127.09 seconds in
`20261103T085759Z-release-clock/`. Median app footprint was 331.10 MiB versus a
short warmed-library baseline of 326.19 MiB. That run overlapped automated tests.
The final clock isolates observation to time labels and the scrubber; its matched
baseline and playback measurements are in `20261103T091534Z-release-pause-fixed/`:
77.10 s idle at 324.27 MiB median and 0.02% CPU; 126.90 s playing at 329.41 MiB
median and 7.92% CPU, an app increment of 5.14 MiB. Playing peak was 334.20 MiB.
The own reaper adds about 0.94 MiB; Soloist is measured separately. A five-second
sample found the main thread waiting in 3,879 of 4,198 samples, unlike the previous
continuous layout loop. This is not a frame-time/stall percentile measurement.
The iOS build overlapped the beginning; playback included one natural transition.
Short-pause/parked samples include accessibility inspection and are reported
separately in `resource-summary.json`. Keep every failed/intermediate result.

The owner authorized an earlier five-second audition at 5% and confirmed hearing
music. That audition used persistent mode. A separate authorization was consumed
for the actual Release app using Soloist 1.3.10.36 in single-track mode, recorded
in `20261103T090611Z-release-final-ui/audition-result.json`: observed gain
0 → 5 → 0, then confirmed pause; five seconds were waited at 5%, with zero gain
confirmed after 5.25 seconds including observation delay. The diagnostic tool
verifies listener/PID/start-time/parent ownership and has a seven-second shutdown
watchdog. It reads no key and captures no audio. The owner subsequently confirmed
hearing native audio during manual testing of the latest build with Spotify.app
fully closed. Do not repeat an audition under the consumed approval.

The external audition pause exposed a runtime defect: only Kinrox-issued pause
commands started the 20-second parking timer. Soloist therefore exited with code
1 after about 60 seconds, disabling controls. A regression first failed both
expected teardown and explicit-resume restart assertions. Observed transitions
to paused now schedule the same serialized idle teardown; scheduling replaces
the previous timer. Nineteen runtime/reducer/keyboard tests passed afterward.
Release rebuilt successfully. The zero-gain live regression confirmed external
pause, observed child teardown between samples 20.12 and 21.18 seconds, and kept
the UI usable through 82.47 seconds paused. Space resumed the same track from its
saved position with a new child, still at zero gain. All 453 presence samples
through the recorded summary found Spotify.app absent. The owner reported seeing
the remote on iPhone;
separately instrumented physical LAN commands have now passed, as detailed below.

The actual Release GUI app was then terminated with SIGKILL while playing at
zero gain. Its verified direct Soloist child exited in an observed 139.71 ms;
the own reaper exited in 146.34 ms. Evidence is
`20261103T091534Z-release-pause-fixed/forced-app-quit.json`. A fresh GUI launch in
`20261103T092510Z-release-crash-reopen/` retained account consent, key and session,
restored the library, and started the album without Spotify.app or another key
prompt. No media resumed automatically before the explicit Play action.

### Physical iPhone commands — 2026-11-03

The owner's physical iPhone was attached by USB for XCTest. Both applications
used Release builds; the phone test host enabled testability and used its existing
pairing through the normal Bonjour-discovered encrypted transport. The first
attempt (`20261103T093102Z-physical-lan/`) completed one five-command sequence,
then immediately attempted Pause while the remote still advertised it disabled
after Next. That local rejection and XCTest's reported CancellationError are
retained. The test now waits for advertised command availability before dispatch
and requires Next to restore the Pause capability before completing its sample.
This changes the harness; no production guard was weakened.

The corrected run and a repeat over the same tracks both passed: 51 commands
per run, including ten each of pause, resume, seek, idempotent zero volume and
Next, plus a final pause. Test durations were 38.02 and 29.20 seconds. Artifacts
and numeric attachments: `20261103T093758Z-physical-lan-ready/`.

| Command | First pass p50 / maximum | Same-track repeat p50 / maximum |
|---|---:|---:|
| Pause | 70.72 / 111.45 ms | 60.01 / 91.49 ms |
| Resume | 78.17 / 89.46 ms | 71.83 / 204.70 ms |
| Seek | 94.49 / 197.57 ms | 76.11 / 198.78 ms |
| Idempotent zero volume | 40.39 / 108.84 ms | 41.69 / 62.61 ms |
| Next | 3688.86 / 4510.73 ms | 2359.57 / 4319.39 ms |

These durations end at confirmed state received on the phone, not acceptance.
Acceptance medians were 2.70–6.50 ms. Ten samples per operation make nearest-rank
p95 equal the maximum, so this is a small-sample result. The original 3-second
Next target was **not established** by these physical-phone runs. The later
200-cycle result and explicit owner decision are recorded below. Cache was not cleared before the first pass;
the repeat used the same eleven queue tracks. It is not a controlled cold-cache
comparison. No volume above zero was requested. The lsof route observer exposed
no established app sockets, so it did not independently identify the physical
network interface; USB attachment is recorded rather than claiming Wi-Fi-only
timing. The normal Remote app was relaunched after testing, and the Mac remained
paused at zero gain. Spotify.app was absent in all 784 monitor samples through
the first completed phone-run summary; the continuous trace is retained.

The owner subsequently confirmed hearing music in the latest app with Spotify.app
fully closed. This closes the separately authorized audible-output check; no
additional audible audition was performed. Sleep/wake is deferred at the owner's
request ("not convenient now"); an actual sleep or system reboot has not been
performed. A fresh app launch does not substitute for a system reboot.

### Video regression and power handling — 2026-11-03

The owner's screenshot reported "Failed to open video / Soloist could not confirm
the playback command." The coordinator correctly pauses music before opening
video, but the native runtime incorrectly required a queue occurrence when no
music process had ever started. A real coordinator/native-adapter regression
reproduced the error and the missing video open. An idle pause now joins teardown
and succeeds without creating an occurrence or launching Soloist.

Artifacts: `20261103T132526Z-video-and-final-acceptance/`. The red regression is
retained in `video-red.log`; 22 focused tests passed afterward. The real mpv suite
passed eight tests, including new MP4/MKV checks with the native adapter connected,
time advancement, rendered frames and gain zero. The method-only attempt selected
zero tests and is retained separately, not counted as verification.

The native engine now observes system sleep/wake. Sleep cancels pending work,
joins the command chain, stops the owned process and preserves the pre-sleep
position. Wake leaves the track paused until explicit Play. Eighteen focused
tests passed, including position restoration and no process overlap. These are
deterministic lifecycle tests; physical sleep/reboot acceptance was subsequently waived by the owner.

### Output and network recovery — 2026-11-03

After an interrupted session, a new clean observation is retained in
`20261103T143400Z-lifecycle/`. Spotify.app was fully closed before this observation.
At Kinrox gain zero, the default output changed from ULT FIELD 1 (Bluetooth) to
MacBook Pro Speakers and back. Core Audio reported active output IO and use of
the current default output on both devices, with the same Soloist PID. Position
advanced, pause/resume worked, and the original Bluetooth output was restored.
The system volume controls were not adjusted; each device retained its own level.
Core Audio IO registration is supporting evidence, not a decoded-frame claim.

Wi-Fi was powered off for 25.67 seconds and restored by an independent local
controller with unconditional restoration. Kinrox retained the buffered playback
session. A Next command after reconnection completed in 2055 ms; the subsequent
51-command physical-iPhone series passed with no failures. The UI command issued
while connectivity was unavailable reached the app only after restoration, so it
does not prove offline-command behavior or prolonged-outage timeout handling.
No phone-route claim is made from the USB-connected test.

Earlier exploratory samples in `20261103T132526Z-video-and-final-acceptance/`
included a running Spotify.app and are excluded from standalone acceptance.
When external Spotify playback took over, Kinrox stopped its child, preserved the
queue/position and displayed "Play on this Mac". It did not reclaim playback
until that explicit action. The earlier `output-built-in.json` phase label was
not verified after the interruption; use the two new output records instead.

### Next preparation diagnostics — 2026-11-03

The pre-optimization phone repeat passed 51 commands in 28.19 seconds, but Next
still had p50 2254.37 ms / p95 3245.93 ms (ten samples). Fixed-stage opt-in OSLog
diagnostics separated teardown, signature verification, Keychain, socket startup
and observed playback. No identifiers, credentials or protocol payloads are logged.
The longest loads spent 2.3–2.45 seconds waiting for Soloist playback in addition
to sequential local preparation.

Preparation now overlaps independent signature/architecture/digest verification
and Keychain reading with teardown. New-process launch still waits for all checks
and old-process termination. Every launch retains the full signature and
notarization checks; there is no trust cache or prestarted audio process. Soloist
Keychain reads run off MainActor. Twenty-three focused tests and the full Mac
suite (276 tests / 60 suites) passed. The arm64 Release bundle check passed.
The final physical-phone measurement is in
`20261103T144400Z-next-optimized/phone-200.xcresult` and its JSON attachments. It
passed 1003 commands in 503.73 seconds: 200 each of pause, resume, seek,
idempotent zero-volume and Next, plus repeat setup/restoration and final pause.
The 19-track queue used Repeat All for the run, then restored its original Off
setting. Cache was retained, Spotify.app remained closed, and gain stayed zero.
These are full Release app-to-physical-phone results, with the phone attached by
USB and its normal encrypted Bonjour transport; the specific interface is not
independently established.

| Command | Samples | p50 | p95 | Maximum |
|---|---:|---:|---:|---:|
| Pause | 200 | 72.50 ms | 158.93 ms | 207.84 ms |
| Resume | 200 | 86.96 ms | 166.92 ms | 281.52 ms |
| Seek | 200 | 83.03 ms | 208.01 ms | 668.12 ms |
| Idempotent zero volume | 200 | 53.59 ms | 132.27 ms | 223.20 ms |
| Next | 200 | 2099.70 ms | 3095.05 ms | 4065.58 ms |

There were zero rejected or timed-out commands. Acceptance medians were
9.30–12.25 ms for these five operations. The nearest-rank Next p95 exceeded the
original 3000 ms limit by 95.05 ms. On 2026-11-03 the owner explicitly accepted
3200 ms for v1 after reviewing these measurements. The Next latency criterion
therefore passes; the measured values and slower outliers remain recorded. The first
680 process-monitor samples found no Spotify.app and at most one owned Soloist
and one owned reaper. Later fault-injection samples are separate from latency.

### Artifact size inventory

`20261103T143400Z-lifecycle/artifact-size-comparison.json` compares retained local
Release builds: the pre-standalone `SpotifyPerformance/Release` app identifies as
0.4.1 (7), and the current app as 0.4.2 (8). Main executable size changes from
9,520,992 to 10,485,952 bytes; the new signed helper adds 53,376 bytes. Combined
executable/helper growth is 1,018,336 bytes. Bundle file totals are 18,473,526 and
19,711,510 bytes. These are development bundles with external libmpv, not DMGs;
the comparison also includes intervening changes and is not an isolated
attribution of every byte to Soloist.

The read-only external storage inventory found 36,298,651 bytes under the engine
installation root (including retained download artifacts), 3,606,891 session
bytes and 55,142,766 audio-cache bytes. The runtime still uses a 200 MB cache cap.
No session/cache contents or credential values were read by that inventory.

### Abnormal helper and child exit — 2026-11-03

The planned helper-death check reproduced a failure: after the owned reaper was
killed, Soloist survived the 1.2-second observation. The zero-gain fault controller
then stopped that exact child. The supervisor now observes reaper termination,
checks both current helper identity and child object identity, and retires the
child immediately. A late exit from an older helper cannot stop a replacement.
The fixed Release check stopped Soloist in 331.26 ms, below the one-second limit.

A separate SIGKILL of Soloist reproduced stale endpoint files and failure to
restart after Retry. The supervisor now retires the dead child's helper and
archives only the endpoint values captured from that child's validated loopback
listener. Unknown values, symlinks and session files remain untouched. Two file
regressions cover preservation and refusal; the live check preserved all three
endpoint files and left no stale launch names. Its first observer printed the
correct primary result, then raced the already-exited helper during enumeration;
an independent follow-up verified the result and archived files successfully.

Artifacts: red cases in `20261103T144400Z-next-optimized/`; green cases and
`child-crash-observation-verified.json` in `20261103T150200Z-supervision/`.
Explicit Settings → Retry → Play restored the saved position, native gain zero
and subsequent Next. The app was left paused at zero. These fault-path changes
follow the 200-cycle latency run; they do not replace it with a new measurement.
At handoff the latest Release app remained open, with no owned audio/helper child
after idle parking; all 318 final presence samples found Spotify.app absent. The
normal Remote app was relaunched successfully on the physical iPhone.
Physical sleep/reboot checks were subsequently waived by the owner together with
release authorization. The owner-approved 3.2-second Next p95 criterion is closed.

## Automated and documentation checks

- Native setup construction performs no download or key read. Regression tests
  cover preserved pairing on cancellation, settling before account cleanup,
  failed Disconnect retry and preservation of the downloaded engine.
- Owned storage validates both account roots and ownership markers before
  deletion. Unknown, mismatched or symlinked data is retained.
- Installer/archive tests cover traversal, links, duplicates, architecture,
  expiry and allowed HTTPS origins. Each installation uses an immutable unique
  slot, including repeated downloads of the same build.
- Runtime tests cover serialized commands, missing ACK versus observation
  timeout, cancellation, position/gain restore and bounded event coalescing.
- Protocol v1 remains unchanged; optional `volumeKnown` preserves old-client
  compatibility and disables volume when unknown. No key/session/path is sent
  to iPhone.
- UI strings and versioned connection/privacy documents are updated in all
  30 locales. Consent version is `2026-11-03`; the public pages are regenerated
  offline. Document validation and 120-page generation checks pass.
- The embedded helper identifier bug was detected by a real native launch:
  incremental build retained a stale embedded copy. Explicit target signing
  identity and a fresh build resolved it; bundle checks now reject that case.

Current automated checks: final default-cutover verification with portable release
libraries passed 280 tests / 61 suites; Music 37 and script checks 52 also passed.
Artifacts: `20261103-release-cutover/`. The earlier full Mac suite passed 276 tests / 60 suites after
the video, power and parallel-preparation changes; 22 focused tests / three suites
passed after the helper/endpoint recovery changes, including socket loss without
process exit and rejection of delayed disconnects from a retired epoch. Music package 37
tests / seven suites, protocol 127 / 22 using a fresh scratch build, iOS 62 / 12,
and release/document/site script tests 52 passed. Failed incremental protocol
artifacts are retained separately. Strict Swift lint passes. Native setup screens
were rendered and inspected at 560 points in English, Russian and Arabic.
The current arm64 Release app builds and passes the embedded-helper/absence-of-
Spotify-artifact boundary check. This is a development build, not a notarized
distribution artifact or a measured release-size comparison.
The opt-in physical-iPhone latency test passed twice on the connected device
in Release. Default/simulator runs cannot perform this acceptance test.
Default cutover removes the production Connect factory and all playback-driven
helper-playlist writes. Legacy queue IDs remain read-only exclusion tombstones.
New OAuth requests retain device-read permission for pairing and omit playback-write
permission; retained historical adapters are unreachable from production wiring.
No user files or failed artifacts have been cleaned up.

## Prepared Mac 0.5.0 release

`dist/0.5.0-build9/` retains the signed app, DMG, corresponding dependency sources,
checksums, signed appcast and both Apple acceptance receipts. The mounted DMG
passed signature, Gatekeeper, stapling, 44-library verification, absence of a
bundled Spotify artifact and a real startup check. No new manual media, sleep or
reboot test was performed during packaging. Existing live evidence remains above.
Build 9 was prepared from baseline `0b6291e` plus the then-uncommitted working
tree. Subsequent review fixes changed production sources, so build 9 is not the
published artifact. The owner authorized committing accumulated changes and
releasing version 0.5.0 on 2026-11-04; build 10 is built from that source snapshot.


## Publication verification — 2026-11-04

The owner requested commit and release. Post-build-9 fixes required build 10;
build 9 remains preserved. The new source manifest is in `dist/0.5.0-build10/`.
Passed: 290 Mac tests / 61 suites, 37 music tests / seven suites, 127 protocol
tests / 22 suites in a fresh scratch build, 52 Python tests, strict Swift lint,
and generation checks for 120 pages / 30 languages. iOS simulator tests also
passed: 62 tests in 12 suites. The first incremental
protocol run failed six socket assertions; both logs are retained separately.
Historical live evidence and the physical sleep/reboot and macOS 14 runtime
verification boundaries above remain unchanged.
