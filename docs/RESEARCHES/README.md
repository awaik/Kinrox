# Research notes

Start unfinished filenames with the date and time, followed by a descriptive name.
Use Windows-compatible separators, for example:

`2026-10-29_15-00_Release-tooling-review.md`

After a separate review, the reviewing agent adds the `REVIEWED - ` filename prefix:

`REVIEWED - 2026-10-29_15-00_Release-tooling-review.md`

After implementation is complete, mark the document with the `DONE - ` prefix:

`DONE - 2026-10-29_15-00_Release-tooling-review.md`

## Problems and correction plans

Before fixing a behavioral bug, create a document here or update an existing
document for the same problem. Filename timestamps use `Europe/Moscow`.
Record the investigation in the document, not only in chat. Include at least:

1. Symptoms, expected behavior, and a verifiable reproduction.
2. Confirmed causes, with hypotheses and unverified claims identified separately.
3. Defect class, affected paths, and the files responsible for them.
4. Proposed correction, alternatives, and compatibility or security constraints.
5. Regression before the fix, checks after it, and acceptance criteria.
6. Actual results, remaining limitations, and release status.

The document does not replace tests or require renewed approval when the user
has already authorized implementation. If only a plan was requested, do not edit code.
Every agent must finish an investigation with documented evidence and a plan.
Do not automatically launch or attempt to launch an independent review through
Claude, another model, a subagent, or a review runner. A separate review runs only
after an explicit user request. Do not require it to complete an investigation.
The author's own fact and plan checks remain part of the investigation; add the
`REVIEWED - ` prefix only after a separate review actually took place.
Do not include secrets, personal data, or private payloads. Preserve failed
reproduction attempts and record successful retries separately.
