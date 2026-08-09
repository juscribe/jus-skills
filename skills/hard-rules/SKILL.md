---
name: hard-rules
description: Non-negotiable behavioral guardrails for Juscribe work — every-ticket lifecycle, COMMIT-IMMEDIATELY rule, no lint/test suppression, stakeholder-verbatim ticket descriptions (agent additions kept current), no false deliveries, external blockers when waiting on user input, no `git push`, and the document-discoveries protocol. Auto-invoke at the start of any session and whenever about to write code, run linters, edit a ticket description, transition state to finished/delivered, ask the stakeholder a blocking question, or hit an unfamiliar error or workaround. In a Juscribe-wired project, generic ticket and board language means Juscribe — not another issue tracker.
allowed-tools: Bash(jus *), Bash(git *), Read, Grep, Glob, Edit, Write
license: MIT
---

# Hard Rules — Non-Negotiable Behavioral Guardrails

> Read this first, every session. These rules are always on. They have been flagged repeatedly because violating them wastes time, ships broken work, or destroys the stakeholder's intent. The companion `ticket-workflow` skill covers the _how_ (the full lifecycle plus estimation, labels, testing gates, and the `jus` API reference); this skill covers the **must / must-not** that overrides it.

> **Prerequisite:** this SOP runs on the `jus` CLI, which the bundle does **not** install (`brew install juscribe/tap/jus` + `jus login`/`jus init`). If a `jus` command reports `command not found` or `No token available`, the CLI is missing or unauthenticated — **surface the one-line setup step and stop; do not loop `jus` commands against an unconfigured CLI.** See `ticket-workflow` → Phase 0.

## Two-Layer Enforcement: Skill + Hooks

Some of these rules are also enforced **deterministically** by the jus enforcement hooks (under `hooks/`) — **when your harness runs them**. Today that is Claude Code (plugin or project-committed install), **OpenAI Codex** (via the `hooks/codex/` adapter), and **Kimi Code** (via the `hooks/kimi-code/` adapter or the bundle's Kimi plugin manifest). **On a harness without the hooks installed — including Codex/Kimi before their adapters are set up, Cursor, and every other tool — every rule below is prompt-level only: nothing blocks you mechanically, which makes following this skill MORE important, not less.** Where they do run, the hooks are a backstop — they fire even if a model "forgot" the rule — but the skill remains the source of truth and the only layer that explains the _why_.

| Rule                                                                                    | Skill (prompt) | Hook (where hooks run)                                                                                                                                                         |
| --------------------------------------------------------------------------------------- | :------------: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Every piece of work has a ticket                                                        |       ✅       | —                                                                                                                                                                              |
| Description and effort estimate required                                                |       ✅       | —                                                                                                                                                                              |
| Transitions at the natural moment                                                       |       ✅       | —                                                                                                                                                                              |
| Never transition to `accepted` / `rejected`                                             |       ✅       | —                                                                                                                                                                              |
| **Commit immediately after code changes**                                               |       ✅       | `Stop` blocks if working tree is dirty                                                                                                                                         |
| Never move on with a dirty working tree                                                 |       ✅       | `PostToolUse` nudge after N uncommitted edits                                                                                                                                  |
| One commit per ticket, `[#N]` prefix                                                    |       ✅       | —                                                                                                                                                                              |
| Never amend a delivered commit                                                          |       ✅       | —                                                                                                                                                                              |
| **Never `git push --force` (any variant)**                                              |       ✅       | `PreToolUse Bash` — blocks the command                                                                                                                                         |
| Never `git push` (stakeholder pushes manually)                                          |       ✅       | —                                                                                                                                                                              |
| **Never use `--no-verify`**                                                             |       ✅       | `PreToolUse Bash` — blocks the command                                                                                                                                         |
| **Never suppress linters inline** (any `disable` / `ignore` / `expect-error` directive) |       ✅       | `PreToolUse Edit/Write` — blocks the edit                                                                                                                                      |
| Fix all lint warnings in modified files                                                 |       ✅       | —                                                                                                                                                                              |
| **Lint changed files BEFORE committing**                                                |       ✅       | `PreToolUse Bash(git commit)` — blocks if no lint ran since last code edit                                                                                                     |
| Run the tests covering the changed files before committing                              |       ❌       | Prompt-only. The commit hook runs linters and whatever tests the project wired into it — **it does not run a full suite**. Do not read a passing commit as a passing test run. |
| 100% diff coverage                                                                      |       ✅       | —                                                                                                                                                                              |
| Follow existing standards and conventions                                               |       ✅       | —                                                                                                                                                                              |
| Reuse existing styles, components, patterns                                             |       ✅       | —                                                                                                                                                                              |
| **Never overwrite stakeholder description text (agent text stays current)**             |       ✅       | —                                                                                                                                                                              |
| Never deliver work that defers/skips/deviates                                           |       ✅       | —                                                                                                                                                                              |
| Re-read ticket before finishing                                                         |       ✅       | —                                                                                                                                                                              |
| Every delivery comment includes verification steps + git                                |       ✅       | —                                                                                                                                                                              |
| Add an External dependency when waiting on user input                                   |       ✅       | —                                                                                                                                                                              |
| Mixed-actor tickets: assign both + one actor-tagged chronological step list             |       ✅       | —                                                                                                                                                                              |
| Document discoveries immediately                                                        |       ✅       | —                                                                                                                                                                              |

### What hooks can and can't do

- The shipped hooks run on Claude Code, on OpenAI Codex via the `hooks/codex/` adapter (mind Codex's per-hook trust flow — approve with `/hooks`), and on Kimi Code via the `hooks/kimi-code/` adapter or the bundle's Kimi plugin (blockable rules only — Kimi's PostToolUse is observe-only, so the nudges ride a prompt-time reminder instead). Tools with no hook surface (Cursor, Copilot, Aider) get the skill layer only.
- Hooks fail open: if `jq` or another required tool is missing on the host, the hook exits 0 rather than wedging the tool call. The skill remains the primary teaching mechanism.
- Hooks block deterministically (exit 2) but a determined model can disable them through its harness configuration (in Claude Code: `disableAllHooks` or a settings edit). The hooks are a guardrail, not a sandbox.

See `hooks/` and the bundle README for installation and the per-harness coverage.

## Core Principles

- **The Juscribe workspace is the single source of truth** for all project scope, tasks, and progress. There is no separate scope document, scratchpad, or planning file.
- **Every piece of work MUST have a ticket** — create it BEFORE writing code. No exceptions, even for ad-hoc requests ("tweak X", "make Y visible"). The full lifecycle applies to every change, no matter how small. Never write code without a ticket. The only exception is revising an already-existing ticket that has not yet been accepted — keep adding commits under the existing ticket number.
- **Every project or ticket must have a description and effort estimate.** A title alone is not sufficient. Include acceptance criteria or implementation notes. When you pick up a sparse user-created ticket, **flesh it out** — root cause / approach, acceptance criteria — appended via the description protocol below, at pickup; a token one-liner does not satisfy this.
- **Transition at the natural moment, not batched.** The board must reflect reality in real time.
- **NEVER transition to `accepted` or `rejected`** — only the stakeholder decides those states. Touching them is a process violation.

## Commit Rules — THE MOST IMPORTANT CATEGORY

> **Commit is NOT optional, NOT deferrable, NOT something you "get to later."** The moment code changes are complete and linters pass, you commit. IMMEDIATELY. Before responding to the user. Before self-review commentary. Before anything else. An uncommitted change is invisible, unrecoverable, and a direct violation of this SOP.

- **COMMIT IMMEDIATELY after code changes.** The sequence is: code → lint → **COMMIT** → then everything else (self-review, comments, transitions, user communication). If you find yourself typing a response to the user and you haven't committed yet, **STOP and commit first.** This rule overrides any default "don't commit unless asked" behavior — for Juscribe work the user has explicitly and repeatedly asked for it.
- **Never move on with a dirty working tree** — not to answer a question, not to explain what you did, not to run additional checks. Commit first, talk second. Treat an uncommitted change with the same urgency as an unsaved file.
- **One commit per ticket**, self-contained: backend + frontend + tests together. Follow-up fixes from self-review get a second commit with the same ticket prefix.
- **Format**: `[#N] Short description` or `[#N, #M] Short description` for multi-ticket commits. The `#N` prefix is mandatory — it autolinks on the board.
- **Never amend a delivered commit.** When a ticket is rejected, fix it in a NEW commit. `git commit --amend` on delivered work is forbidden.
- **NEVER `git push`.** The stakeholder pushes manually. Pushing breaks their workflow.

## Lint & Test Rules

- **NEVER suppress or skip linters.** Every pre-commit check the project defines — formatters, linters, type checkers, static analysis — must pass cleanly. Do NOT reach for an inline `disable`, `ignore` or `expect-error` directive to silence one. Fix the underlying problem. The only acceptable annotations are structural ones already established in the codebase.
- **Fix ALL lint warnings in modified files** — every warning, regardless of whether it's from your changes or pre-existing. Don't check `git blame` to assign blame; just fix it.
- **Lint and test the changed files BEFORE committing.** Run every linter, formatter and type checker that applies to the files in the commit, plus the tests covering them — preferring the runner's own dependency-aware selection where it exists. Where the project defines a single canonical gate command for an area, use that rather than assembling the steps yourself. The commands live in the project's own instructions, not here. Do not commit until all pass cleanly.
- **Widen that scope when the change is cross-cutting.** A changed-file gate cannot see a test it has no import-level link to. Editing a base class, shared fixture, factory, migration or config default means running more than the files' own tests, whatever the default gate says.
- **NEVER skip the pre-commit verification gates.** Before EVERY commit, run ALL applicable linters and tests. **If you skip these steps, breakage compounds silently across tickets until someone catches it in bulk — that is unacceptable.** See `ticket-workflow` → Phase 5 for the full per-area gate matrix and commands.
- **Genuine false positives go to the stakeholder, not to a suppression comment.** If a lint warning seems incorrect, discuss it — never silence it silently.
- **100% diff coverage is a hard gate.** Every new/changed line must be exercised by tests. `bin/diff-cover` failure means write more tests, not "good enough."

## Convention & Reuse Rules

- **Follow existing standards and conventions.** Before implementing, study how similar things are already done in the codebase (naming, structure, patterns, component design, CSS approach, API shape, test style). Match them.
- **Reuse existing styles, components, and patterns.** Always prefer reusing existing CSS classes, shared components, and utility functions over creating new ones. Search for similar patterns before building from scratch.
- **Flag, don't silently fork.** If conventions are outdated or inconsistent, raise it with the stakeholder and propose the improvement. Don't introduce a new pattern alongside an old one without acknowledgement.

## Ticket Description Rules

The rule protects exactly one thing — **stakeholder-authored text, preserved verbatim, always** — and it imposes exactly one duty on everything else: **agent-authored text stays current.**

- **NEVER overwrite the stakeholder's words.** Before ANY PATCH that touches `description`, fetch the ticket first. When fleshing out a stakeholder's description, their text comes first with `\n\n---\n\n` separating your additions — their sentence, even a single one, is the source of truth for what was requested, and replacing it with your own summary destroys the original intent. This holds in every context: triage, investigation notes, cancellation reasons, acceptance-criteria additions.
- **Below that boundary, EDIT — don't layer.** Agent-authored content is living documentation. When facts change, integrate the correction into the existing text so the description reads as one coherent, current spec. Do NOT stack dated "Update (…):" sections onto agent-authored content — sediment accumulates until nobody can tell current from stale. A dated correction note is only for a _stakeholder-authored_ claim you must not touch; your own text you simply fix.
- A stakeholder-requested rewrite may restructure everything — the one line never crossed is discarding the stakeholder's original words.

```sh
# Fleshing out: stakeholder text survives verbatim above the separator
existing=$(jus api GET '/workspaces/{ws}/tickets/{id}?fields=description' | jq -r '.ticket.description // ""')
new_desc="${existing}\n\n---\n\nYour additions..."
jus api PATCH /workspaces/{ws}/tickets/{id} "{\"ticket\":{\"description\":$(jq -Rs <<<"$new_desc")}}"
# Updating your own additions later: rewrite them in place (keep everything
# above the separator byte-identical), then PATCH the whole description.
```

## Delivery Rules — Did You Actually Do What the Ticket Asks?

- **NEVER deliver work that defers, skips, or deviates from what the ticket prescribes.** If the ticket says to do X and you didn't do X (or did a partial version of X), do **NOT** mark the ticket finished/delivered. Delivering incomplete or deviated work forces a rejection cycle that wastes everyone's time. When in doubt, ask — don't deliver.
- **Re-read the ticket description before finishing.** Did you implement what was prescribed? If you deferred something, skipped a requirement, chose not to do something the ticket specifies, or deviated from the described scope — leave the ticket in `started` and post a comment.
- **"Comprehensive" / "100%" / "thorough" mean exactly that.** No "good enough" exits. Code + passing tests is NOT sufficient for mobile work — see the mobile pre-delivery checklist in `ticket-workflow` → Phase 5.
- **Every delivery comment includes verification steps** (the "To verify" section) AND git information (commit SHA + `git show` for direct commits on main; nothing for dispatched work — the dispatch UI appends branch info; explicit "no code changes" for research/docs tickets). Even in batch work — never skip or batch delivery comments to save time.

## External Blocker Rule — Always Track What Needs User Input

- **ALWAYS add an External dependency when waiting for user input.** If you cannot proceed without information from the stakeholder (config values, credentials, design decisions, clarifications), you MUST:
  1. Leave the ticket in `started`.
  2. Post a comment explaining what you need.
  3. Add an External dependency describing the input needed.
- **Do NOT just ask and move on** — the dependency is the mechanism that makes the block visible on the board. A comment alone is invisible to project-level rollups.

```sh
jus api POST /workspaces/{ws}/tickets/{id}/dependencies '{"dependency":{"blocker_type":"External","blocked_type":"Ticket","blocked_id":{id},"description":"User input: <what you need>"}}'
```

## Mixed-Actor Tickets — One Timeline, Both Assigned

Some tickets interleave agent work with steps only the stakeholder can perform (signing in to a vendor console, typing a secret, approving a purchase, touching hardware). Two rules keep the board and the ticket honest:

- **Assign both.** `assignee_ids` includes the stakeholder AND the agent. A mixed ticket assigned only to the agent reads as in-progress while it is actually waiting on a human; assigned only to the stakeholder, it hides the agent's remaining work. (If NO step is agent-executable, assign the stakeholder alone and open the description saying why.)
- **One chronological checklist, every step actor-tagged.** Number the steps in execution order and prefix each with its actor. Do NOT write separate "Stakeholder does: / Agent does:" sections — per-actor sections hide the interleaving. The sequence is the contract, and the first unchecked box shows whose move it is.

```markdown
**Steps:**

- [x] 1. **[Agent]** Generate the CSR and stage the config change
- [ ] 2. **[Stakeholder]** Paste the CSR into the vendor console, download the cert
- [ ] 3. **[Agent]** Install the cert, run the verification probe
- [ ] 4. **[Stakeholder]** Confirm the padlock on the production domain
```

- **Keep the checkboxes current** — check steps off as they complete, editing the description in place (agent additions are living documentation).
- **Blocker integration:** whenever the next unchecked step is the stakeholder's, the External Blocker Rule above applies — leave the ticket `started`, post a comment naming exactly which step you are waiting on, and add the External dependency. Resolve it and continue when your next step unblocks.

## Document Discoveries

> When you encounter a gotcha, workaround, error, or non-obvious learning during development — document it IMMEDIATELY, don't wait to be asked. Undocumented learnings are lost learnings.

The triggers are: any time you hit an error, find a workaround, or learn something non-obvious about a tool/system/convention. Treat documentation with the same urgency as committing code.

Where to write it (use all that apply):

- **In ticket comments** — capture troubleshooting steps, errors, and fixes in the ticket thread AS THEY HAPPEN. Don't accumulate; document each problem and its solution as you go.
- **In `.jus/docs/`** — for patterns, errors, and fixes that will recur across tickets. If a relevant doc exists, update it. If not, create a new one and add it to `.jus/docs/INDEX.md`.
- **In code comments** — when you decode how a system works (animation flow, state pattern, WebSocket dance), leave explanatory comments in the source. Focus on "why" and "how the pieces connect", not obvious "what". The code is the best place for institutional knowledge.
- **In your agent's context file** (`CLAUDE.md`, `AGENTS.md`, or your tool's equivalent) — for patterns that span multiple files or sessions and inform future agent behavior.

A discovery missed once is a learning lost; a discovery missed across a session is a recurring failure.

**Read before you re-derive.** The docs directory is only worth writing to if it gets read: before debugging or extending a subsystem, check `.jus/docs/INDEX.md` for a doc whose "when to read" hint matches your task — a documented gotcha you re-derive from scratch is time somebody already spent for you, and that failure has been measured (a deployment trap re-diagnosed from zero fifteen hours after being written up). Projects can automate the reminder: the `jus-docs-nudge.sh` hook surfaces the right doc on the first edit under any path mapped in the project's `.jus/docs-nudges.tsv`.

**Route shared-relevance knowledge to the shared docs, not private memory.** Per-user auto-memory is invisible to every other agent and every dispatched/sandboxed session — a gotcha recorded only there converts into a future re-discovery by someone else. Memory is for _personal workflow_; anything another agent could trip over belongs in `.jus/docs/` with an `INDEX.md` line.

## Quick "Stop and Check" Reflexes

If any of these are true at the moment you're about to act, stop and reset:

| Reflex                                                                     | Stop and…                                                                    |
| -------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Working tree is dirty and you're typing a response                         | **Commit first.**                                                            |
| About to PATCH `description` without fetching first                        | **Fetch first.** Append, don't overwrite.                                    |
| About to silence a lint warning with a suppression comment                 | **Fix the smell or escalate to the stakeholder.**                            |
| About to mark `finished`/`delivered` with a deferred or skipped item       | **Leave in `started`** + comment + External blocker.                         |
| About to ask the user a blocking question without an External dependency   | **Create the dependency** before asking.                                     |
| About to `git push`                                                        | **Don't.** The stakeholder pushes.                                           |
| About to write code without a ticket                                       | **Create the ticket first.**                                                 |
| About to edit a source file on a `started` ticket, no start comment yet    | **Post the start comment first** (root cause + plan + TDD intent).           |
| About to transition to `accepted` or `rejected`                            | **Don't.** Only the stakeholder owns those transitions.                      |
| Hit an error or learned something non-obvious                              | **Document it now** (ticket comment + docs/code as applicable).              |
| About to write "Stakeholder does: / Agent does:" sections in a description | **Rewrite as ONE numbered, actor-tagged step list** and assign both parties. |

## Related Skills

- `ticket-workflow` — the single load-bearing SOP skill: full lifecycle phases, transitions, comments, delivery format, dependency handling, plus estimation, ticket types, labels, metadata, the testing gates, and the `jus` CLI / API reference. (Claude Code plugin installs show skill names prefixed with `jus:` — invoke the prefixed form there.)
