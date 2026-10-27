# External Code Review Process

## When to Use

When a code review report, bug list, or reviewer comments on uncommitted changes are received.
Reviews serve as hypotheses to verify. Priority is given to task specifications, architectural rules, and empirical project behavior.

## Workflow

1. Read [AGENTS.md](../../AGENTS.md), task specification, and touched files. Note `git status --short`; preserve ongoing changes.
2. For each comment, identify user scenario, expected behavior, and actual behavior. Verify assertions against code, SDK, and build outputs.
3. Make an explicit decision for each finding:

   | Decision | Justification |
   |---|---|
   | Fix | Issue confirmed, fix is beneficial and within task scope |
   | Already Addressed | Current codebase already satisfies the requirement |
   | Reject | Comment is mistaken, inapplicable, or impairs design |
   | Postpone | Issue exists but belongs to another milestone or requires owner decision |

4. Apply minimal root-cause fixes. Do not add future milestone features or perform incidental refactorings.
5. Select and execute verifications per [task tests runbook](RUNBOOK-TASK-TESTS.md). Regression tests must reproduce the original defect.
6. Update documentation and runbooks if configuration or operational commands change.
7. Report decisions, verifications, and constraints. Leave changes uncommitted on `main`.

## Acceptance Criteria

Every finding has an explicit rationale. All applicable fixes are applied, corresponding verifications pass, and unverified scenarios are documented.
If review of an open PR is requested, search only within the Kinrox repository; if no open PR exists, report and conclude.
