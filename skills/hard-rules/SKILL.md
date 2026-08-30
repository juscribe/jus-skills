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

| Rule | Skill (prompt) | Hook (where hooks run) |
| --- | :-: | --- |
| Every piece of work has a ticket | ✅ | — |
| Description and effort estimate required | ✅ | — |
| Transitions at the natural moment | ✅ | — |
| Never transition to `accepted` / `rejected` | ✅ | — |
| **Commit immediately after code changes** | ✅ | `Stop` blocks if working tree is dirty |
| Never move on with a dirty working tree | ✅ | `PostToolUse` nudge after N uncommitted edits |
| One commit per ticket, `[#N]` prefix | ✅ | — |
| Never amend a delivered commit | ✅ | — |
| **Never `git push --force` (any variant)** | ✅ | `PreToolUse Bash` — blocks the command |
| Never `git push` (stakeholder pushes manually) | ✅ | — |
| **Never use `--no-verify`** | ✅ | `PreToolUse Bash` — blocks the command |
| **Never suppress linters inline** (any `disable` / `ignore` / `expect-error` directive) | ✅ | `PreToolUse Edit/Write` — blocks the edit |
| Fix all lint warnings in modified files | ✅ | — |
| **Lint changed files BEFORE committing** | ✅ | `PreToolUse Bash(git commit)` — blocks if no lint ran since last code edit |
| Run the tests covering the changed files before committing | ✅ | Prompt-only. The commit hook runs linters and whatever tests the project wired into it — **it does not run a full suite**. Do not read a passing commit as a passing test run. |
| Diff coverage meets the project's bar (100% by default) | ✅ | — |
| Follow existing standards and conventions | ✅ | — |
| Reuse existing styles, components, patterns | ✅ | — |
| **Never overwrite stakeholder description text (agent text stays current)** | ✅ | — |
| Never deliver work that defers/skips/deviates | ✅ | — |
| Re-read ticket before finishing | ✅ | — |
| Every delivery comment includes verification steps + git | ✅ | — |
| Add an External dependency when waiting on user input | ✅ | — |
| Steps are subtasks, never description checkboxes; mixed-actor tickets assign both | ✅ | — |
| Tick every checkbox and subtask before delivering — and never tick an unmet one | ✅ | — |
| Never inline prose into a shell command; never hand over a wrapping command | ✅ | — |
| Check the ticket's own claims and state what the approach assumes | ✅ | — |
| New tickets to the bottom of the backlog unless urgent or deliberately placed | ✅ | — |
| Blocked on a third party: split at the boundary, deliver your half | ✅ | — |
| Document discoveries immediately | ✅ | — |

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
- **A change ships with tests, and a bug fix ships with one that failed first.** Whether you write them before the code is **the project's testing policy** to set; this skill's default is that you do. What does not vary is that the change is tested and that the tests covering it pass.
- **Lint and test the changed files BEFORE committing.** Run every linter, formatter and type checker that applies to the files in the commit, plus the tests covering them — preferring the runner's own dependency-aware selection where it exists. Where the project defines a single canonical gate command for an area, use that rather than assembling the steps yourself. The commands live in the project's own instructions, not here. Do not commit until all pass cleanly.
- **Widen that scope when the change is cross-cutting.** A changed-file gate cannot see a test it has no import-level link to. Editing a base class, shared fixture, factory, migration or config default means running more than the files' own tests, whatever the default gate says.
- **NEVER skip the pre-commit verification gates.** Before EVERY commit, run ALL applicable linters and tests. **If you skip these steps, breakage compounds silently across tickets until someone catches it in bulk — that is unacceptable.** See `ticket-workflow` → Phase 5 for the full per-area gate matrix and commands.
- **Genuine false positives go to the stakeholder, not to a suppression comment.** If a lint warning seems incorrect, discuss it — never silence it silently.
- **Diff coverage is a gate, and the bar is the project's.** Every new/changed line should be exercised by tests; where the project's testing policy sets no other number, that means 100%. A diff-coverage failure means write more tests, not "good enough."

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
- **"Comprehensive" / "100%" / "thorough" mean exactly that.** No "good enough" exits. And where a project ships **more than one client**, code plus passing tests is not sufficient on its own: work verified entirely against the primary surface can deliver completely broken on the other. See [`ticket-workflow`](#related-skills) → Phase 5, "A second client surface needs its own pre-delivery check".
- **TICK THE BOXES BEFORE YOU DELIVER — state is not decoration.** Any `- [ ]` left in a description, and any untoggled subtask, is a live claim about what has **not** happened yet. Delivering while the acceptance criteria still read unchecked tells the stakeholder the opposite of what the delivery comment says, and the description is what they re-read at acceptance. **Sweep every checkbox and every subtask as the last action before the `finished` transition.**

  Measured: seven delivered tickets carrying **47** unchecked boxes between them — every criterion actually satisfied and documented in the delivery comments, while the descriptions said none of it was done. It reads as seven abandoned tickets.

  ⚠️ **Tick a subtask the turn its step completes, not in a sweep at delivery.** That is the whole point of it being data; a ten-step ticket left untouched for days is the board lying for days.

- ⚠️ **AND THE INVERSE, WHICH BOTH GATES ABOVE PASS BY CONSTRUCTION.** Ticking a criterion you have **not** met is the same lie the other way round, and it is the worse one: an unticked box is visible and gets asked about, while a wrongly ticked one looks exactly like success, so nobody goes back. The sweep finds no unticked box, and the pre-delivery re-read confirms criteria you have already marked satisfied.

  **The check is one question: what evidence would I cite?** A command, a query, an output, a file, a commit. A criterion you cannot answer that for is not met, whatever the diff shows — and "it will be true once this ships" is a forecast, not evidence.

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

## The Ticket Is a Claim, Not a Contract

Every other gate here asks whether you **obeyed** the ticket. None asks whether the ticket is **right** — so a wrong prescription gets implemented faithfully and the process reports success.

**Before you start, check the ticket's own statements, and say what the prescribed approach assumes.** Both go in the start comment. This is a sentence, not a review pass.

- **Stated measurements** — re-run them if they are cheap. A ticket citing a file mode, a rate, or a volume is citing someone's reading from some earlier day.
- **What the prescribed approach depends on being true** — the expensive one. A ticket prescribing "add it as an eighth entry to that file" assumes the file exists at the moment the code runs. If the tool that creates it runs later, the append silently does nothing, and you find out after the spec, the commit and the documentation have all been built against it.

**Raising it early is cheaper than raising it late, and that is the whole point.** Flagging a deviation is not the same as asking — but a prescription questioned **before** implementation costs one message, and the same prescription questioned **after** costs the rebuild. Ask at the moment the doubt forms.

## Ticket Placement — Filing Is Not Prioritising

**A new ticket goes to the BOTTOM of the backlog by default**, whether you filed it yourself or were asked to. Set it on the create rather than reordering afterwards.

The middle of the backlog is a sequencing decision the stakeholder has already made. Dropping a new ticket into it silently claims everything below matters less than something they have not read yet. **An unprioritized ticket goes to the top of the icebox** by the same reasoning.

**It is a default, not an absolute. Three things override it:**

1. **The stakeholder specified a position.** Do what they said.
2. **The work is genuinely urgent** — a live outage, an exposed credential, a security hole being actively reachable, or anything gating work already in flight. Then the top is correct: the window in which it is live is the whole cost.
3. **It is not urgent, but it plainly belongs before things already queued.** This is the common case and the one the two above mishandle. **Filing it at the bottom is not the neutral choice it looks like** — it asserts that everything above it matters more. Reaching for the top is the same error inverted.

   So **read the backlog before choosing**, pick a position between the two neighbours it belongs between, and **say which two in the delivery message**. A middle position chosen without listing the backlog is a guess wearing a number.

## Blocked on a Third Party — Split at the Boundary, Deliver Your Half

⚠️ **A ticket whose remaining acceptance criteria depend on an outside party must never sit in `started`.** Marketplace acceptance, vendor approval, an upstream release, a support ticket, a domain transfer — none of it moves because someone is assigned. `started` claims a person is working on it, which is precisely what hides that the ball is entirely elsewhere.

**This is distinct from the External Blocker Rule above.** That one is for work _you own_ and cannot continue — you stay `started` because you resume the moment the answer arrives. This one is for a ticket whose completion is **not yours to reach**.

⚠️ **"Third party" is this section's title, not its test.** The test is at the end, and reading the title as the test is how the section gets skipped: **waiting on your own deploy plus elapsed time fails it too**, and nothing about that reads as an outside party.

**The procedure, in order:**

1. **Re-scope the original to what you actually own.** Move the dependent criteria out of its acceptance list and say where they went. Do not delete them.
2. **Deliver the original** against that re-scoped list, naming the commit that shipped it. ⚠️ **Do not cancel it** — the work was done, and cancelling erases that.
3. **Create a successor** carrying the moved criteria, in the **icebox**: it cannot be scheduled, so it must not sit in a backlog that implies it can.
4. **Add an External dependency to the successor** naming the awaited event specifically, not "waiting on vendor".
5. **Cross-reference both ways** — the original says where the rest went, the successor says what already shipped and under which commit.
6. **Give the successor a closing condition.** "If they reject, or never answer: close this too, record why, and keep the artefact." A successor with no way to end is the original's problem with a new number.

**The test:** _could anyone here complete this ticket today, given unlimited effort?_ If no, and the reason is someone else's decision or the passage of time, split it. If yes but you need an answer first, that is the External Blocker Rule and you stay `started`.

## Steps Are Subtasks, Never Description Checkboxes

If a ticket tells someone to _do_ things in order — a runbook, a migration sequence, a mixed-actor procedure — those steps are **subtasks on the ticket**, not `- [ ]` lines in the description.

**Why, in one line: a description checkbox is prose, a subtask is data.** The board renders subtasks, counts them, orders them, assigns each to one person, broadcasts each change, and lets the stakeholder tick one off from their phone. A `- [ ]` can do none of that, and only an agent editing the whole description can ever change one — which is exactly backwards when the steps are the stakeholder's to run.

```sh
jus api POST /workspaces/{ws}/tickets/{id}/subtasks '{"subtask":{"title":"2. Approve the certificate","description":"…","assignee_id":1}}'
jus api PATCH /workspaces/{ws}/tickets/{id}/subtasks/{subtask_id} '{"subtask":{"completed":true}}'
```

| Field | Carries |
| --- | --- |
| `title` | `N. ` plus a short imperative label. **Not the command** — see the truncation note below |
| `description` | the fenced command, then the commentary and the trap warnings |
| `assignee_id` | who runs it. This replaces an `**[Actor]**` tag in the text |
| `position` | execution order. Unset it is the end of the list, so create them in order |
| `completed` | whether it has been run. **Set it; never `/toggle`, which flips** |

⚠️ **THE COMMAND GOES IN THE DESCRIPTION, NOT THE TITLE.** The board truncates a subtask's title, so a title long enough to hold a real command is cut off with an ellipsis and cannot be copied. A short label fits; the command belongs in a fence in the description, which both the web and mobile clients render as a code block.

⚠️ **Each fence holds ONLY the bare command — copy-pastable as-is.** No `#` comment on the command line, and never several steps packed into one fence with aligned commentary: copying a step then drags the commentary along. The commentary is still required; it follows the fence in the same description.

⚠️ **The number stays in the title.** Neither surface displays an ordinal, so `N. ` is the only thing that lets anything else — a table, a comment, a delivery note — point at a specific step.

### Mixed-actor tickets: one timeline, both assigned

Some tickets interleave agent work with steps only the stakeholder can perform (signing in to a vendor console, typing a secret, approving a purchase, touching hardware).

- **Assign both.** The ticket's `assignee_ids` includes the stakeholder AND the agent. A mixed ticket assigned only to the agent reads as in-progress while it is actually waiting on a human; assigned only to the stakeholder, it hides the agent's remaining work. (If NO step is agent-executable, assign the stakeholder alone and open the description saying why.)
- **One chronological subtask list**, each with its own `assignee_id`. Do NOT write separate "Stakeholder does: / Agent does:" sections — per-actor sections hide the interleaving. The sequence is the contract, and the first untoggled subtask shows whose move it is.
- **Tick each subtask the turn its step completes**, not in a sweep at delivery. That is the whole point of it being data; a ten-step ticket left untouched for days is the board lying for days.
- **Blocker integration:** whenever the next untoggled subtask is the stakeholder's, the External Blocker Rule above applies — leave the ticket `started`, post a comment naming exactly which step you are waiting on, and add the External dependency. Resolve it and continue when your next step unblocks.

### What stays a description checkbox: acceptance criteria

They are claims about whether the ticket is _done_, not things someone performs, and they are what the stakeholder re-reads at acceptance. Keep them in the description and keep them swept. If you cannot tell which you are writing, ask whether a person could be **assigned** it — a step has an actor, a criterion does not.

## Shell Safety — Prose and Commands

- **NEVER build a shell command by inlining prose you wrote.** Ticket comments, descriptions and commit bodies go through a **file plus a quoted heredoc** (`<<'EOF'`), then get passed as `"$(cat file)"` or piped in. This is not a formatting preference; it is an **arbitrary-command-execution** risk, because agent prose is full of the two characters that break shell quoting.

  Measured: an apostrophe in a possessive (`the hook's`) terminated a single-quoted argument, which left the rest of the sentence unquoted, which meant the **backticks around a command name in the prose were evaluated** — and the command ran. Nothing shipped only because a preflight refused on an unset variable. **One apostrophe ends a single-quoted string**; never assume prose is safe to interpolate.

- **NEVER hand a person a command long enough to wrap.** If it does not fit comfortably on one line, put it in a script that takes one short argument. A wrapped paste is not a cosmetic problem: a shell continues a line that _ends_ with `&&` and rejects one that _begins_ with it, so wrapping alone turns a working chain into a parse error — one that names neither the real cause nor the thing that failed to happen.

  Secret entry is the usual offender. **Never ask for a token to be pasted into a chat**; hand over a one-argument script that reads it without echoing. ⚠️ The hidden-input read is shell-specific and the forms are not interchangeable — check which shell the line will actually run under, since a script runs under its shebang and not the person's login shell.

## Document Discoveries

> When you encounter a gotcha, workaround, error, or non-obvious learning during development — document it IMMEDIATELY, don't wait to be asked. Undocumented learnings are lost learnings.

The triggers are: any time you hit an error, find a workaround, or learn something non-obvious about a tool/system/convention. Treat documentation with the same urgency as committing code.

Where to write it (use all that apply):

- **In ticket comments** — capture troubleshooting steps, errors, and fixes in the ticket thread AS THEY HAPPEN. Don't accumulate; document each problem and its solution as you go.
- **In `.jus/docs/`** — for patterns, errors, and fixes that will recur across tickets. If a relevant doc exists, update it. If not, create a new one and add it to `.jus/docs/INDEX.md`.
- **In code comments** — when you decode how a system works (animation flow, state pattern, WebSocket dance), leave explanatory comments in the source. Focus on "why" and "how the pieces connect", not obvious "what". The code is the best place for institutional knowledge.
- **In your agent's context file** (`CLAUDE.md`, `AGENTS.md`, or your tool's equivalent) — for patterns that span multiple files or sessions and inform future agent behavior.

A discovery missed once is a learning lost; a discovery missed across a session is a recurring failure.

**Read before you re-derive.** The docs directory is only worth writing to if it gets read: before debugging or extending a subsystem, check `.jus/docs/INDEX.md` for a doc whose "when to read" hint matches your task — a documented gotcha you re-derive from scratch is time somebody already spent for you, and that failure has been measured (a deployment trap re-diagnosed from zero fifteen hours after being written up). Projects can automate the reminder: the `jus-docs-nudge.sh` hook surfaces the right doc at ticket pickup (for `label:`/`kw:` rows matching the started ticket's labels or title — the moment the information can still change the plan) and on the first edit under any path mapped in the project's `.jus/docs-nudges.tsv`.

**Route shared-relevance knowledge to the shared docs, not private memory.** Per-user auto-memory is invisible to every other agent and every dispatched/sandboxed session — a gotcha recorded only there converts into a future re-discovery by someone else. Memory is for _personal workflow_; anything another agent could trip over belongs in `.jus/docs/` with an `INDEX.md` line.

## Quick "Stop and Check" Reflexes

If any of these are true at the moment you're about to act, stop and reset:

| Reflex | Stop and… |
| --- | --- |
| Working tree is dirty and you're typing a response | **Commit first.** |
| About to PATCH `description` without fetching first | **Fetch first.** Append, don't overwrite. |
| About to silence a lint warning with a suppression comment | **Fix the smell or escalate to the stakeholder.** |
| About to mark `finished`/`delivered` with a deferred or skipped item | **Leave in `started`** + comment + External blocker. |
| About to ask the user a blocking question without an External dependency | **Create the dependency** before asking. |
| About to `git push` | **Don't.** The stakeholder pushes. |
| About to write code without a ticket | **Create the ticket first.** |
| About to edit a source file on a `started` ticket, no start comment yet | **Post the start comment first** (root cause + plan + test intent). |
| About to transition to `accepted` or `rejected` | **Don't.** Only the stakeholder owns those transitions. |
| Hit an error or learned something non-obvious | **Document it now** (ticket comment + docs/code as applicable). |
| About to write "Stakeholder does: / Agent does:" sections in a description | **Rewrite as ONE numbered subtask list in execution order**, each with its own `assignee_id`, and assign both parties on the ticket. |

## Related Skills

- `ticket-workflow` — the single load-bearing SOP skill: full lifecycle phases, transitions, comments, delivery format, dependency handling, plus estimation, ticket types, labels, metadata, the testing gates, and the `jus` CLI / API reference. (Claude Code plugin installs show skill names prefixed with `jus:` — invoke the prefixed form there.)
