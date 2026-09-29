# Lint and test rules — the full text

Read before a commit, when a linter or a coverage gate is in your way. `SKILL.md` states the rule; this file is the whole of it, with the reasons and the traps.

## Lint & Test Rules

- **NEVER suppress or skip linters.** Every pre-commit check the project defines — formatters, linters, type checkers, static analysis — must pass cleanly. Do NOT reach for an inline `disable`, `ignore` or `expect-error` directive to silence one. Fix the underlying problem. The only acceptable annotations are structural ones already established in the codebase.
- **Fix ALL lint warnings in modified files** — every warning, regardless of whether it's from your changes or pre-existing. Don't check `git blame` to assign blame; just fix it.
- **A change ships with tests, and a bug fix ships with one that failed first.** Whether you write them before the code is **the project's testing policy** to set; this skill's default is that you do. What does not vary is that the change is tested and that the tests covering it pass.
- **Lint and test the changed files BEFORE committing.** Run every linter, formatter and type checker that applies to the files in the commit, plus the tests covering them — preferring the runner's own dependency-aware selection where it exists. Where the project defines a single canonical gate command for an area, use that rather than assembling the steps yourself. The commands live in the project's own instructions, not here. Do not commit until all pass cleanly.
- **Widen that scope when the change is cross-cutting.** A changed-file gate cannot see a test it has no import-level link to. Editing a base class, shared fixture, factory, migration or config default means running more than the files' own tests, whatever the default gate says.
- **NEVER skip the pre-commit verification gates.** Before EVERY commit, run ALL applicable linters and tests. **If you skip these steps, breakage compounds silently across tickets until someone catches it in bulk — that is unacceptable.** See `ticket-workflow` → Phase 5 for the full per-area gate matrix and commands.
- **Genuine false positives go to the stakeholder, not to a suppression comment.** If a lint warning seems incorrect, discuss it — never silence it silently.
- **Diff coverage is a gate, and the bar is the project's.** Every new/changed line should be exercised by tests; where the project's testing policy sets no other number, that means 100%. A diff-coverage failure means write more tests, not "good enough."
