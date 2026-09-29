# Phase 5: Self-Review

Read right after each commit: what to review, the checks to run, and the coverage of the diff.

After committing, review your diff (`git show`). Go beyond the diff:

- Naming consistency with surrounding code
- Paradigm fit (does it match existing patterns?)
- DRY opportunities with existing code
- Missed cleanup or dead code
- Refactoring the change exposes
- Performance implications

## Where the commands come from

**This skill does not name them**: it ships to projects with different stacks, and a runner named here would be wrong everywhere else. The obligations below are universal; the invocations live in the project's own instructions — its `CLAUDE.md`, contributor guide or task runner.

If you cannot find them, **ask rather than guess**. A test command invented from the directory layout can pass while running nothing.

## Mandatory post-commit checks

> These checks are the point of self-review. **Do not skip them.**

Run, **scoped to the files in this commit**:

1. **The tests covering what you changed.** Prefer the tooling's own dependency-aware selection where it exists: a runner that follows the import graph finds the tests that exercise your change, not just the ones with matching filenames.
2. **Every linter and formatter that applies to those files**, including any static-analysis or smell tool the project treats as mandatory. Fix every warning in a file you touched, whether or not your change caused it.
3. **Any type checker.** It is usually project-wide — check whether yours can be scoped before assuming it can.

⚠️ **Know what this scope does not prove.** A changed-file gate misses a test with no textual or import link to the change — one reached through a shared callback, fixture, factory or config default. Without dependency-aware selection, "tests for the changed files" is a filename convention and that blind spot is wide.

So **widen the scope yourself when the change is cross-cutting**: a base class, a shared fixture, a migration, a config default, anything imported broadly. If the project runs a full suite somewhere — CI, a pre-push hook, a nightly job — know which, because that is what covers the gap.

- **A reviewer that changes code to test it, such as deleting a guard to see whether the tests notice, must mutate a temporary copy**, never the checkout you are about to commit from. A surviving mutation is exactly what that review produces, so your own gates will not catch one left behind.

Fix issues in a follow-up commit with the same ticket prefix. Only finish once the code would pass a senior review.

## Diff coverage gate

After lints pass, check coverage **of the diff** for every component you touched: that every new or changed line is exercised, not just that the tests pass.

Most projects wrap this in one command; find it rather than assembling one. Two things bite:

- **Coverage instrumentation is usually opt-in.** A plain test run often leaves the old report in place, and the diff check reads it — wrong line numbers and all — and reports success. Confirm the report came from the run you just did.
- **Scoping the test run also scopes the coverage.** The report covers only what the tests you ran exercised. That is the right denominator here, and says nothing about the project as a whole.

**Default threshold: 100%** — every new or changed line — unless the project's testing policy sets another. Where the default applies, a failure means writing the missing tests: do not deliver with uncovered lines.

**Stubborn lines, case by case:** a **reachable** line needs the test that exercises it, edge cases and error branches included, since those break first in production. **Unreachable or dead code** is refactored away, not hidden behind `:nocov:` or `/* istanbul ignore */`. Cover them all in one pass rather than carrying debt across commits.

## A second client surface needs its own pre-delivery check

**Where a project ships more than one client — a mobile app, a CLI, a public API, an embedded widget — code plus passing tests is NOT sufficient.** Work verified against the primary client can ship completely broken on the other. Before delivering a ticket that touches the second client, run the four checks in `references/second-client.md`, and the project's own version of them where it has one.
