# Orchestrator release checklist

You, the orchestrator, perform this release stage yourself, without Codex (owner decision
2026-11-12: Codex limits run out quickly, and the release is mostly mechanical). The checklist
below was written for a release agent; read it with these substitutions:

- "Questions for the orchestrator": resolve what you can establish from code, documents, and
  project rules yourself, with evidence; ask the owner directly with the question tool only for
  owner decisions. The "no questions after the first push" rule still applies to you.
- The authority, the prohibitions, and every verification step stay exactly as written. Your own
  control of this package does not let you skip the release checks.
- Run long commands (checks, `build-release.sh` with notarization) in the background with a log
  file in `{{RUN_DIR}}`, wait for completion notifications without polling, and read only the
  tail and failures of each log.
- Maintain `{{RELEASE_FILE}}` as described, so an interrupted release can continue without
  repeating a finished build, commit, tag, push, or publication.
- When you finish or stop at a blocker, write the answer described in "Answer", ending with the
  `RESULT:` line, to `{{RELEASE_LAST_FILE}}`, then run:
  `{{SKILL_RUN}} --finish "{{RUN_DIR}}"` (exit 0 released, exit 12 not finished: continue and
  run `--finish` again).
