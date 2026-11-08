# Research, plans, and reports

This directory contains task documents: bug investigations, plans, reviews,
verification results, and release reports. Keep ongoing work in the directory
root and completed documents in `DONE/`. Write documentation in English, as
required by the repository's [AGENTS.md](../../AGENTS.md).

## Directory layout

| Path | Contents |
|---|---|
| `docs/RESEARCHES/` | Ongoing investigations, plans, implementation, and work awaiting a requested review |
| `docs/RESEARCHES/DONE/` | Completed documents and their supporting artifacts |

Create `DONE/` when first needed. Existing completed documents in the root may be
migrated in a separate task; do not bulk move unrelated documents while working
on another task.

## Filenames

Use `YYYY-MM-DD_HH-MM_<topic>.md`: the creation date and time in `Europe/Moscow`,
followed by a descriptive English topic. Use only Windows-compatible characters:
no `: / \ * ? " < > |`, and no trailing period or space.

```text
2026-10-29_15-00_Release-tooling-review.md
```

Use at most one status prefix:

| Stage | Filename | Location |
|---|---|---|
| In progress | `2026-10-29_15-00_Release-tooling-review.md` | Root |
| Separately reviewed, with work remaining | `REVIEWED - 2026-10-29_15-00_Release-tooling-review.md` | Root |
| Complete | `DONE - 2026-10-29_15-00_Release-tooling-review.md` | `DONE/` |

Keep the original date, time, and topic when changing the prefix. Do not normalize
unrelated legacy filenames: other documents or code may refer to them.

## Workflow

1. **Find an existing document.** Before creating one, search the root and
   `DONE/`, for example with `rg -l "<keyword>" docs/RESEARCHES`. Update an open
   document for the same problem instead of creating a duplicate. If the problem
   returns after completion, create a new document in the root and link to the
   previous one. Do not reopen a document by moving it out of `DONE/`.
2. **Create the document** in the root without a status prefix.
3. **Maintain it during the work.** Record evidence, decisions, and checks in
   the same file, not only in chat. Keep a `Status:` line near the top, such as
   investigation, plan, implementation, implemented locally, or released in a
   specified version.
4. **Record a separate review only when requested.** The agent that actually
   performs the review records its findings and adds `REVIEWED - ` to the
   filename. The author's own checks do not qualify for this prefix. See
   "Investigation and review" below.
5. **Close completed work in the same task.** The completing agent records what
   changed, checks and results, remaining limitations, and release status. Replace
   any `REVIEWED - ` prefix with `DONE - `, retaining the review record in the
   text, and move the document following "Moving to DONE/" below.

### What counts as complete

- A fix or feature is implemented and the required checks pass. Publication is
  a separate status: record "implemented locally" or "released in X.Y.Z" in the
  document. Publication does not determine the filename or directory.
- A report without implementation, such as a review, verification, incident
  analysis, or release report, is finished, handed off to the user, and has no
  remaining work in its agreed scope.
- Work is cancelled or a plan is superseded. Record
  `Closed without implementation: <reason>` near the top and link to the
  replacement when applicable, then close the document as complete.

Keep documents in the root when a plan awaits implementation or a user decision,
required checks have failed, or review findings still require corrections.

## Moving to DONE/

Moving a document one directory deeper changes both incoming and outgoing
relative links. Every updated navigation link must resolve after the move.

1. **Verify the targets, then move rather than copy.** Confirm that the document
   belongs to the completed task. Give supporting artifacts, such as JSON data,
   diagnostic scripts, or an evidence directory, the same date/time prefix and
   move them with the document. Do not leave a duplicate in the root or overwrite
   an existing destination. If ownership is uncertain, ask before moving it.
2. **Find incoming references.** Search with `rg -l -F "<filename without .md>" .`
   and repeat with spaces encoded as `%20`. Check references to supporting
   artifacts as well.
3. **Update incoming documentation links.** From `docs/*.md`, the path becomes
   `RESEARCHES/DONE/DONE - <timestamp>_<topic>.md`; from another document in the
   research root, use `DONE/DONE - <timestamp>_<topic>.md`. Update plain-text
   repository paths in backticks as well as Markdown links.
4. **Update links inside the moved document.** A repository link such as
   `../../PlayerMac/` becomes `../../../PlayerMac/`; `../runbooks/` becomes
   `../../runbooks/`. A document left in the research root becomes `../X.md`.
   Link to a neighboring document or artifact in `DONE/` without a directory
   prefix.
5. **Preserve code references and historical records.** Do not edit source or
   test comments merely to reflect a documentation move. The original timestamp
   and topic remain searchable. Preserve historical file inventories, review
   logs, and command output because they record the state at that time.
6. **Verify the links.** Check that changed incoming links, outgoing relative
   links, and artifact references resolve to the intended files.

Enclose Markdown link destinations containing spaces in angle brackets:

```markdown
[Investigation](<DONE/DONE - 2026-10-29_15-00_Release-tooling-review.md>)
```

For code references, prefer repository-relative paths in backticks, such as
`PlayerMac/PlayerMac/MPVKit/MPVPlayer.swift`. These remain readable after a move.

## Problems and correction plans

Before fixing a behavioral bug, create a document here or update an existing
open document for the same problem. Record the investigation in the document,
not only in chat. Include at least:

1. Symptoms, expected behavior, and a verifiable reproduction.
2. Confirmed causes, with hypotheses and unverified claims identified separately.
3. Defect class, affected paths, and the files responsible for them.
4. Proposed correction, alternatives, and compatibility or security constraints.
5. Regression before the fix, checks after it, and acceptance criteria.
6. Actual results, remaining limitations, and release status.

The document does not replace tests or require renewed approval when the user
has already authorized implementation. If only a plan was requested, do not edit code.

## Investigation and review

Every agent must finish an investigation with documented evidence and a plan.
Do not automatically launch or attempt to launch an independent review through
Claude, another model, a subagent, or a review runner. A separate review runs only
after an explicit user request. Do not require it to complete an investigation.
The author's own fact and plan checks remain part of the investigation; add the
`REVIEWED - ` prefix only after a separate review actually took place.

An investigation with a plan still awaiting implementation stays in the root.

An explicit request to execute a research document (for example, `Execute
docs/RESEARCHES/<document>.md` or the equivalent request in the user's language)
authorizes both independent plan review and local implementation through
[research-execute](../../.agents/skills/research-execute/SKILL.md). The
orchestrator launches Gemini review followed by Codex implementation, handles
questions, and verifies the result. This exception applies to the requested
document only; it does not authorize publication, release, or a separate
post-implementation code review. Creating a plan or adapting the skill does not
start the pipeline.

## Preservation and privacy

- Do not include secrets, personal data, or private payloads.
- Do not delete documents or rewrite earlier evidence. Preserve failed
  reproduction attempts and record successful retries separately.
- Preserve files and changes belonging to the user or other agents. Do not
  discard or overwrite them when renaming or archiving task documents.
- Archive documents completed in the current task so the root remains a list
  of ongoing work.
