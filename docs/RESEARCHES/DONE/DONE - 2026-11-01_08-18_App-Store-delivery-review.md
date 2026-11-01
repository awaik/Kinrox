# App Store delivery review

Status: Complete — implemented and validated. iPhone publication remains pending Apple review.

## Scope and evidence

The owner requested an independent assessment of six findings against the
uncommitted App Store delivery workflow, then authorized commit, deployment and
release. The implementation was checked against installed fastlane 2.236.1.
No new Mac application behavior or binary is introduced by this change.

## Findings and corrections

1. Review contact validation ran only during submission, although deliver uploads
   review information during metadata delivery. Both lanes now reject missing or
   whitespace-only contact fields before upload.
2. Unexpected locales, screenshot slots, missing local metadata and absent review
   details could abort verification before its report. These cases now produce
   reported errors; the output directory is created and contact whitespace is
   normalized consistently with deliver. Verify stages its screenshot inputs.
3. Broken staging links raised raw filesystem errors and obsolete images could
   reach deliver. Staging now rejects broken links, extra files and extra locale
   directories while preserving their contents.
4. The build lookup now uses the inspected version. Requiring an already attached
   build was rejected: the documented workflow verifies the processed candidate
   before deliver selects it during submission.
5. Export now generates ignored Xcode projects before gym inspects the workspace.
   The redundant export method overridden by gym was removed.
6. Temporary Apple ID authentication now restores API authentication in an ensure
   block, including login and app-creation failures.

## Verification

- Before production fixes: 20 regression checks failed for the expected causes.
- After fixes: 28 Ruby tests, 149 assertions; all passed, including a complete
  350-screenshot fixture and API-authentication restoration on failure.
- Python script suite: 40 tests passed.
- Ruby syntax, App Store metadata validation, Info.plist validation, website
  generation check (90 pages, 30 languages), and whitespace checks passed.
- Credentials and local fastlane reports remain ignored. Regression tests use
  offline action doubles and isolated temporary fixtures.
- Read-only `fastlane ios status` on November 1, 2026 confirmed iPhone version
  0.1.0 remains `WAITING_FOR_REVIEW`. No App Store metadata, binary or submission
  was changed during this review or publication task. Manual release requires
  Apple's approval.

Implementation: [Fastfile](../../../fastlane/Fastfile),
[store verifier](../../../fastlane/verify_store.rb), and
[delivery instructions](../../../AppStore/README.md).
