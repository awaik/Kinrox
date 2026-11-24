#!/usr/bin/env bash
# Execute a Kinrox research plan: review, then implementation.
# Usage: run.sh [--dry-run] [--stage review|execute] <research.md>
#        run.sh --resume <run-directory>
# Exit: 0 complete/selected stage finished; 10 questions; 12 partial; 1 error; 2 usage.
set -uo pipefail

fail() { echo "$*" >&2; exit 1; }
SKILL_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROMPTS_DIR="$SKILL_DIR/prompts"
REPO="$(git -C "$SKILL_DIR" rev-parse --show-toplevel 2>/dev/null)" || fail "The skill must be inside the Kinrox checkout."
RES_DIR="$REPO/docs/RESEARCHES"
STATE_ROOT="$REPO/.tmp/scratch/research-execute"
[ -f "$REPO/.agents/lib/agy-watch.sh" ] || fail "Missing $REPO/.agents/lib/agy-watch.sh (agy idle watchdog)."
. "$REPO/.agents/lib/agy-watch.sh"
# Owner decision 2026-11-11: the review uses only Gemini 4 Carbon (High); Argon and 3.8 Flash are refused.
AGY_MODEL="${AGY_MODEL:-Gemini 4 Carbon (High)}"
AGY_TIMEOUT="${AGY_TIMEOUT:-5400}"
EXEC_TIMEOUT="${EXEC_TIMEOUT:-$AGY_TIMEOUT}"
# Owner decision 2026-11-20: Codex is no longer used. Implementation runs on agy Gemini 4 Neon at the
# level of EXEC_EFFORT: high by default, xhigh for complex architectural, concurrency, C-API, or
# protocol plans and for hard ones.
EXEC_EFFORT="${EXEC_EFFORT:-high}"
STAGE_ONLY=""; RESUME_DIR=""; DRY_RUN=0; DOC_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stage|--resume)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
      if [ "$1" = --stage ]; then STAGE_ONLY="$2"; else RESUME_DIR="$2"; fi
      shift ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    -*) echo "Unknown argument: $1" >&2; exit 2 ;;
    *) [ -z "$DOC_ARG" ] || { echo "Unexpected argument: $1" >&2; exit 2; }; DOC_ARG="$1" ;;
  esac
  shift
done
case "$STAGE_ONLY" in ""|review|execute) ;; *) echo "--stage must be review or execute" >&2; exit 2 ;; esac
# Google models other than Carbon High (Argon, 3.8 Flash, lower Carbon levels) are refused.
case "$(printf '%s' "$AGY_MODEL" | tr '[:upper:]' '[:lower:]')" in
  *gemini*) case "$AGY_MODEL" in "Gemini 4 Carbon (High)"|gemini-4-carbon-high) ;;
    *) fail "Forbidden agy model: $AGY_MODEL. Only Gemini 4 Carbon (High) is allowed (owner decision 2026-11-11)." ;; esac ;;
esac
case "$AGY_TIMEOUT" in ""|*[!0-9]*|0*) fail "AGY_TIMEOUT must be a positive number of seconds." ;; esac
case "$EXEC_TIMEOUT" in ""|*[!0-9]*|0*) fail "EXEC_TIMEOUT must be a positive number of seconds." ;; esac
# agy model names carry the reasoning level; Neon has no max/ultra level.
neon_model() {
  case "$1" in
    low) echo "Gemini 4 Neon (Low)" ;; medium) echo "Gemini 4 Neon (Medium)" ;;
    high) echo "Gemini 4 Neon (High)" ;; xhigh) echo "Gemini 4 Neon (XHigh)" ;; *) return 1 ;;
  esac
}
EXEC_MODEL="$(neon_model "$EXEC_EFFORT")" || fail "EXEC_EFFORT must be low, medium, high, or xhigh."
[ -z "${RESEARCH_EXECUTE_STAGE:-}" ] || fail "Nested pipeline execution is prohibited (stage: $RESEARCH_EXECUTE_STAGE)."
for cmd in git perl node; do command -v "$cmd" >/dev/null || fail "Missing command: $cmd"; done

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$RUN_DIR/run.log" >&2; }
doc_key() {
  local b; b="$(basename "$1")"; b="${b#REVIEWED - }"; b="${b#REVEIWED - }"; b="${b#DONE - }"
  printf '%s' "$b"
}
find_doc() {
  local k="$1" c found=""
  for c in "$RES_DIR/DONE/DONE - $k" "$RES_DIR/DONE - $k" "$RES_DIR/REVIEWED - $k" "$RES_DIR/REVEIWED - $k" "$RES_DIR/$k"; do
    [ -f "$c" ] || continue
    if [ -n "$found" ]; then
      echo "Conflicting document copies: $found and $c. No files were changed." >&2
      return 1
    fi
    found="$c"
  done
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}
doc_stage() {
  case "$(dirname "$1")" in "$RES_DIR/DONE") echo done; return ;; esac
  case "$(basename "$1")" in "DONE - "*|"REVIEWED - "*|"REVEIWED - "*) echo execute ;; *) echo review ;; esac
}
doc_status() { head -n 80 "$1" | sed -n 's/^Status:[[:space:]]*//p' | head -n 1; }
result_line() { grep -a -h 'RESULT:' "$@" 2>/dev/null | tail -n 1 | sed 's/^.*RESULT:/RESULT:/'; }
save_state() {
  {
    printf 'DOC_KEY=%q\n' "$DOC_KEY"
    printf 'PENDING_STAGE=%q\n' "$PENDING_STAGE"
    printf 'STAGE_ONLY=%q\n' "$STAGE_ONLY"
    printf 'HEAD_BEFORE=%q\n' "$HEAD_BEFORE"
    printf 'ROUND=%q\n' "$ROUND"
    printf 'EXEC_SESSION=%q\n' "${EXEC_SESSION:-}"
  } >"$RUN_DIR/state.env"
}
# Values come from the environment, not shell evaluation of rendered text.
render() {
  P_DOC_FILE="$DOC" P_REPO="$REPO" P_RUN_DIR="$RUN_DIR" P_QUESTIONS_FILE="$RUN_DIR/questions.md" \
  P_ANSWERS="${ANSWERS_TEXT:-none}" P_STAGE="${CUR_STAGE:-}" \
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
stage_prompt() {
  render "$PROMPTS_DIR/$1.md"
  if [ -n "${ANSWERS_TEXT:-}" ]; then printf '\n\n'; render "$PROMPTS_DIR/resume.md"; fi
}
run_review() {
  local prompt start
  STAGE_LOG="$RUN_DIR/review-$ROUND.log"
  prompt="$(stage_prompt review)"
  printf '%s\n' "$prompt" >"$RUN_DIR/review-$ROUND.prompt.md"
  if [ "$DRY_RUN" = 1 ]; then log "dry-run: agy review ($AGY_MODEL, timeout ${AGY_TIMEOUT}s)"; return; fi
  log "Stage 1 - plan review (agy, $AGY_MODEL, timeout ${AGY_TIMEOUT}s), round $ROUND"
  start=$(date +%s); : >"$STAGE_LOG"
  ( cd "$REPO" && export RESEARCH_EXECUTE_STAGE=review && with_timeout "$AGY_TIMEOUT" "${AGY_WATCHED[@]}" --log "$STAGE_LOG" -- \
      agy --dangerously-skip-permissions --model "$AGY_MODEL" -p "$prompt" </dev/null ) >>"$STAGE_LOG" 2>&1
  STAGE_RC=$?; STAGE_MIN=$(( ($(date +%s) - start) / 60 )); STAGE_RESULT="$(result_line "$STAGE_LOG")"
  [ "$STAGE_RC" != 124 ] || log "Review timed out after ${AGY_TIMEOUT}s."
}
# agy prints one JSON object: its response from $1 goes to $2, the conversation id to stdout.
agy_result() {
  node -e '
    const fs = require("fs"); const [src, dst] = process.argv.slice(1);
    const lines = fs.readFileSync(src, "utf8").split("\n").reverse();
    let o; for (const l of lines) { try { o = JSON.parse(l); break; } catch {} }
    if (!o) process.exit(3);
    fs.writeFileSync(dst, o.response || "");
    process.stdout.write(o.conversation_id || "");
    process.exit(o.status === "SUCCESS" ? 0 : 4);
  ' "$1" "$2"
}
# A continued conversation still gets the full prompt: agy silently starts a new one for an unknown id.
run_execute() {
  local prompt start rc last="$RUN_DIR/execute-$ROUND.last.md" json="$RUN_DIR/execute-$ROUND.json" sid conv=()
  STAGE_LOG="$RUN_DIR/execute-$ROUND.log"
  prompt="$(stage_prompt execute)"
  printf '%s\n' "$prompt" >"$RUN_DIR/execute-$ROUND.prompt.md"
  if [ "$DRY_RUN" = 1 ]; then log "dry-run: agy implementation ($EXEC_MODEL)"; return; fi
  log "Stage 2 - implementation (agy, $EXEC_MODEL), round $ROUND"
  start=$(date +%s); : >"$STAGE_LOG"
  if [ -n "${ANSWERS_TEXT:-}" ]; then
    case "${EXEC_SESSION:-}" in agy:?*) conv=(--conversation "${EXEC_SESSION#agy:}") ;; esac
  fi
  ( cd "$REPO" && export RESEARCH_EXECUTE_STAGE=execute && with_timeout "$EXEC_TIMEOUT" "${AGY_WATCHED[@]}" --log "$STAGE_LOG" -- \
      agy --dangerously-skip-permissions --model "$EXEC_MODEL" \
      --output-format json ${conv[@]+"${conv[@]}"} -p "$prompt" </dev/null ) >"$json" 2>>"$STAGE_LOG"
  rc=$?
  [ "$rc" != 124 ] || log "Implementation timed out after ${EXEC_TIMEOUT}s."
  sid="$(agy_result "$json" "$last")" || { [ "$rc" != 0 ] || rc=1; }
  cat "$last" >>"$STAGE_LOG" 2>/dev/null
  [ -z "$sid" ] || EXEC_SESSION="agy:$sid"
  STAGE_RC=$rc; STAGE_MIN=$(( ($(date +%s) - start) / 60 )); STAGE_RESULT="$(result_line "$last" "$STAGE_LOG")"
}
summary_stage() {
  {
    echo "### $1 (round $ROUND)"
    echo "- Exit code: $STAGE_RC; duration: $STAGE_MIN min"
    echo "- Document: ${DOC#"$REPO"/}"
    echo "- Status: $(doc_status "$DOC")"
    echo "- Agent result: ${STAGE_RESULT:-no RESULT line}"
    echo "- Log: ${STAGE_LOG#"$REPO"/}"
    echo
  } >>"$SUMMARY"
}
summary_tail() {
  {
    echo "## Checkout state"
    echo "- Branch: $(git -C "$REPO" rev-parse --abbrev-ref HEAD); HEAD before: ${HEAD_BEFORE:0:12}; after: $(git -C "$REPO" rev-parse --short=12 HEAD)"
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$HEAD_BEFORE" ] || echo "- WARNING: HEAD changed; investigate unexpected commits."
    echo "- Paths changed since startup (including concurrent sessions):"
    node "$SKILL_DIR/fingerprint.mjs" diff "$REPO" "$RUN_DIR/fingerprint-before.json"
    echo
  } >>"$SUMMARY"
}
stop_for_questions() {
  PENDING_STAGE="$1"; save_state
  {
    echo "## Awaiting answers"
    echo "- Questions: $RUN_DIR/questions.md"
    echo "- Write answers to: $RUN_DIR/answers.md"
    echo "- Resume: run.sh --resume \"$RUN_DIR\" (stage $PENDING_STAGE)"
  } >>"$SUMMARY"
  summary_tail
  log "Awaiting answers: $RUN_DIR/questions.md. Summary: $SUMMARY"
  exit 10
}

ANSWERS_TEXT=""
if [ -n "$RESUME_DIR" ]; then
  [ "$DRY_RUN" = 0 ] && [ -z "$DOC_ARG" ] && [ -z "$STAGE_ONLY" ] || fail "--resume cannot be combined with other options or a document."
  RUN_DIR="$(cd "$RESUME_DIR" 2>/dev/null && pwd -P)" || fail "Run directory not found: $RESUME_DIR"
  case "$RUN_DIR" in "$STATE_ROOT/runs/"*) ;; *) fail "Run directory must belong to this checkout." ;; esac
  [ -f "$RUN_DIR/state.env" ] || fail "Missing state.env in $RUN_DIR"
  # This is local state generated by this script; never source agent output here.
  . "$RUN_DIR/state.env"
  [ -s "$RUN_DIR/answers.md" ] || fail "Missing answers: $RUN_DIR/answers.md"
  ANSWERS_TEXT="$(cat "$RUN_DIR/answers.md")"
  ROUND=$((ROUND + 1))
  case "$PENDING_STAGE" in review|execute) ;; *) fail "Nothing to resume (stage: $PENDING_STAGE)." ;; esac
  STAGES="$PENDING_STAGE"
  [ "$PENDING_STAGE" != review ] || [ "$STAGE_ONLY" = review ] || STAGES="review execute"
  DOC="$(find_doc "$DOC_KEY")" || fail "Document missing or conflicting: $DOC_KEY"
else
  [ -n "$DOC_ARG" ] || { sed -n '2,5p' "$0" >&2; exit 2; }
  case "$DOC_ARG" in *.md) ;; *) fail "Expected a Markdown research document." ;; esac
  dir="$(cd "$(dirname "$DOC_ARG")" 2>/dev/null && pwd -P)" || fail "Document directory not found."
  real_res="$(cd "$RES_DIR" && pwd -P)" || fail "Research directory not found."
  case "$dir" in "$real_res"|"$real_res/DONE") ;; *) fail "Document must be in this checkout's docs/RESEARCHES/." ;; esac
  DOC_KEY="$(doc_key "$DOC_ARG")"
  DOC="$(find_doc "$DOC_KEY")" || fail "Document missing or conflicting: $DOC_KEY"
  [ -f "$DOC_ARG" ] || echo "Document already renamed: ${DOC#"$REPO"/}" >&2
  case "$(doc_stage "$DOC")" in
    done) echo "Document already completed: ${DOC#"$REPO"/}" >&2; exit 0 ;;
    review) STAGES="review execute" ;;
    execute) STAGES="execute" ;;
  esac
  if [ "$STAGE_ONLY" = review ] && [ "$(doc_stage "$DOC")" != review ]; then fail "Review already completed: $DOC"; fi
  if [ "$STAGE_ONLY" = execute ] && [ "$(doc_stage "$DOC")" != execute ]; then fail "Review required first: missing REVIEWED - prefix."; fi
  [ -z "$STAGE_ONLY" ] || STAGES="$STAGE_ONLY"
  ROUND=1; EXEC_SESSION=""
fi

if [ "$DRY_RUN" = 0 ]; then
  command -v agy >/dev/null || fail "Missing command: agy"
  [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = main ] || fail "Checkout must be on main; branch switching is prohibited."
fi
mkdir -p "$STATE_ROOT/runs" "$STATE_ROOT/locks" || exit 1
if [ "$DRY_RUN" = 0 ]; then
  LOCK="$STATE_ROOT/locks/$(printf '%s' "$DOC_KEY" | git hash-object --stdin | cut -c1-16)"
  mkdir "$LOCK" 2>/dev/null || fail "Document is locked: $LOCK (pid $(cat "$LOCK/pid" 2>/dev/null)). Verify ownership and process absence before removing it."
  echo $$ >"$LOCK/pid"
  release_lock() {
    if [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; then rm "$LOCK/pid"; rmdir "$LOCK"; fi
  }
  trap release_lock EXIT
fi

if [ -n "$RESUME_DIR" ]; then
  for name in answers questions; do
    [ ! -e "$RUN_DIR/$name-$((ROUND - 1)).md" ] || fail "Refusing to overwrite archived $name."
  done
  mv "$RUN_DIR/answers.md" "$RUN_DIR/answers-$((ROUND - 1)).md"
  [ ! -f "$RUN_DIR/questions.md" ] || mv "$RUN_DIR/questions.md" "$RUN_DIR/questions-$((ROUND - 1)).md"
else
  prefix="$(date '+%Y-%m-%d_%H-%M-%S')"
  [ "$DRY_RUN" = 0 ] || prefix="dry-run-$prefix"
  RUN_DIR="$(mktemp -d "$STATE_ROOT/runs/$prefix-XXXXXX")" || exit 1
  HEAD_BEFORE="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" -c core.quotepath=off status --short >"$RUN_DIR/git-status-before.txt"
  node "$SKILL_DIR/fingerprint.mjs" snapshot "$REPO" "$RUN_DIR/fingerprint-before.json" || exit 1
  {
    echo "# Research execution - $(date '+%Y-%m-%d %H:%M %Z')"
    echo "- Document: ${DOC#"$REPO"/}"
    echo "- Stages: $STAGES; review: agy $AGY_MODEL (timeout ${AGY_TIMEOUT}s); implementation: agy $EXEC_MODEL"
    echo "- Initial uncommitted paths: $(wc -l <"$RUN_DIR/git-status-before.txt" | tr -d ' ') (see git-status-before.txt)"
  } >"$RUN_DIR/summary.md"
fi
SUMMARY="$RUN_DIR/summary.md"
if [ "$DRY_RUN" = 0 ]; then
  if [ -e "$STATE_ROOT/latest" ] && [ ! -L "$STATE_ROOT/latest" ]; then fail "Refusing to overwrite non-symlink: $STATE_ROOT/latest"; fi
  ln -sfn "$RUN_DIR" "$STATE_ROOT/latest"
fi
log "Run: $RUN_DIR; stages: $STAGES"

for CUR_STAGE in $STAGES; do
  DOC="$(find_doc "$DOC_KEY")" || fail "Document missing or conflicting: $DOC_KEY"
  if [ "$CUR_STAGE" = review ]; then
    run_review
    [ "$DRY_RUN" = 0 ] || { ANSWERS_TEXT=""; continue; }
    DOC="$(find_doc "$DOC_KEY")" || fail "Document missing or conflicting after review."
    summary_stage "Plan review (agy)"
    ANSWERS_TEXT=""
    if [ -s "$RUN_DIR/questions.md" ]; then
      if [ "$(doc_stage "$DOC")" = review ]; then stop_for_questions review; fi
      stop_for_questions execute
    fi
    if [ "$STAGE_RC" != 0 ] || [ "$(doc_stage "$DOC")" != execute ]; then
      PENDING_STAGE=review; save_state; summary_tail
      log "Review did not complete (exit $STAGE_RC). Summary: $SUMMARY"; exit 1
    fi
    case "$(doc_status "$DOC")" in
      *"awaiting owner decision"*)
        printf '# Owner decision required\n\nReviewer status: %s\nSee %s\n' "$(doc_status "$DOC")" "$DOC" >"$RUN_DIR/questions.md"
        stop_for_questions execute ;;
    esac
    log "Review completed: $(basename "$DOC")"
  else
    run_execute
    [ "$DRY_RUN" = 0 ] || continue
    DOC="$(find_doc "$DOC_KEY")" || fail "Document missing or conflicting after implementation."
    summary_stage "Implementation (agy)"
    ANSWERS_TEXT=""
    [ ! -s "$RUN_DIR/questions.md" ] || stop_for_questions execute
    PENDING_STAGE=execute
    if [ "$STAGE_RC" = 0 ] && [ "$(doc_stage "$DOC")" = done ]; then PENDING_STAGE=done; fi
    save_state; summary_tail
    if [ "$PENDING_STAGE" = done ]; then log "Completed: ${DOC#"$REPO"/}. Summary: $SUMMARY"; exit 0; fi
    log "Implementation incomplete (exit $STAGE_RC). Summary: $SUMMARY"; exit 12
  fi
done
if [ "$DRY_RUN" = 1 ]; then log "dry-run: prompts saved in $RUN_DIR"; exit 0; fi
PENDING_STAGE=execute; save_state; summary_tail
log "Finished (review only). Summary: $SUMMARY"
