---
name: hard-rules
description: Non-negotiable behavioral guardrails for Juscribe work — every-ticket lifecycle, COMMIT-IMMEDIATELY rule, no lint/test suppression, stakeholder-verbatim ticket descriptions (agent additions kept current), no false deliveries, external blockers when waiting on user input, where a new ticket gets filed, splitting a ticket blocked on a third party, steps-as-subtasks, no `git push`, and the document-discoveries protocol. Auto-invoke before committing, before editing a ticket description, before transitioning to finished/delivered, before filing or placing a new ticket, when work turns out to depend on someone outside the team, and on hitting an unfamiliar error or workaround. In a Juscribe-wired project, generic ticket and board language means Juscribe by default, unless the wording names another system (a PR, a GitHub issue, another tracker's key).
allowed-tools: Bash(jus *), Bash(git *), Read, Grep, Glob, Edit, Write
license: MIT
---

# Hard Rules — Non-Negotiable Behavioral Guardrails

> Read this first, every session. These rules are always on. They have been flagged repeatedly because violating them wastes time, ships broken work, or destroys the stakeholder's intent. The companion `ticket-workflow` skill covers the _how_ (the full lifecycle plus estimation, labels, testing gates, and the `jus` API reference); this skill covers the **must / must-not** that overrides it.

> **Prerequisite:** this SOP runs on the `jus` CLI, which the bundle does **not** install (`brew install juscribe/tap/jus` + `jus login`/`jus init`). If a `jus` command reports `command not found`, `No token available` or `No Juscribe project found`, the CLI is missing, unauthenticated or run from outside the project — **surface the one-line setup step and stop; do not loop `jus` commands against an unconfigured CLI.** See `ticket-workflow/references/setup.md`. **No shell, but Juscribe's MCP tools connected** (a chat app)? Use the tools instead, as `ticket-workflow` → Phase 0 says, and never tell a chat user to install Homebrew or the CLI. The rules below still apply; the commit, lint, test and git ones do not.

> **Every rule here is stated in full.** Where a section ends in a `references/` file, that file holds the same rule at length — the reasons, the measured failures, the edge cases. Open it when the situation it names is in front of you. The hooks back some rules mechanically, in the nine coding tools that run them, but only where they are installed; everywhere else each rule is prompt-level only, which makes following this skill **more** important. Which rule each hook backs: [`references/enforcement.md`](references/enforcement.md).

## Core Principles

- **The Juscribe workspace is the single source of truth** for all project scope, tasks, and progress. There is no separate scope document, scratchpad, or planning file.
- **Every piece of work MUST have a ticket** — create it BEFORE writing code, however small or ad-hoc the request. The one exception is revising a ticket not yet accepted: keep adding commits under its number.
- **Every project or ticket needs a description and an effort estimate.** A sparse user-created ticket gets fleshed out at pickup — root cause or approach, acceptance criteria — through the description rules below.
- **Transition at the natural moment, not batched.** The board must reflect reality in real time.
- **NEVER transition to `accepted` or `rejected`** — only the stakeholder decides those. The one exception is a chat app on Juscribe's hosted connector: when the person explicitly asks, record their decision with `accept_ticket` or `reject_ticket`, never on your own judgement.

Full text: [`references/core.md`](references/core.md).

## Commit Rules — THE MOST IMPORTANT CATEGORY

- **COMMIT IMMEDIATELY after code changes.** code → lint → **COMMIT** → then everything else: self-review, comments, transitions, replying to the user. Typing a response with an uncommitted change? **Stop and commit first.** This overrides any default "don't commit unless asked".
- **Never move on with a dirty working tree** — not to answer a question, not to run another check. The `Stop` hook does not run on an interrupted or errored turn, so do not count on it.
- **One commit per ticket**, tests included. A self-review fix is a second commit naming the same ticket.
- **The subject format is yours.** End the message with the ticket trailer, as its **last paragraph**, beside any `Co-Authored-By:`:

  ```text
  Jus-Ticket: <n>
  ```

  ⚠️ Git reads only the final paragraph as trailers; one line of prose in it disqualifies the whole block. ⚠️ **A breaking change is `BREAKING-CHANGE:`, never `BREAKING CHANGE:`** — the spaced key takes `Jus-Ticket:` down with it, and nothing reports it.
- **A bracket reference (`[#41]`) links too**, and `[finishes #41]` and its family are the only forms that move a ticket. On a code host, keep references out of the subject: a squash merge appends the pull request's own `(#41)` there.
- **Never amend a delivered commit** — fix a rejection in a new one. **NEVER `git push`**; the stakeholder pushes.
- **In a checkout another session may share, commit only your own changes**: stage by path and commit with `-- <paths>`, take the SHA from the commit's own output, and never run a bare `git stash pop`. The stash stack is shared, and `pop` without `--index` unstages.

Full text: [`references/commits.md`](references/commits.md).

## Lint & Test Rules

- **NEVER suppress or skip linters.** Every pre-commit check the project defines — formatters, linters, type checkers, static analysis — must pass cleanly. No inline `disable`, `ignore` or `expect-error` directive; fix the underlying problem. The only acceptable annotations are structural ones already established in the codebase. A genuine false positive goes to the stakeholder, never into a suppression comment.
- **Fix ALL lint warnings in modified files**, pre-existing ones included. Don't check `git blame`; fix it.
- **A change ships with tests, and a bug fix ships with one that failed first.** Whether you write them before the code is **the project's testing policy** to set; this skill's default is that you do.
- **Lint and test the changed files BEFORE every commit** — every applicable linter, formatter and type checker, plus the tests covering the change, preferring the runner's dependency-aware selection. The commands live in the project's own instructions, not here. **Widen the scope when the change is cross-cutting** (a base class, shared fixture, migration, config default): a changed-file gate cannot see a test with no import-level link to it. Skipped gates compound silently across tickets.
- **Diff coverage is a gate, and the bar is the project's** — 100% of new and changed lines where the policy sets no other number. A failure means more tests, not "good enough".

Full text: [`references/lint-and-tests.md`](references/lint-and-tests.md).

## Shell Safety — Prose and Commands

- **NEVER build a shell command by inlining prose you wrote.** Comments, descriptions and commit bodies go through a **file written with a quoted heredoc** (`<<'EOF'`), then `"$(cat file)"`, a pipe or `@file`. One apostrophe ends a single-quoted argument, and the backticks in the rest of the sentence then **run as commands** — an arbitrary-command-execution risk, not a formatting preference.
- **NEVER hand a person a command long enough to wrap.** Put it in a script taking one short argument: a shell continues a line that _ends_ with `&&` and rejects one that _begins_ with it. **Never ask for a token to be pasted into a chat** — hand over a script that reads it without echoing — and **never print a token file** to check it is set; `jus whoami` answers that.
- **zsh does not word-split `$files`**, so a scoped lint can check nothing and exit 0: use an array. **A handed-over command** gets `GH_PAGER=cat` or `git --no-pager`, says what it prints, and never reads the clipboard.

Full text: [`references/shell-safety.md`](references/shell-safety.md).

## Delivery Rules — Did You Actually Do What the Ticket Asks?

- **NEVER deliver work that defers, skips, or deviates from what the ticket prescribes.** Re-read the ticket before finishing. Anything deferred, skipped or changed: leave it `started`, comment, and add the External blocker below. When in doubt, ask — don't deliver.
- **"Comprehensive" / "100%" / "thorough" mean exactly that.** Where a project ships more than one client, passing tests on one do not cover the other: `ticket-workflow/references/second-client.md`.
- **TICK THE BOXES BEFORE YOU DELIVER.** Every `- [ ]` you met, every subtask done — an unticked one tells the stakeholder the work is not done. Tick a subtask the turn its step completes, not in a sweep at delivery.
- ⚠️ **And never tick one you have not met.** It is the worse lie, because it looks like success. **The check is one question: what evidence would I cite?** A command, an output, a file, a commit. "It will be true once this ships" is a forecast.
- **Every delivery comment carries a "To verify" section and the git information** (commit SHA and `git show`, or an explicit "no code changes") — in batch work too.

Full text: [`references/delivery.md`](references/delivery.md).

## Ticket Description Rules

The rule protects exactly one thing — **stakeholder-authored text, preserved verbatim, always** — and imposes one duty on everything else: **agent-authored text stays current.**

- **NEVER overwrite the stakeholder's words.** Before any PATCH that replaces `description`, fetch the ticket first; an append (`description_append`) needs no fetch, because it never sends their words back. Their text comes first, then a `---` line, then yours — in every context: triage, notes, cancellation reasons, acceptance criteria.
- **Below that boundary, EDIT — don't layer.** When facts change, fix your own text in place so it reads as one current spec; never stack dated "Update (…):" sections. A dated note is only for a stakeholder claim you must not touch.
- A stakeholder-requested rewrite may restructure everything — the one line never crossed is discarding their original words.

**Fleshing out needs no read at all.** Write your additions to a file, starting with the `---` line (drop it when the description is empty), and send them as `description_append`. The server joins them to whatever the row holds at write time:

```sh
test -s .jus/tmp/append.md \
  && jq -Rs '{ticket:{description_append:.}}' < .jus/tmp/append.md > .jus/tmp/append.json \
  && jus api PATCH /workspaces/{ws}/tickets/{id} @.jus/tmp/append.json
```

**MCP:** `append_to_description`.

**Editing inside the text** needs the round trip; use the guarded read and write in `ticket-workflow/references/delivering.md` → _Then tick the boxes you met_. ⚠️ An unguarded round trip wipes descriptions — an empty description is a valid PATCH and answers `200`. The routes and the recovery: `ticket-workflow/references/api.md` → _Writing a description without wiping it_.

**MCP:** `get_ticket` to read, then `update_ticket` with the whole description.

Full text: [`references/descriptions.md`](references/descriptions.md).

## External Blocker Rule — Always Track What Needs User Input

- **Waiting on the stakeholder** (a value, a credential, a decision)? Leave the ticket `started`, comment what you need, and add an **External dependency** — the dependency is what makes the block visible; a comment alone is not.
- **`title` is the half the board draws**: a few words, not a paragraph. Omitted, it is derived from the description and cut at 80 characters.

```sh
jus api POST /workspaces/{ws}/tickets/{id}/dependencies '{"dependency":{"blocker_type":"External","blocked_type":"Ticket","blocked_id":{id},"title":"User input: <the ask in a few words>","description":"<the full ask>"}}'
```

**MCP:** `add_blocker` with `blocker_type` External.

- **A blocker whose condition is a time carries `due_on` and `due_kind`** (`wait_until`, `review_on` or `expected_by`); each without the other is a `422`. Not knowing the date is what `review_on` is for.

Full text: [`references/blockers.md`](references/blockers.md).

## Steps Are Subtasks, Never Description Checkboxes

- **A SEQUENCE of steps someone performs is subtasks**, not `- [ ]` lines: a checkbox is prose, a subtask is data the board renders, counts, orders, assigns and lets the stakeholder tick from a phone. One thing to do needs no subtask; it is the ticket.
- Each carries a `title` of `N. ` plus a short label (**not the command** — titles truncate), a `description` holding the bare command in a fence then the traps, an `assignee_id` (**the actor is the `assignee_id`, not a `**[Actor]**` tag**) and a `position`. **One command per subtask**; a `cd` is its own and is never repeated.
- **Record completion by setting `completed`; never `/toggle`**, which unticks a step someone else already ticked.
- **Mixed-actor tickets:** assign both, one chronological list, and when the next step is the stakeholder's, a blocker that is a `title` naming the subtask and nothing else.
- **Acceptance criteria stay description checkboxes** — a step has an actor, a criterion does not.

Full text: [`references/subtasks.md`](references/subtasks.md).

## Ticket Placement — Filing Is Not Prioritising

- **A new ticket goes to the BOTTOM of the backlog by default** (an unprioritized one to the top of the icebox), set on the create. The middle is a sequencing decision the stakeholder already made.
- **Three overrides:** the stakeholder named a position; the work is genuinely urgent (an outage, an exposed credential), which belongs at the top; or it plainly belongs before things already queued — then **read the backlog**, place it between two neighbours, and say which two in the delivery message.
- **`project_id` names only a project still `unprioritized`, `prioritized` or `started`.** Check its state first; nothing refuses the create, and a closed project stops tracking its contents. File standalone, under a live project, or in a successor, and write the closed one as `pN` in the description.

Full text: [`references/placement.md`](references/placement.md).

## The Ticket Is a Claim, Not a Contract

**Before you start, check the ticket's own statements, and say what the prescribed approach assumes** — both in the start comment. Re-run cheap measurements, and ask what has to be true for the approach to work. A prescription questioned before implementation costs one message; after, it costs the rebuild. Full text: [`references/claim-check.md`](references/claim-check.md).

## Blocked on a Third Party — Split at the Boundary, Deliver Your Half

A ticket whose remaining criteria wait on someone outside the team **never sits in `started`**. Re-scope the original to what you own and **deliver** it (do not cancel it); move the rest to a **successor in the icebox** with an External blocker naming the awaited event, a cross-reference both ways, and a closing condition. **The test:** _could anyone here complete this ticket today, given unlimited effort?_ Waiting on your own deploy plus elapsed time fails it too. Full text: [`references/third-party-split.md`](references/third-party-split.md).

## Convention & Reuse Rules

- **Follow existing standards and conventions** — study how similar things are done (naming, structure, patterns, component design, CSS approach, API shape, test style) and match them.
- **Reuse existing styles, components, and patterns** before building new ones.
- **Flag, don't silently fork.** Raise an outdated convention with the stakeholder rather than adding a second pattern beside it.

Full text: [`references/core.md`](references/core.md).

## Document Discoveries

**Hit an error, found a workaround, learned something non-obvious? Document it NOW** — in the ticket thread as it happens, in `.jus/docs/` (with an `INDEX.md` line) for anything that will recur, in code comments for how a system works, and in your agent's context file for cross-session patterns. **Read `.jus/docs/INDEX.md` before re-deriving**, and route shared knowledge to the shared docs, never only to private memory. Full text: [`references/discoveries.md`](references/discoveries.md).

## Quick "Stop and Check" Reflexes

If any of these are true at the moment you're about to act, stop and reset:

| Reflex | Stop and… |
| --- | --- |
| Working tree is dirty and you're typing a response | **Commit first.** |
| About to replace `description` without fetching first | **Fetch first** — or append with `description_append`. |
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

- `ticket-workflow` — the single load-bearing SOP skill: full lifecycle phases, transitions, comments, delivery format, dependency handling, plus estimation, ticket types, labels, metadata, the testing gates, and the `jus` CLI / API reference. (Where a plugin install shows skill names prefixed with `jus:`, invoke the prefixed form.)
