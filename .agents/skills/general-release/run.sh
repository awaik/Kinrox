#!/usr/bin/env bash
# General Kinrox Mac release: everything on `main` above origin/main (local commits and
# uncommitted changes) ships as one signed, notarized release.
#   1) review of the whole package - agy (Gemini), report review.md;
#   2) assessment and application of justified findings - codex (high), locally; stop for
#      the orchestrator's control (exit 11);
#   3) release: version bump, release notes, full checks, build-release.sh, mounted-DMG
#      verification, source commit, tag, push, GitHub Release, website and appcast commit,
#      Pages verification. Only via --release and only with the line "VERDICT: RELEASE" in
#      control.md. By default the orchestrator performs it from release-N.prompt.md (exit 14)
#      and reports with --finish; RELEASE_AGENT=codex hands it to codex (medium) instead.
# Agent questions land in questions.md (exit 10); after answers.md run --resume.
#
# Usage:
#   run.sh --version X.Y.Z --build N [--dry-run]   stages 1-2 in a new run
#   run.sh --resume "<run>"                         continue a codex stage after answers.md
#   run.sh --release "<run>"                        stage 3 after control
#   run.sh --finish "<run>"                         record the orchestrator's release result
#
# Exit: 0 released (or nothing to release); 10 questions; 11 control needed;
#       12 release partial or blocked; 13 extra branches or worktrees;
#       14 release handed to the orchestrator; 1 error; 2 usage.
set -uo pipefail

fail() { echo "$*" >&2; exit 1; }
SKILL_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROMPTS_DIR="$SKILL_DIR/prompts"
REPO="$(git -C "$SKILL_DIR" rev-parse --show-toplevel 2>/dev/null)" || fail "The skill must be inside the Kinrox checkout."
# The working-tree fingerprint is shared with research-execute.
FINGERPRINT="$REPO/.agents/skills/research-execute/fingerprint.mjs"
STATE_ROOT="$REPO/.tmp/scratch/general-release"
# Owner decision 2026-11-11: of Google's models, agents use only Gemini 4 Carbon (High).
AGY_MODEL="${AGY_MODEL:-Gemini 4 Carbon (High)}"
AGY_TIMEOUT="${AGY_TIMEOUT:-5400}"
CODEX_MODEL="${CODEX_MODEL:-gpt-6-astra}"
# Owner decision 2026-11-12: Codex limits run out quickly. Apply defaults to high (APPLY_EFFORT=xhigh
# for a hard package), and the orchestrator performs the release unless RELEASE_AGENT=codex.
APPLY_EFFORT="${APPLY_EFFORT:-high}"
RELEASE_EFFORT="${RELEASE_EFFORT:-medium}"
RELEASE_AGENT="${RELEASE_AGENT:-orchestrator}"
# Codex auto-loads AGENTS.md but truncates it at 32 KiB by default; load it whole so agents never re-read it.
CODEX_DOC_BYTES="${CODEX_DOC_BYTES:-65536}"

MODE=new; RUN_ARG=""; DRY_RUN=0; VERSION=""; BUILD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version|--build|--resume|--release|--finish)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
      case "$1" in
        --version) VERSION="$2" ;;
        --build) BUILD="$2" ;;
        --resume) MODE=resume; RUN_ARG="$2" ;;
        --release) MODE=release; RUN_ARG="$2" ;;
        --finish) MODE=finish; RUN_ARG="$2" ;;
      esac
      shift ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
if [ "$MODE" = new ]; then
  [ -n "$VERSION" ] && [ -n "$BUILD" ] || { echo "A new run needs --version X.Y.Z and --build N" >&2; exit 2; }
else
  [ -n "$RUN_ARG" ] || { echo "--$MODE needs a run directory" >&2; exit 2; }
  [ -z "$VERSION$BUILD" ] || { echo "--version/--build belong to a new run only" >&2; exit 2; }
  [ "$DRY_RUN" = 0 ] || { echo "--dry-run works with a new run only" >&2; exit 2; }
fi
case "$(printf '%s' "$AGY_MODEL" | tr '[:upper:]' '[:lower:]')" in
  *gemini*) [ "$AGY_MODEL" = "Gemini 4 Carbon (High)" ] || \
    fail "Forbidden agy model: $AGY_MODEL. Only Gemini 4 Carbon (High) is allowed (owner decision 2026-11-11)." ;;
esac
case "$RELEASE_AGENT" in orchestrator|codex) ;; *) fail "RELEASE_AGENT must be orchestrator or codex." ;; esac
case "$AGY_TIMEOUT" in ""|*[!0-9]*|0*) fail "AGY_TIMEOUT must be a positive number of seconds." ;; esac
if [ -n "${GENERAL_RELEASE_STAGE:-}${RESEARCH_EXECUTE_STAGE:-}" ]; then
  fail "Nested pipeline execution is prohibited (stage: ${GENERAL_RELEASE_STAGE:-${RESEARCH_EXECUTE_STAGE:-}})."
fi
for cmd in git perl node python3; do command -v "$cmd" >/dev/null || fail "Missing command: $cmd"; done

log() {
  local line
  line="[$(date '+%H:%M:%S')] $*"
  printf '%s\n' "$line" >&2
  if [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ]; then printf '%s\n' "$line" >>"$RUN_DIR/run.log"; fi
  return 0
}
result_line() { grep -a -h 'RESULT:' "$@" 2>/dev/null | tail -n 1 | sed 's/.*RESULT:/RESULT:/' | tr -d '`*'; }
minutes_since() { echo $(( ($(date +%s) - $1) / 60 )); }
dirty_count() { git -C "$REPO" status --porcelain --untracked-files=all | wc -l | tr -d ' '; }
xcconfig_value() { sed -n "s/^$1 = //p" "$REPO/Config/PlayerMac.xcconfig" | head -n 1 | tr -d '[:space:]'; }

save_state() {
  {
    printf 'VERSION=%q\n' "$VERSION"
    printf 'BUILD=%q\n' "$BUILD"
    printf 'BASE_SHA=%q\n' "$BASE_SHA"
    printf 'ORIGIN_SHA=%q\n' "$ORIGIN_SHA"
    printf 'HEAD_BEFORE=%q\n' "$HEAD_BEFORE"
    printf 'UNPUSHED_COUNT=%q\n' "$UNPUSHED_COUNT"
    printf 'BEHIND_COUNT=%q\n' "$BEHIND_COUNT"
    printf 'DIRTY_COUNT=%q\n' "$DIRTY_COUNT"
    printf 'PENDING_STAGE=%q\n' "$PENDING_STAGE"
    printf 'ROUND=%q\n' "$ROUND"
    printf 'APPLY_SESSION=%q\n' "${APPLY_SESSION:-}"
    printf 'RELEASE_SESSION=%q\n' "${RELEASE_SESSION:-}"
    printf 'RELEASE_RUNNER=%q\n' "${RELEASE_RUNNER:-}"
  } >"$RUN_DIR/state.env"
}

# {{KEY}} -> value of P_KEY from the environment, so paths and answers substitute safely.
render() {
  P_REPO="$REPO" P_RUN_DIR="$RUN_DIR" P_VERSION="$VERSION" P_BUILD="$BUILD" P_TAG="v$VERSION" \
  P_DIST_DIR="$REPO/dist/$VERSION-build$BUILD" P_BASE_SHA="$BASE_SHA" P_ORIGIN_SHA="$ORIGIN_SHA" \
  P_HEAD_SHA="$HEAD_BEFORE" P_UNPUSHED_COUNT="$UNPUSHED_COUNT" P_BEHIND_COUNT="$BEHIND_COUNT" \
  P_DIRTY_COUNT="$DIRTY_COUNT" P_REVIEW_FILE="$RUN_DIR/review.md" P_QUESTIONS_FILE="$RUN_DIR/questions.md" \
  P_CONTROL_FILE="$RUN_DIR/control.md" P_RELEASE_FILE="$RUN_DIR/release.env" \
  P_STATUS_RELEASE_FILE="$RUN_DIR/git-status-release.txt" \
  P_FINGERPRINT_CMD="node $FINGERPRINT diff $REPO $RUN_DIR/fingerprint-release.json" \
  P_ANSWERS="${ANSWERS_TEXT:-none}" P_STAGE="${CUR_STAGE:-}" \
  P_RELEASE_LAST_FILE="$RUN_DIR/release-${ROUND:-1}.last.md" P_SKILL_RUN="$SKILL_DIR/run.sh" \
    perl -pe 's/\{\{(\w+)\}\}/exists $ENV{"P_$1"} ? $ENV{"P_$1"} : "{{$1}}"/ge' "$1"
}

# Runs a command in its own process group and stops the group after $1 seconds (exit 124).
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

summary_tail() {
  local head origin
  head="$(git -C "$REPO" rev-parse HEAD)"
  origin="$(git -C "$REPO" rev-parse --verify -q origin/main || echo '?')"
  {
    echo "## Main checkout state"
    echo
    echo "- Branch: $(git -C "$REPO" rev-parse --abbrev-ref HEAD); HEAD before: ${HEAD_BEFORE:0:12}, now: ${head:0:12}; origin/main: ${origin:0:12} (at review ${ORIGIN_SHA:0:12}, package base ${BASE_SHA:0:12})"
    echo "- Local commits outside origin/main: $(git -C "$REPO" rev-list --count origin/main..HEAD 2>/dev/null || echo '?'); origin/main commits missing locally: $(git -C "$REPO" rev-list --count HEAD..origin/main 2>/dev/null || echo '?'); uncommitted paths: $(dirty_count)"
    echo "- Worktrees: $(git -C "$REPO" worktree list --porcelain | grep -c '^worktree '); local branches: $(git -C "$REPO" for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' ')"
    echo
  } >>"$SUMMARY"
}

stop_for_questions() {
  PENDING_STAGE="$1"
  save_state
  {
    echo "## Waiting for answers"
    echo
    echo "- Questions: questions.md; write answers to answers.md"
    echo "- Continue: run.sh --resume \"$RUN_DIR\" (stage $PENDING_STAGE)"
    echo
  } >>"$SUMMARY"
  summary_tail
  log "Agent waits for answers: $RUN_DIR/questions.md. Summary: $SUMMARY"
  exit 10
}

# The release comes from the main checkout on main only; extra branches and worktrees need the owner.
check_single_tree() {
  local trees branches
  trees="$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')"
  branches="$(git -C "$REPO" for-each-ref --format='%(refname:short)' refs/heads | grep -vx main || true)"
  if [ "$trees" -gt 1 ] || [ -n "$branches" ]; then
    echo "Besides the main checkout on main there are other worktrees or local branches (SKILL.md, Single tree):" >&2
    git -C "$REPO" worktree list >&2
    [ -z "$branches" ] || printf 'branches: %s\n' "$(echo "$branches" | tr '\n' ' ')" >&2
    exit 13
  fi
}

run_review() {
  local prompt start
  prompt="$(render "$PROMPTS_DIR/review.md")"
  printf '%s\n' "$prompt" >"$RUN_DIR/review.prompt.md"
  if [ "$DRY_RUN" = 1 ]; then log "(dry-run) agy --model \"$AGY_MODEL\" -p <review.prompt.md>"; return 0; fi
  log "Stage 1 - package review (agy, $AGY_MODEL, timeout ${AGY_TIMEOUT}s)"
  node "$FINGERPRINT" snapshot "$REPO" "$RUN_DIR/fingerprint-before-review.json"
  start=$(date +%s)
  ( cd "$REPO" && export GENERAL_RELEASE_STAGE=review && with_timeout "$AGY_TIMEOUT" \
      agy --dangerously-skip-permissions --model "$AGY_MODEL" -p "$prompt" </dev/null ) >"$RUN_DIR/review.log" 2>&1
  STAGE_RC=$?
  [ "$STAGE_RC" != 124 ] || log "Review timed out after ${AGY_TIMEOUT}s."
  # The agent may print the report without writing the file.
  if [ ! -s "$RUN_DIR/review.md" ] && grep -aq 'RESULT:' "$RUN_DIR/review.log"; then
    cp "$RUN_DIR/review.log" "$RUN_DIR/review.md"
  fi
  {
    echo "### Review (agy)"
    echo "- Exit code: $STAGE_RC, duration: $(minutes_since "$start") min"
    echo "- Result: $(result_line "$RUN_DIR/review.md" "$RUN_DIR/review.log" || true)"
    echo "- Report: review.md; log: review.log"
    echo "- Paths changed during the review (the reviewer must not edit code; consider parallel sessions):"
    node "$FINGERPRINT" diff "$REPO" "$RUN_DIR/fingerprint-before-review.json"
    echo
  } >>"$SUMMARY"
  [ -s "$RUN_DIR/review.md" ]
}

# $1 - stage (apply | release), $2 - reasoning effort, $3 - name of the variable holding the codex session id.
run_codex() {
  local stage="$1" effort="$2" sid_var="$3" log_file last prompt start rc sid
  log_file="$RUN_DIR/$stage-$ROUND.log"
  last="$RUN_DIR/$stage-$ROUND.last.md"
  prompt="$(render "$PROMPTS_DIR/$stage.md")"
  if [ -n "${ANSWERS_TEXT:-}" ]; then prompt="$prompt

$(render "$PROMPTS_DIR/resume.md")"; fi
  printf '%s\n' "$prompt" >"$RUN_DIR/$stage-$ROUND.prompt.md"
  if [ "$DRY_RUN" = 1 ]; then log "(dry-run) codex exec --model $CODEX_MODEL ($effort) <$stage-$ROUND.prompt.md>"; return 0; fi
  log "Stage $stage (codex, $CODEX_MODEL, $effort), round $ROUND"
  node "$FINGERPRINT" snapshot "$REPO" "$RUN_DIR/fingerprint-before-$stage-$ROUND.json"
  start=$(date +%s)
  rc=1
  sid="${!sid_var:-}"
  if [ -n "$sid" ] && [ -n "${ANSWERS_TEXT:-}" ]; then
    # Continue the same session: the context exists, so send only the answers.
    ( cd "$REPO" && GENERAL_RELEASE_STAGE="$stage" codex exec resume "$sid" \
        --dangerously-bypass-approvals-and-sandbox --model "$CODEX_MODEL" \
        --config "model_reasoning_effort=\"$effort\"" --config "project_doc_max_bytes=$CODEX_DOC_BYTES" -o "$last" \
        "$(render "$PROMPTS_DIR/resume.md")" </dev/null ) >"$log_file" 2>&1
    rc=$?
    { [ $rc -eq 0 ] && [ -s "$last" ]; } || log "  session $sid could not resume (exit $rc); retrying with the full prompt"
  fi
  if [ $rc -ne 0 ] || [ ! -s "$last" ]; then
    ( cd "$REPO" && GENERAL_RELEASE_STAGE="$stage" codex exec --dangerously-bypass-approvals-and-sandbox \
        --model "$CODEX_MODEL" --config "model_reasoning_effort=\"$effort\"" --config "project_doc_max_bytes=$CODEX_DOC_BYTES" -C "$REPO" -o "$last" \
        "$prompt" </dev/null ) >>"$log_file" 2>&1
    rc=$?
  fi
  sid="$(grep -a -i -m1 'session id:' "$log_file" | sed 's/.*[Ss]ession id:[[:space:]]*//' | tr -d '[:space:]')"
  if [ -n "$sid" ]; then printf -v "$sid_var" '%s' "$sid"; fi
  STAGE_RESULT="$(result_line "$last" "$log_file" || true)"
  {
    echo "### Stage $stage (codex, $effort), round $ROUND"
    echo "- Exit code: $rc, duration: $(minutes_since "$start") min"
    echo "- Result: ${STAGE_RESULT:-no RESULT line}"
    echo "- Answer: $stage-$ROUND.last.md; log: $stage-$ROUND.log"
    [ "$stage" = release ] && echo "- Release: release.env (SHA, tag, dist directory, checksums). After the source commit, package paths match HEAD, so a \"change disappeared\" note for paths in git-status-release.txt is expected; inspect paths outside the package."
    echo "- Paths changed during the stage (including parallel sessions):"
    node "$FINGERPRINT" diff "$REPO" "$RUN_DIR/fingerprint-before-$stage-$ROUND.json"
    echo
  } >>"$SUMMARY"
}

# Default release path: the orchestrator performs the release itself from the rendered prompt.
hand_release_to_orchestrator() {
  local prompt="$RUN_DIR/release-$ROUND.prompt.md"
  { render "$PROMPTS_DIR/release-orchestrator.md"; echo; render "$PROMPTS_DIR/release.md"; } >"$prompt"
  if [ "$DRY_RUN" = 1 ]; then log "(dry-run) release by the orchestrator <release-$ROUND.prompt.md>"; return 0; fi
  {
    echo "### Stage release (orchestrator), round $ROUND"
    echo "- Checklist: release-$ROUND.prompt.md; the orchestrator writes its answer to release-$ROUND.last.md and runs --finish"
    echo
  } >>"$SUMMARY"
}

# The release starts only from a state the orchestrator has checked.
check_release_gate() {
  grep -q '^VERDICT: RELEASE' "$RUN_DIR/control.md" 2>/dev/null || \
    fail "No line \"VERDICT: RELEASE\" in $RUN_DIR/control.md - the orchestrator's control comes first."
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$HEAD_BEFORE" ] || \
    fail "HEAD changed after the review (${HEAD_BEFORE:0:12} -> $(git -C "$REPO" rev-parse --short=12 HEAD)): new commits are unchecked; start a new run."
}

# Signing and publication prerequisites are checked by name only; values are never printed.
check_release_prerequisites() {
  local v
  for v in APPLE_TEAM_ID APPLE_SIGNING_IDENTITY NOTARYTOOL_PROFILE; do
    [ -n "${!v:-}" ] || fail "Environment variable $v is not set. Ask the owner to export it before the release (RUNBOOK-RELEASE.md)."
  done
  for cmd in gh xcodebuild xcrun xcodegen hdiutil codesign; do command -v "$cmd" >/dev/null || fail "Missing command: $cmd"; done
  gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated (gh auth status)."
}

# A lag behind origin/main does not block: the release agent merges origin/main into main after committing.
fetch_origin() {
  git -C "$REPO" fetch --quiet --prune origin '+refs/heads/main:refs/remotes/origin/main' || fail "Could not update origin/main."
}

validate_version() {
  local cur_v cur_b
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid --version: $VERSION" >&2; exit 2; }
  [[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid --build: $BUILD" >&2; exit 2; }
  cur_v="$(xcconfig_value MARKETING_VERSION)"; cur_b="$(xcconfig_value CURRENT_PROJECT_VERSION)"
  [ -n "$cur_v" ] && [ -n "$cur_b" ] || fail "Config/PlayerMac.xcconfig has no MARKETING_VERSION / CURRENT_PROJECT_VERSION."
  [ "$(printf '%s\n%s\n' "$cur_v" "$VERSION" | sort -V | tail -n 1)" = "$VERSION" ] && [ "$cur_v" != "$VERSION" ] || \
    fail "Version $VERSION must be greater than the current $cur_v."
  [ "$BUILD" -gt "$cur_b" ] || fail "Build $BUILD must be greater than the current $cur_b."
  [ ! -e "$REPO/dist/$VERSION-build$BUILD" ] || fail "dist/$VERSION-build$BUILD already exists."
  [ "$DRY_RUN" = 1 ] && return 0
  git -C "$REPO" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && fail "Tag v$VERSION already exists locally."
  git -C "$REPO" ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null 2>&1 && fail "Tag v$VERSION already exists on origin."
  # Read-only feed preflight: both numbers must exceed every appcast item.
  ( cd "$REPO" && python3 Scripts/update-appcast.py --check --appcast site/appcast.xml --version "$VERSION" --build "$BUILD" ) \
    || fail "The appcast preflight rejected version $VERSION build $BUILD."
  return 0
}

# ---------- preparation ----------
[ -f "$FINGERPRINT" ] || fail "Missing $FINGERPRINT (shared with research-execute)."
if [ "$DRY_RUN" = 0 ]; then
  for cmd in agy codex; do command -v "$cmd" >/dev/null || fail "Missing command: $cmd"; done
  [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = main ] || fail "The main checkout is not on main; branches are never switched (AGENTS.md, rule 3)."
  [ "$MODE" = resume ] || check_single_tree
  mkdir -p "$STATE_ROOT/runs"
  # Logs may hold signing and publication output; they must never reach Git.
  git -C "$REPO" check-ignore -q "$STATE_ROOT/runs" || fail "$STATE_ROOT is not ignored by Git (.tmp/ must be in .gitignore)."
  LOCK="$STATE_ROOT/lock"
  if ! mkdir "$LOCK" 2>/dev/null; then
    fail "Another release run is active (lock $LOCK, pid $(cat "$LOCK/pid" 2>/dev/null)). If that process is gone, remove the lock."
  fi
  echo $$ >"$LOCK/pid"
  trap 'rm -rf "$LOCK"' EXIT
fi

ANSWERS_TEXT=""
if [ "$MODE" = new ]; then
  validate_version
  [ "$DRY_RUN" = 1 ] || fetch_origin
  ORIGIN_SHA="$(git -C "$REPO" rev-parse --verify origin/main)" || fail "No origin/main."
  HEAD_BEFORE="$(git -C "$REPO" rev-parse HEAD)"
  BASE_SHA="$(git -C "$REPO" merge-base HEAD origin/main)" || fail "main and origin/main have no common base."
  UNPUSHED_COUNT="$(git -C "$REPO" rev-list --count origin/main..HEAD)"
  BEHIND_COUNT="$(git -C "$REPO" rev-list --count HEAD..origin/main)"
  DIRTY_COUNT="$(dirty_count)"
  if [ "$UNPUSHED_COUNT" = 0 ] && [ "$DIRTY_COUNT" = 0 ]; then
    echo "Nothing to release: no local commits outside origin/main and no uncommitted changes."
    exit 0
  fi
  ROUND=1; APPLY_SESSION=""; RELEASE_SESSION=""; RELEASE_RUNNER=""
  if [ "$DRY_RUN" = 1 ]; then RUN_DIR="$STATE_ROOT/runs/dry-run-$(date '+%Y-%m-%d_%H-%M-%S')"
  else RUN_DIR="$STATE_ROOT/runs/$(date '+%Y-%m-%d_%H-%M-%S')"; fi
  mkdir -p "$RUN_DIR"
  [ "$DRY_RUN" = 1 ] || ln -sfn "$RUN_DIR" "$STATE_ROOT/latest"
  SUMMARY="$RUN_DIR/summary.md"
  git -C "$REPO" -c core.quotepath=off status --short --untracked-files=all >"$RUN_DIR/git-status-before.txt"
  git -C "$REPO" log --oneline origin/main..HEAD >"$RUN_DIR/unpushed-commits.txt"
  git -C "$REPO" log --oneline HEAD..origin/main >"$RUN_DIR/origin-ahead-commits.txt"
  {
    echo "# General Kinrox Mac release $VERSION (build $BUILD) - $(TZ=Europe/Moscow date '+%Y-%m-%d %H:%M') Europe/Moscow"
    echo
    echo "- origin/main ${ORIGIN_SHA:0:12}; HEAD ${HEAD_BEFORE:0:12}; package base (merge-base) ${BASE_SHA:0:12}"
    echo "- Package: local commits outside origin/main $UNPUSHED_COUNT (unpushed-commits.txt), uncommitted paths $DIRTY_COUNT (git-status-before.txt)"
    echo "- origin/main commits missing locally: $BEHIND_COUNT (origin-ahead-commits.txt) - merged into main during the release"
    if [ "$RELEASE_AGENT" = codex ]; then release_desc="codex $CODEX_MODEL ($RELEASE_EFFORT)"; else release_desc="orchestrator"; fi
    echo "- Models: review agy $AGY_MODEL; apply codex $CODEX_MODEL ($APPLY_EFFORT); release $release_desc"
    echo
  } >"$SUMMARY"
  log "Run: $RUN_DIR"

  PENDING_STAGE=review
  if ! run_review; then
    [ "$DRY_RUN" = 1 ] || { save_state; summary_tail; log "The review produced no report. Log: $RUN_DIR/review.log"; exit 1; }
  fi
  CUR_STAGE=apply
  run_codex apply "$APPLY_EFFORT" APPLY_SESSION
  if [ "$DRY_RUN" = 1 ]; then
    CUR_STAGE=release
    if [ "$RELEASE_AGENT" = codex ]; then run_codex release "$RELEASE_EFFORT" RELEASE_SESSION
    else hand_release_to_orchestrator; fi
    log "dry-run: prompts saved in $RUN_DIR"
    exit 0
  fi
  [ -s "$RUN_DIR/questions.md" ] && stop_for_questions apply
  PENDING_STAGE=control
  save_state
  summary_tail
  log "Review and application finished - the orchestrator's control is needed. Summary: $SUMMARY"
  exit 11
fi

# ---------- continuation and release: an existing run ----------
RUN_DIR="$(cd "$RUN_ARG" 2>/dev/null && pwd -P)" || fail "No run directory: $RUN_ARG"
[ -f "$RUN_DIR/state.env" ] || fail "No state.env in $RUN_DIR"
# shellcheck disable=SC1091
. "$RUN_DIR/state.env"
SUMMARY="$RUN_DIR/summary.md"
RELEASE_RUNNER="${RELEASE_RUNNER:-}"

# The orchestrator reports its release: release-N.last.md must end with the RESULT line.
if [ "$MODE" = finish ]; then
  [ "$PENDING_STAGE" = release ] && [ "$RELEASE_RUNNER" = orchestrator ] || \
    fail "--finish applies only to an orchestrator release in progress (stage: $PENDING_STAGE, runner: ${RELEASE_RUNNER:-codex})."
  last="$RUN_DIR/release-$ROUND.last.md"
  [ -s "$last" ] || fail "No answer: $last (write the release report ending with the RESULT line)."
  STAGE_RESULT="$(result_line "$last" || true)"
  {
    echo "- Orchestrator result, round $ROUND: ${STAGE_RESULT:-no RESULT line} (release-$ROUND.last.md)"
    echo "- Paths changed since the release started (package paths match HEAD after the source commit):"
    node "$FINGERPRINT" diff "$REPO" "$RUN_DIR/fingerprint-release.json"
    echo
  } >>"$SUMMARY"
  case "$STAGE_RESULT" in
    "RESULT: RELEASED"*)
      PENDING_STAGE=done; save_state; summary_tail
      log "Release finished. Summary: $SUMMARY"; exit 0 ;;
    *)
      save_state; summary_tail
      log "The release did not finish: ${STAGE_RESULT:-no RESULT line}. Continue it and run --finish again."; exit 12 ;;
  esac
fi

if [ "$MODE" = resume ]; then
  case "$PENDING_STAGE" in
    apply|control) CUR_STAGE=apply ;;
    release)
      [ "$RELEASE_RUNNER" != orchestrator ] || \
        fail "The orchestrator performs this release itself: continue from release-$ROUND.prompt.md, then run --finish."
      CUR_STAGE=release ;;
    *) fail "Nothing to continue in this run (stage: $PENDING_STAGE). A new package needs a new run." ;;
  esac
  [ -s "$RUN_DIR/answers.md" ] || fail "No answers: $RUN_DIR/answers.md"
  ANSWERS_TEXT="$(cat "$RUN_DIR/answers.md")"
  ROUND=$((ROUND + 1))
  mv "$RUN_DIR/answers.md" "$RUN_DIR/answers-$((ROUND - 1)).md"
  [ -f "$RUN_DIR/questions.md" ] && mv "$RUN_DIR/questions.md" "$RUN_DIR/questions-$((ROUND - 1)).md"
else
  [ "$PENDING_STAGE" = control ] || fail "--release is possible only after control (stage now: $PENDING_STAGE)."
  check_release_gate
  check_release_prerequisites
  CUR_STAGE=release
  ROUND=$((ROUND + 1))
  RELEASE_RUNNER="$RELEASE_AGENT"
fi
ln -sfn "$RUN_DIR" "$STATE_ROOT/latest"

if [ "$CUR_STAGE" = apply ]; then
  log "Continuing the review application, round $ROUND"
  run_codex apply "$APPLY_EFFORT" APPLY_SESSION
  [ -s "$RUN_DIR/questions.md" ] && stop_for_questions apply
  PENDING_STAGE=control
  save_state
  summary_tail
  log "Application finished - repeat the orchestrator's control. Summary: $SUMMARY"
  exit 11
fi

# Release stage. On continuation the agent may already have built, committed, pushed, or published,
# so the HEAD check and the "inspected state" snapshot belong to the first release launch only.
if [ "$MODE" = release ]; then
  fetch_origin
  node "$FINGERPRINT" snapshot "$REPO" "$RUN_DIR/fingerprint-release.json"
  git -C "$REPO" -c core.quotepath=off status --short --untracked-files=all >"$RUN_DIR/git-status-release.txt"
  PENDING_STAGE=release
  save_state
  log "Release $VERSION (build $BUILD): run $RUN_DIR"
  if [ "$RELEASE_RUNNER" = orchestrator ]; then
    hand_release_to_orchestrator
    log "Release handed to the orchestrator: $RUN_DIR/release-$ROUND.prompt.md; afterwards run --finish \"$RUN_DIR\"."
    exit 14
  fi
fi
run_codex release "$RELEASE_EFFORT" RELEASE_SESSION
[ -s "$RUN_DIR/questions.md" ] && stop_for_questions release
case "$STAGE_RESULT" in
  "RESULT: RELEASED"*)
    PENDING_STAGE=done; save_state; summary_tail
    log "Release finished. Summary: $SUMMARY"; exit 0 ;;
  *)
    # An unfinished release continues with an orchestrator answer (--resume), but never starts over.
    PENDING_STAGE=release; save_state; summary_tail
    log "The release did not finish: ${STAGE_RESULT:-no RESULT line}. Summary: $SUMMARY"; exit 12 ;;
esac
