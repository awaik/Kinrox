# Task: root-cause investigation — <short bug name>

Role: `investigate` (owner decision 2026-11-11). Do not repeat the model here.
The orchestrator copies this template to `.tmp/scratch/<task>/investigate.md`,
fills it in, and launches it in the background in parallel with the Codex fix:

```sh
# Portable process-group timeout; macOS includes Perl.
with_timeout() {
  perl -e '
    my $secs = shift;
    my $pid = fork() // die "fork: $!\n";
    if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n"; }
    sub stop { kill "TERM", -$pid; for (1 .. 10) { last if waitpid($pid, 1) > 0; select undef, undef, undef, 0.5 } kill "KILL", -$pid; }
    $SIG{ALRM} = sub { stop(); print STDERR "Timed out after ${secs}s; agent stopped.\n"; exit 124 };
    $SIG{$_} = sub { stop(); exit 130 } for qw(INT TERM HUP);
    alarm $secs; waitpid $pid, 0; my $st = $?; alarm 0;
    exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
  ' "$@"
}
with_timeout 5400 agy --dangerously-skip-permissions --model "Gemini 4 Carbon (High)" \
  -p "$(cat .tmp/scratch/<task>/investigate.md)" </dev/null \
  >.tmp/scratch/<task>/investigate.log 2>&1
```

## Symptom

<What the user or system observes, verbatim: error text, report, steps, time,
macOS/app version, Mac or iPhone, video or Spotify mode. Links to logs, crash
reports, or verification runbooks. No hypothesis about the cause and no fix
plan: the investigation must stay independent of Codex.>

Repository: Kinrox, main checkout, local `main`. Read `AGENTS.md` completely,
`docs/runbooks/RUNBOOK-TASK-TESTS.md`, and the verification runbook in
`docs/runbooks/` for the affected area.

## Required

1. Find the root cause: the violated rule or invariant, the location in code
   (`path:line`), and the chain from input to symptom.
2. Prove it: reproduce with an existing test or a temporary script under
   `.tmp/scratch/<task>/`, or cite log lines. Use builds or tests only as allowed below.
3. List other places with the same defect and what else may break.
4. Propose the fix in words and the regression test that would pin it.

## Hard rules

- Read only. Do not change code, tests, documents, `project.yml`, configs,
  localization, generated projects, or `Kinrox.xcworkspace`. Write only under
  `.tmp/scratch/<task>/` and to the report file.
- Codex may be editing files for this bug at the same time. If a file changes
  under you, rely on `git show HEAD:<path>` and note it in the report.
- No commits, push, PR, release, signing, notarization, installing over the
  user's app, `git checkout/reset/stash/restore/clean`, branches, or worktrees.
  Do not launch agents or `research-execute`.
- Do not read or print secrets: `Config/Signing.local.xcconfig`, Keychain items,
  Spotify or remote pairing tokens, Sparkle signing keys, `.env*`, `*.pem`, `*.key`.
- Builds and tests follow `RUNBOOK-TASK-TESTS.md` for the touched subsystem, with
  outputs under `.tmp/scratch/<task>/`: `-derivedDataPath .tmp/scratch/<task>/DerivedData`
  for `xcodebuild`, `--scratch-path .tmp/scratch/<task>/build` for `swift test`.
  Do not run `Scripts/generate.sh` or release scripts.
- Playback checks keep Kinrox volume at 0; never change Mac system volume. Do not
  launch Spotify.app. No WebView, network requests, or account actions beyond
  what this task explicitly allows.

## Report

Write `.tmp/scratch/<task>/investigate-report.md` in English: the cause in one
sentence; evidence with `path:line` and commands; confidence and what was not
checked; other places with the same defect; the proposed fix and regression test.
The last non-empty line:

`RESULT: cause found | hypothesis without proof | not found - <one sentence>`
