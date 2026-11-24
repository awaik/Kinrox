# agy idle watchdog for bash runners; source it after REPO is set (ported from direct-mcp, 2026-11-21).
# In -p mode agy sometimes finishes, prints "root agent idle; waiting for N background task(s)" to
# stderr, and waits forever for a task that no longer exists. agent-watchdog stops it only when that
# marker is the last stage-log line and nothing has shown work for AGY_IDLE_STOP_SECONDS; see
# .agents/lib/agent_watchdog.py. agy's stderr must be appended (2>>) to the log passed as --log.
#
# Usage: with_timeout <secs> "${AGY_WATCHED[@]}" --log <stage log> -- agy <args...>
# The single place for the threshold (the environment override exists for tests; 0 disables).
AGY_IDLE_STOP_SECONDS="${AGY_IDLE_STOP_SECONDS:-1800}"
case "$AGY_IDLE_STOP_SECONDS" in ""|*[!0-9]*) echo "AGY_IDLE_STOP_SECONDS must be a whole number of seconds." >&2; exit 1 ;; esac
# Threshold once a hang is confirmed: the agy conversation database holds a step left "running"
# after a stream interruption ("The stream was interrupted"; agy waits for it forever, possibly
# without the "root agent idle" marker). 0 disables. See AGENTS.md -> agy idle watchdog.
AGY_CONFIRMED_IDLE_STOP_SECONDS="${AGY_CONFIRMED_IDLE_STOP_SECONDS:-600}"
case "$AGY_CONFIRMED_IDLE_STOP_SECONDS" in ""|*[!0-9]*) echo "AGY_CONFIRMED_IDLE_STOP_SECONDS must be a whole number of seconds." >&2; exit 1 ;; esac
AGY_WATCHED=(python3 "$REPO/.agents/bin/agent-watchdog" --idle-seconds "$AGY_IDLE_STOP_SECONDS"
  --confirmed-idle-seconds "$AGY_CONFIRMED_IDLE_STOP_SECONDS")
[ -x "$REPO/.agents/bin/agent-watchdog" ] || { echo "Missing $REPO/.agents/bin/agent-watchdog" >&2; exit 1; }
