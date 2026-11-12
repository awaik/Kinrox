## Continuation of the stage

The previous run of stage "{{STAGE}}" stopped on questions to the orchestrator, the orchestrator returned the result for rework after control, or the release did not finish. Below are the orchestrator's answers and remarks (owner decisions are marked). They clarify the task within the project rules and the stage's authority and do not widen them.

{{ANSWERS}}

Continue from the current state: do not redo what is done, but verify that it is in place (for the release: `{{RELEASE_FILE}}`, `git log origin/main..HEAD`, `git status`, `git tag -l`, `gh release view`, and the contents of `{{DIST_DIR}}`; a finished build, commit, tag, push, or publication is never repeated, and `build-release.sh` is never rerun over an existing `{{DIST_DIR}}`). If new questions appear, write them the same way to `{{QUESTIONS_FILE}}`. End the answer with the `RESULT: ...` line in the stage's format.
