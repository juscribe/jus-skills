---
name: ticket-workflow
description: The single load-bearing Juscribe SOP skill — the full ticket lifecycle from pickup to delivery, plus estimation, ticket types, labels, metadata, testing gates, and the complete `jus` CLI / API reference in bundled files this skill points at. Use when working any ticket — picking one up, transitioning state, investigating, sizing, labeling, writing tests, running pre-commit gates, calling `jus api`, committing, self-reviewing, finishing, delivering, handling rejections, processing batches, or resolving dependency blockers. Auto-invoke whenever a ticket ID (`#N`) or "work on this ticket" / "pick up backlog" / "deliver" / "rejected" appears. In a project wired to Juscribe (a `.jus/` directory or the `jus` CLI), bare ticket language — `#123`, the board, the backlog, deliver — always means Juscribe tickets, so this skill is the one to invoke for them, never a skill for any other issue tracker.
allowed-tools: Bash(jus *), Bash(git *), Bash(make *), Bash(cd *), Read, Grep, Glob, Edit, Write
license: MIT
---

# Ticket Workflow — Juscribe Lifecycle SOP

> **This skill and `.jus/SOP.md` overlap deliberately.** `jus init` appends that file to your AI context so a project with no plugin still has an SOP. This skill covers the same lifecycle in more depth and is kept more current: where the two differ, this one wins.
>
> Read it when working any ticket. It is the **single load-bearing skill** for Juscribe work. This file is the lifecycle and the batch rules; the operational detail — the `jus` API, estimation, types, dependencies, subtasks, delivery, conversion — sits in reference files that cost nothing until you open one. The companion [`hard-rules`](#related-skills) skill carries the must/must-not. Harnesses that run the jus hooks (Claude Code, with Codex and Kimi adapters) enforce the worst of those deterministically; everywhere else they are prompt-level only.

The lifecycle, in one line:

```
(1) create or pick up → (2) start → (3) investigate → (3b) apply labels → (4) code → (5) commit → (6) self-review → (7) finish
```

**Finishing is your last transition.** Deliver only when a person asks for it; Phase 6 says why.

Every change goes through every phase, however small or ad-hoc. Transition at the natural moment, never in a batch, so the board shows reality. **NEVER transition to `accepted` or `rejected`** — only the stakeholder decides.

## Reference files — read the one you need, when you need it

None of these loads until you open it. Each row says what the file prevents, which is how to tell whether you need it:

| Read | Before |
| --- | --- |
| [references/api.md](references/api.md) | Constructing **any** `jus api` call. A wrong request shape hangs, no-ops or returns a bare 500 rather than an error, and the response envelope is not the JSON root. |
| [references/api-writes.md](references/api-writes.md) | Creating a ticket anywhere but the bottom of the icebox, or changing many at once. Placement belongs in the create, and a bulk call reports failure per item. |
| [references/api-queries.md](references/api-queries.md) | Listing or filtering tickets. The index refuses a filter name it does not know, and leaves markers out unless asked. |
| [references/estimation-and-types.md](references/estimation-and-types.md) | Sizing, typing or labelling a ticket, or filling in a sparse one. Also the pre-start metadata gate and the placement rules for a new ticket. |
| [references/dependencies.md](references/dependencies.md) | Recording that a ticket is blocked. One blocker per independently-clearing condition, and editing one means setting **both** `title` and `description`. |
| [references/delivering.md](references/delivering.md) | Finishing or delivering anything — the pre-delivery gate, the mandatory "To verify" steps, the transitions, and project completion. |
| [references/subtasks.md](references/subtasks.md) | Writing steps someone performs. Steps are subtasks, never description checkboxes, and `completed` is not `/toggle`. |
| [references/converting.md](references/converting.md) | Converting a ticket to a project, or wondering whether a retype is what you actually want. Only a `research` ticket can be converted. |
| [references/formatting.md](references/formatting.md) | Putting a fence inside a list, or reading the reactions on a comment. The fence trap looks correct in the source. |
| [references/second-client.md](references/second-client.md) | Delivering a ticket that touches a second client — a mobile app, a CLI, a public API. Passing tests do not cover it. |
| [references/setup.md](references/setup.md) | A `jus` command failing before it reaches the board, or skills that seem not to have loaded. Each failure has a different fix. |

⚠️ **A pointer is not the content.** About to write a `jus api` call, a dependency, a subtask or a delivery comment? Open the file. Answering from this table is how a wrong request shape ships.

## Phase 0: Prerequisites — the `jus` CLI must be installed and authenticated

This SOP drives the board through the **`jus` CLI**, which the bundle does not install: the user needs `brew install juscribe/tap/jus`, then `jus login` or `jus init` (which also sets the `{ws}` used throughout this skill). **When a `jus` command fails before it reaches the board, open [references/setup.md](references/setup.md).** A missing CLI, a missing token, a retired token and an unreachable server each have a different fix, and only one of them is a rotation. `jus doctor` checks that these skills loaded, which `jus whoami` cannot.

**Do not loop `jus` commands against an unconfigured CLI, or against a 401.** Surface the one setup step the error points to, and stop.

## Phase 1: Session Start

Orient with the agent state endpoint — never fetch full ticket lists at session start.

```sh
jus api GET '/workspaces/{ws}/agent_state?panels=current,backlog'
```

It returns compact markdown (~2–4KB): projects, velocity, users and one line per ticket, cached for 5 minutes. Decide what to work on from it, then fetch individual tickets.

## Phase 2: Ticket Pickup

### Fetch the ticket with comments AND attachments

```sh
jus api GET '/workspaces/{ws}/tickets/{id}?include_comments=true&include_attachments=true&include_label_objects=false'
```

**MUST include comments and attachments.** Comments carry the stakeholder's context, open questions and decisions; attachments carry rejection screenshots and design mocks. If `comments_count` is `0`, drop `include_comments=true`.

If the response shows `blocked: true` or `active_dependencies_count > 0`, fetch the dependencies and apply the [Dependency Handling Protocol](references/dependencies.md).

### Pre-start gate (hard checklist)

Before transitioning to `started`, verify:

- `description` is non-null
- `points` is set
- `stakeholder_id` is set

If any are missing, PATCH them first. Never start a ticket that fails this gate.

**The point scale, the ticket types and the metadata defaults are in [references/estimation-and-types.md](references/estimation-and-types.md)** — open it before putting a number or a type on anything. A guessed type is a `422`; a guessed point value silently distorts the board's velocity.

### Name a branch `<ticket-id>-<slug>` whenever you cut one

⚠️ **The commit linker depends on it.** It reads a ticket id only from the start of the branch's LAST path segment, followed by a dash. `3705-copy-a-branch-name` links its commits and its pull request with nothing typed anywhere; `copy-a-branch-name-3705` links nothing. A prefix is fine: `feat/3705-copy-a-branch-name`.

**Where the work lands is the project's call** — whether to branch, merge or push. Absent instructions, commit where you are and **do not push**: an unrequested push cannot be taken back.

⚠️ **A hook refuses a force-push and a `--no-verify`** on harnesses that run the jus hooks. It is silent where it cannot establish the rule, so its silence is not permission.

### Fleshing out a sparse user-created ticket

A bare title or a one-line description does not pass the gate above. **Flesh the ticket out with substance the stakeholder can react to:**

- **What to add:** your read of the problem (root cause for bugs, approach for features), **acceptance criteria**, and any implementation or test notes. Format it per [Formatting](#formatting-descriptions-and-comments).
- **When:** at pickup, as part of the pre-start gate. Add what investigation finds as you learn it.
- **How:** fetch first. If `description` is non-null, the stakeholder's text stays first and verbatim, then `\n\n---\n\n`, then yours — see [Description conventions](#description-conventions).

A title-only ticket has no acceptance criteria to deliver against and no basis for its estimate.

### CRITICAL: Transition to `started` BEFORE investigating

The moment you decide to work the ticket, transition it and assign yourself, **before** reading any source file. It is the concurrency lock that tells other sessions the ticket is taken.

```sh
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"started"}'
jus api PATCH /workspaces/{ws}/tickets/{id} '{"ticket":{"assignee_ids":[{your_user_id}]}}'
```

Sequence: fetch → start → assign → THEN investigate. **NEVER reverse this order.** Where the jus hooks run, a `UserPromptSubmit` hook fetches the ticket and prints the transition command, but writes nothing: the lock is still yours to take.

### ⚠️ Do NOT put a 👀 on a ticket

**The eyes reaction is not part of the lifecycle.** The hooks that once added and removed it were retired because the reaction went stale in every direction; do not add it by hand. **`started` plus an assignee is the concurrency lock** — it is what the conflict rule below keys on. Your reaction on a **comment** is a different mechanism and is unaffected.

### Concurrency conflict

If the transition to `started` fails, check the assignees. If another agent has claimed the ticket, **stop**, tell the user it appears taken, and ask how to proceed.

### Rejection workflow

A rejected ticket goes `rejected → started → fix → finish`. **NEVER** `git commit --amend` on delivered work — create a new commit.

- **When the user says "rejected", the transition has already happened in the app.** Do not call the reject transition; transition `rejected → started` and fix.
- **Always fetch attachments on a rejected ticket** — the stakeholder may have attached screenshots of the problem. `jus download <url-path> .jus/tmp/<filename>` saves one to view.

## Phase 3: Investigation & Labels

After starting, investigate the codebase. Then apply 1–3 labels before writing code.

### Investigation guidelines

- **Match the exploration to the ticket.** A small, well-understood change wants a couple of direct file reads, not a fan-out of exploration agents. Calibrate "small" to your own codebase.
- **Skip deep architecture analysis for familiar domains** — for routine UI or styling work, read the target files and one or two neighbours. Trace the full state-management chain only when the fix requires it.
- **Time-box investigation to ~3 minutes** for tickets ≤ 2 points. Still reading code after 3 files? Start implementing and adjust as you go.
- **Document what you learn in code comments** — when you decode an animation flow, a state pattern or a WebSocket dance, explain in the source _why_ and how the pieces connect, not the obvious _what_.

### Label conventions

Labels describe **technical areas** — the layers your change touches — not project themes or business intent, which the project grouping already carries.

```sh
jus api PATCH /workspaces/{ws}/tickets/{id} '{"ticket":{"label_ids":[1,2]}}'
```

Guidelines:

- **1–3 labels per ticket** (most are 1–2). More than 3 means the ticket is too large, or the labels repeat what the project already says.
- **Don't duplicate the project grouping.** In a "Mobile redesign" project every ticket already implies `mobile`.
- `docs` — documentation-only tickets. Not for a code ticket that also touches a comment or README.
- `refactor` — restructuring without behavior change. Combine it with `frontend`/`backend` only when the refactor genuinely spans both.
- `regression` — a fix restoring behavior that previously worked. Apply it alongside the area label (e.g. `regression` + `frontend`).

#### Finding this workspace's labels

**Label IDs are per-workspace and are not listed here.** Fetch your project's own:

```sh
jus api GET '/workspaces/{ws}/labels'
```

**The project should document what each label MEANS**, not just its id, in its own instructions. A label with no _when to apply_ is applied by guesswork, and the cost lands on whoever later filters by it.

**If you need a label that doesn't exist, ask the stakeholder before inventing one.** Labels are a controlled vocabulary, and a near-duplicate is worse than a missing one because it silently splits every future filter.

## Phase 4: Coding

### Post the start comment BEFORE the first code edit

**Before you edit a single source file, post a "Starting" comment** on the ticket: your read of the problem (the root cause, for a bug), the plan, and how you will test it. It is the stakeholder's first sign that work began, and the record of your plan before implementation. Nothing hard-blocks skipping it — where the jus hooks run, a soft nudge fires on the first source edit — so it rests on you. Do not skip it, and do not fold it into the delivery comment.

```sh
jus api POST /workspaces/{ws}/tickets/{id}/comments '{"comment":{"body":"Starting. <root cause + plan + test intent>"}}'
```

### Testing

**Every code change MUST include corresponding tests.** Specifically:

- **Bugs**: a test that reproduces the bug — one that fails before the fix and passes after, shipped in the same commit. A fix with no failing-first test has not been shown to fix anything.
- **Features**: tests that define the expected behaviour, including the error and edge paths.
- **Refactors**: coverage of the behaviour being preserved, in place before you move it — add it first if it is missing.

The tests covering your change must pass before every commit. Match the style of the neighbouring tests — their fixtures, helpers and favoured matchers — rather than importing habits from elsewhere.

#### The ordering and the coverage bar are the project's call

**This skill's default is test-first**: investigate → write a failing test → implement → watch it pass → lint → COMMIT. A test written after the code tends to assert what the code does rather than what it should do.

**But it is a default, not a universal. The project's testing policy wins**: where the installing project's instructions set an ordering or a coverage bar, follow them. Where they are silent, work test-first and cover every new or changed line.

What does **not** vary: a change ships with tests, a bug fix has a test that failed before the fix, and the tests covering your change pass before you commit.

#### What to test, where

| Layer | Coverage target |
| --- | --- |
| HTTP endpoints | Happy path + validation errors + **authorization** |
| Domain / data models | Validations, scopes, callbacks, business-logic methods |
| Client-side logic | Hooks, store actions, utility functions, component behaviour |
| Concurrent code | Business logic, exercised under the race detector if the language has one |

**Put each test where the project already puts that kind of test.** If a layer has no home yet, ask: a test in the wrong tree often never runs, which looks identical to passing.

### Description conventions

- **Every ticket must have a description and effort estimate.** A title alone is not sufficient.
- **Stakeholder text verbatim; agent text kept current.** Fetch the ticket BEFORE patching. The stakeholder's words stay first and word-for-word, then a `\n\n---\n\n` separator, then yours; their request is the source of truth. Your own additions are living documentation: when facts change, edit them in place rather than stacking dated updates, so the description reads as one current spec.
- **Steps someone performs are SUBTASKS, not description checkboxes** — a runbook, a migration sequence, a mixed-actor procedure. The board can render, count, order, assign and broadcast a subtask; a `- [ ]` is only prose. A single thing to do needs no subtask: it is the ticket. Acceptance criteria also stay in the description, because they are claims about done-ness rather than things anyone performs. See [Subtasks](references/subtasks.md).
- **Mixed-actor tickets: one timeline, both assigned.** When some steps only the stakeholder can do (vendor consoles, secrets, purchases, hardware), assign BOTH parties to the ticket and give each subtask its own `assignee_id`, in execution order. Never split it into "Stakeholder does: / Agent does:" sections — they hide the interleaving, and the first untoggled subtask must show whose move it is. Tick each the turn its step completes. When the next untoggled subtask is the stakeholder's, apply the External-blocker protocol: leave `started`, comment naming the awaited step, add the dependency. Full rule: [`hard-rules`](#related-skills) → Steps Are Subtasks.

### Comment conventions

Post comments as you work — at minimum the [start comment](#post-the-start-comment-before-the-first-code-edit) and a delivery comment. The thread should tell the implementation story.

- **Capture user interjections** — when the user sends scope-affecting messages mid-ticket, mirror them into the ticket's comment thread.
- **Use `#N` for tickets, `pN` for projects** — both autolink on the board. Never write "ticket 123" or "project 66" in prose.
- **Format for the board, not a terminal** — see [Formatting](#formatting-descriptions-and-comments).
- **References happen by themselves; a prerequisite needs a DEPENDENCY.** There is no References API and nothing to call. Juscribe parses `#N`/`pN` out of a ticket's **title and description** on save and stores the references itself; editing the text removes stale ones.
  - ⚠️ **Comments are NOT scanned.** A `#N` written only in a comment creates no reference, though it still renders as a link.
  - **Read them off the payload, not the text.** Every ticket and project carries both directions resolved: `references` (what it points at) and `referenced_by` (what points at it). Each entry is `{type, id, title, ticket_type, color}`, with `id` the `#N` / `pN` you would write. Regexing the description cannot see `referenced_by` at all. A deleted target comes back with a `null` id, so check before you follow one.
  - **When a ticket genuinely gates another** ("requires #752 complete"), the mechanism that makes it real on the board — `blocked: true`, a row in `active_dependencies_summary` — is a dependency:
    ```sh
    jus api POST /workspaces/{ws}/tickets/{blocked}/dependencies '{"dependency":{"blocker_type":"Ticket","blocker_id":{blocker},"blocked_type":"Ticket","blocked_id":{blocked}}}'
    ```
  - ⚠️ **Set one only when it is genuinely blocking.** A dependency asserts the work _cannot proceed_, and the [Dependency Handling Protocol](references/dependencies.md) tells other agents to skip what it marks. Put a soft ordering preference in the description instead, and say why it is not a blocker.
- **Read comment reactions as stakeholder signals** — `include_comments=true` returns them per comment, and several 👎 from the stakeholder is an effective rejection of that approach. The full legend, and the endpoint for toggling your own, are in [references/formatting.md](references/formatting.md).

### Formatting descriptions and comments

Descriptions and comments render as **markdown on the board**, for a human scanning a card rather than a terminal log. Structure beats prose:

- **Bold section labels** open each part of the story: `**Root cause:**`, `**Plan:**`, `**What shipped:**`, `**To verify:**`, `**Acceptance criteria:**`.
- **Bullets and numbered lists** over paragraph runs — one idea per bullet, and numbered steps for anything the stakeholder will follow in order.
- **Fenced code blocks** for every command, path list or output the stakeholder might copy (`sh`-fenced for commands); **inline backticks** for file paths, method names, flags and states in prose.
- **`#N` / `pN` references** wherever you mention tickets or projects. ⚠️ **`#N` is RESERVED for ticket ids. Never write a bare `#` in front of any other number** — a workspace id, a comment id, a row id, a port, a count. In a title or description it creates a real reference to whichever ticket carries that number; in a comment it still renders as a ticket link. Write `workspace 12`, `comment 6079`, `port 5432`.
- **Bold the verdict, not everything** — the load-bearing words (`**no mount**`, `does **not** retry`), not whole sentences.

⚠️ **A fence inside ANY list item must sit at the list's CONTENT column** — two spaces under a `- ` marker, not lined up under the text. Indented further, it renders as one line of inline code with the language tag glued to the command, while the source still looks correct. Check the rendered output; the worked example, and an example start comment, are in [references/formatting.md](references/formatting.md).

A delivery comment: `**Commit:**` line, a short `**What shipped:**` block, then a numbered `**To verify:**` list — see [Post finished comment](references/delivering.md#post-finished-comment-before-transitioning). Description flesh-outs and blocker comments follow the same conventions.

### Commit conventions — THE MOST IMPORTANT STEP

**Commit the moment code and lint are done** — before self-review, before a comment or a transition, before replying to anyone. Sequence: code → lint → **COMMIT** → everything else. Never move on with a dirty working tree. One commit per ticket, tests included; a self-review fix is a second commit naming the same ticket.

The subject format is yours. End the message with the ticket trailer, as its **last paragraph** alongside any `Co-Authored-By:` — git reads only the final block, so a trailer anywhere else links nothing:

```text
Jus-Ticket: <n>
```

⚠️ **A breaking change is `BREAKING-CHANGE:`, never `BREAKING CHANGE:`.** The spaced key disqualifies the whole final paragraph, so the commit succeeds and the ticket silently never links. Bracket references that move a ticket, and why the reference stays out of the subject on a code host, are in [`hard-rules`](#related-skills) → Commit Rules. **Never `git push`** — the stakeholder pushes.

## Phase 5: Self-Review

After committing, review your diff (`git show`). Go beyond the diff:

- Naming consistency with surrounding code
- Paradigm fit (does it match existing patterns?)
- DRY opportunities with existing code
- Missed cleanup or dead code
- Refactoring the change exposes
- Performance implications

### Where the commands come from

**This skill does not name them**: it ships to projects with different stacks, and a runner named here would be wrong everywhere else. The obligations below are universal; the invocations live in the project's own instructions — its `CLAUDE.md`, contributor guide or task runner.

If you cannot find them, **ask rather than guess**. A test command invented from the directory layout can pass while running nothing.

### Mandatory post-commit checks

> These checks are the point of self-review. **Do not skip them.**

Run, **scoped to the files in this commit**:

1. **The tests covering what you changed.** Prefer the tooling's own dependency-aware selection where it exists: a runner that follows the import graph finds the tests that exercise your change, not just the ones with matching filenames.
2. **Every linter and formatter that applies to those files**, including any static-analysis or smell tool the project treats as mandatory. Fix every warning in a file you touched, whether or not your change caused it.
3. **Any type checker.** It is usually project-wide — check whether yours can be scoped before assuming it can.

⚠️ **Know what this scope does not prove.** A changed-file gate misses a test with no textual or import link to the change — one reached through a shared callback, fixture, factory or config default. Without dependency-aware selection, "tests for the changed files" is a filename convention and that blind spot is wide.

So **widen the scope yourself when the change is cross-cutting**: a base class, a shared fixture, a migration, a config default, anything imported broadly. If the project runs a full suite somewhere — CI, a pre-push hook, a nightly job — know which, because that is what covers the gap.

Fix issues in a follow-up commit with the same ticket prefix. Only finish once the code would pass a senior review.

### Diff coverage gate

After lints pass, check coverage **of the diff** for every component you touched: that every new or changed line is exercised, not just that the tests pass.

Most projects wrap this in one command; find it rather than assembling one. Two things bite:

- **Coverage instrumentation is usually opt-in.** A plain test run often leaves the old report in place, and the diff check reads it — wrong line numbers and all — and reports success. Confirm the report came from the run you just did.
- **Scoping the test run also scopes the coverage.** The report covers only what the tests you ran exercised. That is the right denominator here, and says nothing about the project as a whole.

**Default threshold: 100%** — every new or changed line — unless the project's testing policy sets another. Where the default applies, a failure means writing the missing tests: do not deliver with uncovered lines.

**Stubborn lines, case by case:** a **reachable** line needs the test that exercises it, edge cases and error branches included, since those break first in production. **Unreachable or dead code** is refactored away, not hidden behind `:nocov:` or `/* istanbul ignore */`. Cover them all in one pass rather than carrying debt across commits.

### A second client surface needs its own pre-delivery check

**Where a project ships more than one client — a mobile app, a CLI, a public API, an embedded widget — code plus passing tests is NOT sufficient.** Work verified against the primary client can ship completely broken on the other. Before delivering a ticket that touches the second client, run the four checks in [references/second-client.md](references/second-client.md), and the project's own version of them where it has one.

## Phase 6 onwards: Finish, Deliver, and Project Completion

**[references/delivering.md](references/delivering.md) — open it before the `finished` transition, not after.** It carries the pre-delivery gate (did you actually do what the ticket asks?), the mandatory "To verify" steps, the one transition call and when a delivery is yours to make, and what closing a project involves.

⚠️ **Delivering is the phase most often done from memory, and memory asks the wrong question.** The gate is not "is the code good" but "does this differ from what the ticket says", and only the file asks the second.

## Batch Work & Special Workflows

- **Respect ticket ordering** — work tickets in their `position` order. Do not reorder or cherry-pick.
- **A stakeholder may have a shorthand for "work the whole backlog"**: every ticket in it, in position order, with no confirmation between them. Record the phrase in the project's own instructions; it is a convention between you and them, not a Juscribe feature.
- **Every ticket gets the FULL lifecycle, even in batch mode**: start → investigate → code → commit → self-review → **delivery comment with verification steps** → finish. Never skip or combine delivery comments — the stakeholder reviews tickets individually.
- **Do not force-deliver tickets that aren't fully done.** A batch ticket with questions, blockers or incomplete work stays in `started` with a comment while you move to the next; [references/dependencies.md](references/dependencies.md) records the block. Delivering partial work to "clear the batch" is strictly prohibited.
- **Research tickets** — start it, do the research (web searches, codebase analysis, docs), put the findings in the ticket description, then finish it. No commit needed: the description is the deliverable.

## State Machine Reference

```
unprioritized → prioritized → started → finished → delivered → accepted
                                                             → rejected → started
Any non-terminal state → cancelled  (requires resolution)
Any non-terminal state → converted  (ticket became a project — see below)
archived → accepted
```

Valid `cancelled` resolutions (enum — exact values): `duplicate`, `wont_do`, `cant_reproduce`, `obsolete`.

Panel mapping: `unprioritized→icebox`, `prioritized→backlog`, `started/finished/delivered/rejected→current`, `accepted/cancelled/converted/archived→done`.

`converted` and `archived` are terminal in practice: `converted` has no onward transition, and `archived` can only go to `accepted`.

⚠️ **A board may MERGE Finished into Delivered** — a per-workspace option its owner sets. The map is unchanged; the `finished` call lands the ticket in `delivered` in one transaction. That is why your `finished` call is your last one on every board: merged, it delivers; unmerged, delivering is a person's step. A `delivered` call on a ticket already there answers `200` unchanged, which is not a failure. The workspace payload's `merge_finished_into_delivered` says which kind of board you are on.

## Related Skills

- `hard-rules` — the non-negotiable must/must-not that overrides everything here (commit immediately, no lint suppression, stakeholder-verbatim descriptions, never deliver incomplete work, no `git push`, document discoveries), and which of them the enforcement hooks back deterministically. Claude Code plugin installs prefix skill names with `jus:` — invoke the prefixed form there.
