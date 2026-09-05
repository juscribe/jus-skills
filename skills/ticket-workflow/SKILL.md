---
name: ticket-workflow
description: The single load-bearing Juscribe SOP skill — the full ticket lifecycle from pickup to delivery, plus estimation, ticket types, labels, metadata, testing gates, and the complete `jus` CLI / API reference in bundled files this skill points at. Use when working any ticket — picking one up, transitioning state, investigating, sizing, labeling, writing tests, running pre-commit gates, calling `jus api`, committing, self-reviewing, finishing, delivering, handling rejections, processing batches, or resolving dependency blockers. Auto-invoke whenever a ticket ID (`#N`) or "work on this ticket" / "pick up backlog" / "deliver" / "rejected" appears. In a project wired to Juscribe (a `.jus/` directory or the `jus` CLI), bare ticket language — `#123`, the board, the backlog, deliver — always means Juscribe tickets, so this skill is the one to invoke for them, never a skill for any other issue tracker.
allowed-tools: Bash(jus *), Bash(git *), Bash(make *), Bash(cd *), Read, Grep, Glob, Edit, Write
license: MIT
---

# Ticket Workflow — Juscribe Lifecycle SOP

> **This skill and `.jus/SOP.md` overlap deliberately.** That file is the standalone SOP, appended to your AI context by `jus init` so a project with no plugin still has one. This skill covers the same lifecycle in more depth and is kept more current — where the two differ, this one wins.
>
> Read this when working any ticket. This is the **single load-bearing skill** for Juscribe work: this file defines the lifecycle (session start → pickup → investigate → label → code → commit → self-review → finish → deliver) and the batch-work rules, and the operational detail an agent needs along the way — the `jus` CLI / API, estimation, ticket types, metadata, dependencies, subtasks, delivery and conversion — sits in the reference files listed below, which cost nothing until you open one. The companion [`hard-rules`](#related-skills) skill carries the non-negotiable must/must-not; on harnesses that run the jus enforcement hooks (Claude Code today, with Codex and Kimi adapters) the most painful of those are enforced deterministically, and everywhere else they are prompt-level only.

The lifecycle, in one line:

```
(1) create or pick up → (2) start → (3) investigate → (3b) apply labels → (4) code → (5) commit → (6) self-review → (7) finish → (8) deliver
```

Every change goes through every phase, no exceptions for "small" or "ad-hoc" work. Transitions happen at the natural moment, not batched — the board must reflect reality in real time. **NEVER transition to `accepted` or `rejected`** — only the stakeholder decides.

## Reference files — read the one you need, when you need it

This file is the lifecycle. The operational detail sits beside it and is **not** loaded until you open it. Each line says what the file prevents, because that is what tells you whether to open it:

| Read | Before |
| --- | --- |
| [references/api.md](references/api.md) | Constructing **any** `jus api` call. Four documented request shapes return a 400 or hang on stdin if you guess, and the response envelope is not the JSON root. |
| [references/estimation-and-types.md](references/estimation-and-types.md) | Sizing, typing or labelling a ticket, or filling in a sparse one. Also the pre-start metadata gate and the placement rules for a new ticket. |
| [references/dependencies.md](references/dependencies.md) | Recording that a ticket is blocked. One blocker per independently-clearing condition, and editing one means setting **both** `title` and `description`. |
| [references/delivering.md](references/delivering.md) | Finishing or delivering anything — the pre-delivery gate, the mandatory "To verify" steps, the transitions, and project completion. |
| [references/subtasks.md](references/subtasks.md) | Writing steps someone performs. Steps are subtasks, never description checkboxes, and `completed` is not `/toggle`. |
| [references/converting.md](references/converting.md) | Converting a ticket to a project, or wondering whether a retype is what you actually want. Only a `research` ticket can be converted. |

⚠️ **A pointer is not the content.** If you are about to write a `jus api` call, a dependency, a subtask or a delivery comment, open the file — answering from this table is how a wrong request shape ships.

## Phase 0: Prerequisites — the `jus` CLI must be installed and authenticated

This SOP drives the Juscribe board through the **`jus` CLI**. The bundle ships the **skills and hooks only — not the CLI binary**, so before any phase below will work the user needs:

1. **The CLI** — `brew install juscribe/tap/jus` (or the curl installer at `app.juscribe.ai/install.sh`).
2. **Auth + workspace** — `jus login` (API token) or `jus init` (token + workspace + `bin/jus` symlink). `jus init` also sets the `{ws}` used throughout this skill.

**Preflight.** If you're about to run `jus` and aren't sure it's configured, run `jus whoami` first and read the failure:

- `jus: command not found` → the CLI isn't installed. Tell the user to `brew install juscribe/tap/jus`, then stop.
- `Error: No token available. Run 'jus login'…` → installed but unauthenticated. Tell the user to run `jus login` or `jus init`, then stop.
- `Error: Stored token is invalid or expired.` — or any `HTTP 401` from `jus api` — → the token was real and is now **retired**. API tokens expire: agent tokens 90 days after creation or last rotation, mobile sessions 60 days after last use. The 401 body names the remedy. Relay it and stop.
  - An **agent** token needs a **rotate** (Settings → API Tokens), _not_ another `jus login` — re-authenticating hands back the same dead secret.
  - Tell the user which, then stop.

**Do not loop `jus` commands against an unconfigured CLI, or against a 401.** A 401 never heals by retrying; it is a credential the user must replace. Surface the single setup step the error points to and stop — one clear instruction beats a wall of repeated errors. Everything below assumes this preflight passed.

## Phase 1: Session Start

Orient with the agent state endpoint — never fetch full ticket lists at session start.

```sh
jus api GET '/workspaces/{ws}/agent_state?panels=current,backlog'
```

Returns compact markdown (~2–4KB) with projects, velocity, users, and condensed ticket lines. Cache TTL 5 minutes. Use it to decide what to work on, then fetch individual tickets as needed.

## Phase 2: Ticket Pickup

### Fetch the ticket with comments AND attachments

```sh
jus api GET '/workspaces/{ws}/tickets/{id}?include_comments=true&include_attachments=true&include_label_objects=false'
```

**MUST include comments and attachments.** Comments contain stakeholder context, open questions, decisions. Attachments contain rejection screenshots and design mocks. Skip neither. (Check `comments_count` first — if it's `0`, skip `include_comments=true` and don't pay for an empty array.)

If response shows `blocked: true` or `active_dependencies_count > 0`, fetch dependencies and apply the [Dependency Handling Protocol](references/dependencies.md) below.

### Pre-start gate (hard checklist)

Before transitioning to `started`, verify:

- `description` is non-null
- `points` is set
- `stakeholder_id` is set

If any are missing, PATCH them first. Never start a ticket that fails this gate.

**The point scale, the ticket types and the metadata defaults are in [references/estimation-and-types.md](references/estimation-and-types.md)** — open it before putting a number or a type on anything. Guessing a type is a `422`, and guessing a point value silently distorts the board's velocity.

### Fleshing out a sparse user-created ticket

Stakeholders often file tickets as a bare title or a one-line description. The gate above is not satisfied by a token one-liner — **flesh the ticket out with substance the stakeholder can react to**:

- **What to add:** your read of the problem (root cause for bugs, approach for features), **acceptance criteria**, and any implementation/test notes. Format it per [Formatting](#formatting-descriptions-and-comments).
- **When:** at pickup — a blank description is filled as part of the pre-start gate; deeper findings discovered during investigation are appended as you learn them.
- **How:** always via the append protocol (see [Description conventions](#description-conventions)) — fetch first; if `description` is non-null, prepend the stakeholder's existing text + `\n\n---\n\n` before your additions. Their words survive verbatim, always.

The fleshed-out description is what makes the estimate defensible and the delivery verifiable — a title-only ticket has no acceptance criteria to deliver against.

### CRITICAL: Transition to `started` BEFORE investigating

The moment you decide to work the ticket, transition and assign yourself **before** reading any source files. This is a concurrency lock — it signals to other sessions that the ticket is taken.

```sh
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"started"}'
jus api PATCH /workspaces/{ws}/tickets/{id} '{"ticket":{"assignee_ids":[{your_user_id}]}}'
```

Sequence: fetch ticket → transition to started → assign yourself → react with 👀 → THEN investigate. **NEVER reverse this order.**

### Eyes reaction (non-dispatch agents only)

When working **outside a dispatch job**, signal active work with the 👀 ticket reaction so the stakeholder sees in-progress status on the board. Inside a dispatch job, skip — the dispatch UI already shows it.

```sh
# Add 👀 (on start)
jus api POST /workspaces/{ws}/tickets/{id}/ticket_reactions/toggle '{"emoji":"👀"}'
# Remove 👀 (on finish — same endpoint toggles off)
jus api POST /workspaces/{ws}/tickets/{id}/ticket_reactions/toggle '{"emoji":"👀"}'
```

### Concurrency conflict

If the transition to `started` fails, check current assignees. If another agent has claimed it, **stop**. Report to the user that the ticket appears taken and ask how to proceed.

### Rejection workflow

When a ticket is rejected: `rejected → started → fix → finish → deliver`. **NEVER** `git commit --amend` on delivered work — create a new commit.

- **When the user says "rejected"** the transition has already happened in the app. Do NOT call the reject transition API. Just transition `rejected → started` and fix.
- **Always fetch attachments on rejected tickets** — the stakeholder may have attached screenshots showing the issue. Use `jus download <url-path> .jus/tmp/<filename>` to view them.

## Phase 3: Investigation & Labels

After starting, investigate the codebase. Then apply 1–3 labels before writing code.

### Investigation guidelines

- **Match the exploration to the ticket.** A small, well-understood change wants a couple of direct file reads, not a fan-out of exploration agents. Calibrate what "small" means to your own codebase — any figure quoted here would be someone else's.
- **Skip deep architecture analysis for familiar domains** — for routine UI or styling work, read the target files + 1–2 neighbors. Don't trace the full state-management chain unless the fix requires it.
- **Time-box investigation to ~3 minutes** for tickets ≤ 2 points. If you're still reading code after 3 files, start implementing and adjust as you go.
- **Document what you learn in code comments** — when you decode an animation flow, state pattern, or WebSocket dance, leave explanatory comments in the source. Focus on "why" and "how the pieces connect" rather than obvious "what".

### Label conventions

Labels describe **technical areas** — the layers your change touches — not project themes or business intent. Project themes live in the project grouping; labels stay technical.

```sh
jus api PATCH /workspaces/{ws}/tickets/{id} '{"ticket":{"label_ids":[1,2]}}'
```

Guidelines:

- **1–3 labels per ticket** (most are 1–2). More than 3 means either the ticket is too large or the labels duplicate what the project already communicates.
- **Don't duplicate the project grouping.** If the project is "Mobile redesign," every ticket already implies `mobile` — don't re-label.
- `docs` — documentation-only tickets. Don't add it just because a code ticket also touches a comment or README.
- `refactor` — restructuring without behavior change. Don't combine with `frontend`/`backend` unless the refactor genuinely spans both.
- `regression` — bug that fixes behavior that previously worked. Apply alongside the relevant area label (e.g., `regression` + `frontend`).

#### Finding this workspace's labels

**Label IDs are per-workspace and are not listed here** — the set in your project is its own. Fetch it:

```sh
jus api GET '/workspaces/{ws}/labels'
```

**The project should document what each label MEANS**, not just its id, and that belongs in the project's own instructions. An id with no _when to apply_ is a label applied by guesswork — and the cost lands on whichever label people later want to filter by. In this project a security sweep once missed an internet-facing container with a route to the production database, because `security` had an id and no definition, so the ticket carried only `docker`.

**If you need a label that doesn't exist, ask the stakeholder before inventing one** — labels are a controlled vocabulary, and a near-duplicate is worse than a missing one because it silently splits every future filter.

## Phase 4: Coding

### Post the start comment BEFORE the first code edit

The very first thing in Phase 4 — before you edit a single source file — **post a "Starting" comment on the ticket**: the root cause / your read of the problem, the plan, and how you intend to test it. This is the earliest stakeholder-facing signal that work began and the record of your plan _before_ implementation. It is prompt-only (on harnesses running the jus hooks, a soft nudge fires on the first source edit — nothing hard-blocks it anywhere), so it rests on you remembering. Do not skip it; do not fold it into the delivery comment.

```sh
jus api POST /workspaces/{ws}/tickets/{id}/comments '{"comment":{"body":"Starting. <root cause + plan + test intent>"}}'
```

### Testing

**Every code change MUST include corresponding tests.** Specifically:

- **Bugs**: a test that reproduces the bug — one that fails before the fix and passes after. Ship it in the same commit as the fix; a fix with no failing-first test has not been shown to fix anything.
- **Features**: tests that define the expected behaviour, including the error and edge paths.
- **Refactors**: coverage of the behaviour being preserved, before you move it. Add it first if it is missing.

Existing tests must pass — a green run of the tests covering your change is a prerequisite for every commit. Match the existing test style: study the neighbouring test files for their conventions (fixture and factory helpers, authentication helpers, the matchers they favour) rather than importing habits from elsewhere.

#### The ordering and the coverage bar are the project's call

**This skill's default is test-first** — investigate → write a failing test → implement → watch it pass → lint → COMMIT — and it is the default for a reason: a test written after the code tends to assert what the code does rather than what it should do, and a bug fix with no failing-first test cannot distinguish a fix from a coincidence.

**But it is a default, not a universal.** Plenty of teams that ship well do not write test-first, and a coverage number that is right for one codebase is theatre in another. **The project's testing policy wins**: if the installing project's own instructions state an ordering or a bar, follow those. Where they are silent, use test-first and aim to cover every new or changed line.

What does **not** vary, whatever the policy says: a change ships with tests, a bug fix has a test that failed before the fix, and the tests covering your change pass before you commit. Those are the obligations this skill enforces; the rest is the project's.

#### What to test, where

| Layer | Coverage target |
| --- | --- |
| HTTP endpoints | Happy path + validation errors + **authorization** |
| Domain / data models | Validations, scopes, callbacks, business-logic methods |
| Client-side logic | Hooks, store actions, utility functions, component behaviour |
| Concurrent code | Business logic, exercised under the race detector if the language has one |

**Put each test where the project already puts that kind of test** — mirror the neighbours rather than inventing a location. If a layer has no existing home, ask; a test in the wrong tree often does not run at all, which looks identical to passing.

### Description conventions

- **Every ticket must have a description and effort estimate.** A title alone is not sufficient.
- **Stakeholder text verbatim; agent text kept current.** Fetch the ticket BEFORE patching. A stakeholder's description is preserved word-for-word — prepend it plus a `\n\n---\n\n` separator before your additions; their one-sentence request is the source of truth. Your own prior additions are living documentation: when facts change, edit them in place rather than appending dated update layers — the description should always read as one coherent, current spec.
- **Steps someone performs are SUBTASKS, not description checkboxes.** A runbook, a migration sequence, a mixed-actor procedure — those are subtasks on the ticket, because the board can render, count, order, assign and broadcast them and a `- [ ]` is only prose. **A sequence, though: one thing to do needs no subtask** — it lives in the ticket's own description, under the ticket's own assignee and state. Acceptance criteria are the other exception and stay in the description: they are claims about done-ness, not things anyone performs. See [Subtasks](references/subtasks.md).
- **Mixed-actor tickets: one timeline, both assigned.** When some steps are only the stakeholder's (vendor consoles, secrets, purchases, hardware) and others are the agent's, assign BOTH parties on the ticket and give each subtask its own `assignee_id`, in execution order. Never separate "Stakeholder does: / Agent does:" sections: they hide the interleaving, and the first untoggled subtask must show whose move it is. Tick each the turn its step completes. When the next untoggled subtask is the stakeholder's, apply the External-blocker protocol (leave `started`, comment naming the awaited step, add the dependency). Full rule + example: [`hard-rules`](#related-skills) → Steps Are Subtasks.

### Comment conventions

Post comments as you work — at minimum a start comment (see [above](#post-the-start-comment-before-the-first-code-edit), posted before the first code edit) and a delivery comment when finishing. The comment thread should tell the implementation story.

- **Capture user interjections** — if the user sends scope-affecting messages mid-ticket, mirror those notes into the ticket's comment thread.
- **Use `#N` for tickets, `pN` for projects** — autolinks on the board. Never write "ticket 123" or "project 66" in prose.
- **Format for the board, not a terminal** — see [Formatting](#formatting-descriptions-and-comments) below. Descriptions and comments render as markdown; unformatted walls of text are hard for the stakeholder to scan.
- **References happen by themselves; a prerequisite needs a DEPENDENCY.** These are two different features and this skill used to conflate them, telling you to "create formal References via the API". **There is no such API and nothing to call.** Juscribe parses `#N`/`pN` out of a ticket's **title and description** on save and stores the References itself — writing the reference _is_ the mechanism, and stale rows disappear when you edit the text.
  - ⚠️ **Comments are NOT scanned.** Only title and description feed the parser, so a `#N` written only in a comment creates no Reference. It still autolinks when rendered — that is the client drawing a link, not a stored relationship.
  - **Read them off the payload — do not re-derive them from the text.** Every ticket and project comes back with both directions already resolved: `references` (what this item points at) and `referenced_by` (what points at it). Each entry is `{type, id, title, ticket_type, color}`, with `id` the `#N` / `pN` you would write. Regexing the description instead is the bug this replaced: it renders a bare `#123` for anything the reader has not already loaded, and it cannot see `referenced_by` at all. A target that has since been deleted comes back with a `null` id rather than vanishing, so check before you follow one.
  - **When a ticket genuinely gates another** ("requires #752 complete"), the mechanism that makes it real on the board — `blocked: true`, a row in `active_dependencies_summary` — is a dependency:
    ```sh
    jus api POST /workspaces/{ws}/tickets/{blocked}/dependencies '{"dependency":{"blocker_type":"Ticket","blocker_id":{blocker},"blocked_type":"Ticket","blocked_id":{blocked}}}'
    ```
  - ⚠️ **Set one only when it is genuinely blocking.** A dependency asserts the work _cannot proceed_, and the [Dependency Handling Protocol](references/dependencies.md) tells other agents to skip what it marks. Recording a soft ordering preference that way makes a workable ticket look unstartable — put that in the description instead, and say why it is not a blocker.
- **Pay attention to comment reactions** — `include_comments=true` returns a `reactions` array per comment. Interpret as stakeholder signals:
  - 👍 agreement / "good direction"
  - 👎 disagreement / "wrong approach" — multiple 👎 from the stakeholder = effective rejection of that approach
  - ❤️ strong approval
  - 🤔 uncertainty / "think about this more"
  - 🎉 celebration / "this is great"
  - 👀 "I'm watching this" / "needs attention"
  - 👍 on a suggestion = "yes, do this"
- **Toggle a reaction on a comment** with the nested endpoint (same call adds and removes):
  ```sh
  jus api POST /workspaces/{ws}/tickets/{ticket_id}/comments/{id}/reactions/toggle '{"emoji":"👍"}'
  ```

### Formatting descriptions and comments

Ticket descriptions and comments render as **markdown on the board**. Write them for a human scanning a card, not for a terminal log. Structure beats prose:

- **Bold section labels** open each part of the story: `**Root cause:**`, `**Plan:**`, `**What shipped:**`, `**To verify:**`, `**Acceptance criteria:**`. The stakeholder should locate any section at a glance.
- **Bullets and numbered lists** over paragraph runs — one idea per bullet; numbered steps for anything the stakeholder will follow in order (verification steps especially).
- **Fenced code blocks** for every command, path list, or output the stakeholder might copy (`sh`-fenced for commands); **inline backticks** for file paths, method names, flags, and states in prose.
- **`#N` / `pN` references** wherever you mention tickets or projects — they autolink (see above). ⚠️ **`#N` is RESERVED for ticket ids. Never write a bare `#` in front of any other number** — a workspace id, a comment id, a row id, a port, a count. A ticket's `title` and `description` are **parsed**, and a `#N` there creates a real reference row pointing at whatever ticket carries that id, so the ticket ends up formally linked to unrelated work and they show it back. Write `workspace 12`, `comment 6079`, `port 5432`. Comments are not parsed, but they still autolink in the UI and read as ticket refs.
- **Bold the verdict, not everything** — emphasize the load-bearing words (`**no mount**`, `does **not** retry`), not entire sentences. Over-bolding reads as noise.

A start comment shaped this way:

```markdown
Starting.

**Root cause:** `RejectionAutoDispatchJob#dispatchable?` checks policy and
marker type but never station reachability, so every rejection creates a
dispatch that immediately fails when no station is running.

**Plan:** guard with `workspace.online_agents_for(user).any?` — the same
reachability check the dispatch button uses.

**Tests:** failing job specs first (no station → no dispatch; station
registered elsewhere → no dispatch; reachable → dispatch as before).
```

⚠️ **A fence inside ANY list item must sit at the list's CONTENT column** — two spaces under a `- ` marker, not lined up under the text. Indent it further and CommonMark reads it as a lazy paragraph continuation, because an indented code block cannot interrupt a paragraph; inline parsing then treats the fence as a triple-backtick **code span**, collapses the newline, and the language tag becomes content. A step meant to read as a copyable command renders as `sh my-command` instead, with the `sh` glued to the front.

````text
WRONG — 6 spaces. Renders as one code span: `sh my-command --flag`
- [ ] 2. Run the thing:
      ```sh
      my-command --flag
      ```

RIGHT — 2 spaces. Renders as a code block.
- [ ] 2. Run the thing:
  ```sh
  my-command --flag
  ```
````

**The source looks correct either way**, which is why this needs stating rather than trusting a re-read. Check the rendered output, not the markdown.

And a delivery comment: `**Commit:**` line, a short `**What shipped:**` block, then a numbered `**To verify:**` list — see [Post finished comment](references/delivering.md#post-finished-comment-before-transitioning). The same conventions apply to description flesh-outs (root cause, acceptance criteria) and dependency/blocker comments.

### Commit conventions — THE MOST IMPORTANT STEP

> **CRITICAL: Commit is NOT optional, NOT deferrable, NOT something you "get to later."**
> The moment code changes are done and linters pass, you commit. IMMEDIATELY. Before responding to the user. Before self-review commentary. Before anything. An uncommitted change is invisible, unrecoverable, and a direct violation of this SOP.

- **Commit is the FIRST thing after code + lint** — not the last thing. Sequence: code → lint → **COMMIT** → then everything else (self-review, comments, transitions, user communication). If you find yourself typing a response and you haven't committed, STOP and commit first.
- **Never move on with a dirty working tree** — not to answer a question, not to explain what you did, not to run additional checks. Commit first, talk second.
- **One commit per ticket**, self-contained: backend + frontend + tests together. Follow-up fixes from self-review get a second commit with the same ticket prefix.
- **Format**: `[#N] Short description` or `[#N, #M] Short description` for multi-ticket commits.
- **Do NOT push to remote** — the stakeholder pushes manually. Never run `git push`.

## Phase 5: Self-Review

After committing, review your diff (`git show`). Go beyond the diff:

- Naming consistency with surrounding code
- Paradigm fit (does it match existing patterns?)
- DRY opportunities with existing code
- Missed cleanup or dead code
- Refactoring the change exposes
- Performance implications

### Where the commands come from

**This skill does not name them, deliberately.** It ships to projects with different stacks, and a runner named here is wrong everywhere it does not apply. The obligations below are universal; the exact invocations live in the project's own instructions — its `CLAUDE.md`, contributor guide, or task runner.

If you cannot find them, **ask rather than guess**. A test command invented from the directory layout can pass while running nothing, which is worse than admitting you don't know it.

### Mandatory post-commit checks

> These checks are the entire point of self-review. Skipping them has shipped broken tests and lint warnings across multiple tickets. **Do not skip.**

Run, **scoped to the files in this commit**:

1. **The tests covering what you changed.** Prefer the tooling's own dependency-aware selection where it exists — a runner that follows the import graph finds the tests that actually exercise your change, not just the ones with matching filenames.
2. **Every linter and formatter that applies to those files**, including the static-analysis or smell tools the project treats as mandatory. Fix every warning in a file you touched, whether or not your change caused it.
3. **Any type checker**, which is usually project-wide rather than per-file — check whether yours can be scoped at all before assuming it can.

⚠️ **Know what this scope does not prove.** A changed-file gate cannot catch a change that breaks a test it has no textual or import-level link to — a shared callback, a fixture, a factory, a config default. Where the project's runner has no dependency-aware selection, "tests for the changed files" collapses to a filename convention and that blind spot is wide.

So: **widen the scope yourself when the change is cross-cutting.** Editing a base class, a shared fixture, a migration, a config default or anything imported broadly means running more than the file's own tests, regardless of what the default gate says. If the project runs a full suite anywhere — CI, a pre-push hook, a nightly job — know which, because that is what is actually covering the gap.

Fix issues in a follow-up commit with the same ticket prefix. Only finish once the code would pass a senior review.

### Diff coverage gate

After lints pass, check coverage **of the diff** for every component you touched. This verifies that all new/changed lines are exercised — not just that tests pass.

Most projects wrap this in a single command; find it rather than assembling one. Two things that bite:

- **Coverage instrumentation is usually opt-in.** A plain test run often does not refresh the coverage data, so the diff check silently reads a stale report with the wrong line numbers and reports success. Confirm the report was written by the run you just did.
- **Scoping the test run also scopes the coverage.** If you ran only the tests for the changed files, the report covers only what those exercised — which is the right denominator here, but not a statement about the project as a whole.

**Default threshold: 100%** — every new or changed line covered — unless the project's testing policy sets a different one. Where the default applies, a failure means write the missing tests, not "good enough": do not deliver with uncovered lines.

**Coverage strategy for stubborn lines** — analyze case by case: a **reachable** line means write the test that exercises it (don't skip "edge cases" or "error branches" — those are the most likely to break in production); **unreachable / dead code** means refactor the source to eliminate it rather than gaming coverage with `:nocov:` / `/* istanbul ignore */` markers. Do all uncovered lines in one pass; don't accumulate coverage debt across commits.

### A second client surface needs its own pre-delivery check

**Where a project ships more than one client — a mobile app, a CLI, a public API, an embedded widget — code plus passing tests is NOT sufficient.** Work verified entirely against the primary client can be delivered completely broken on the second one, because the two do not share a surface. Treat this as a hard gate whenever a ticket touches the second client.

The four checks, in the order they bite:

1. **The client's own API namespace exposes every action the feature calls.** A second client usually has its own namespace, and a route existing on the primary surface does **not** mean it exists on the other. This is the one that produces a 404 at runtime with a green test suite.
2. **The serializer or sparse-fieldset constants include every field the UI reads.** Second clients are often more aggressively field-limited; a missing field returns **undefined at runtime rather than erroring**, so it looks like a rendering bug and gets debugged in the wrong layer.
3. **The platform's own interaction constraints are exercised, not inherited by assumption.** Anything the primary client gets for free from its runtime — input focus, keyboard occlusion, back-navigation, offline state — has to be handled explicitly on the other.
4. **Request specs against the client's own namespace**, not only the primary one's.

**Find the project's own version of this list** — where a second client exists, the specifics (namespace paths, the field constants, the platform affordance that bites) belong in that project's own docs. This is the obligation; the project supplies the checks.

## Phase 6 onwards: Finish, Deliver, and Project Completion

**[references/delivering.md](references/delivering.md) — open it before the `finished` transition, not after.** It carries the pre-delivery gate (did you actually do what the ticket asks?), the mandatory "To verify" steps, the two transition calls in order, and what closing a project involves.

⚠️ **Delivering is the phase most often done from memory, and the memory is wrong in a specific way:** the gate is not "is the code good", it is "does this differ from what the ticket says". Those are different questions and only the file asks the second one.

## Batch Work & Special Workflows

- **Respect ticket ordering** — work tickets in their assigned `position` order. Do not reorder or cherry-pick.
- **A stakeholder may have a shorthand for "work the whole backlog"** — if yours does, it means every ticket in the backlog, in position order, without asking for confirmation between them. Record the phrase in the project's own instructions; it is a convention between you and them, not a Juscribe feature.
- **Every ticket gets the FULL lifecycle, even in batch mode.** Each gets: start → investigate → code → commit → self-review → **delivery comment with verification steps** → finish → deliver. Do not skip the delivery comment to save time. Do not combine delivery comments across tickets — the stakeholder reviews tickets individually.
- **Do not force-deliver tickets that aren't fully done.** If a batch ticket has questions, blockers, or incomplete work, leave it in `started` with a comment and move to the next. Recording the block is [references/dependencies.md](references/dependencies.md). Delivering partial work to "clear the batch" is strictly prohibited.
- **Research ticket workflow** — start the ticket, do the research (web searches, codebase analysis, reading docs), capture findings in the ticket description, then finish and deliver. No code commits needed — the deliverable is the description content itself.

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

> **`converted` and `archived` are real states.** An earlier version of this
> reference listed neither, which made the lifecycle look like it ended at
> accepted or cancelled. Both are terminal for practical purposes — `converted`
> has no onward transitions at all, and `archived` can only go to `accepted`.

## Related Skills

- `hard-rules` — the non-negotiable must/must-not that overrides everything here (commit immediately, no lint suppression, stakeholder-verbatim descriptions, never deliver incomplete work, no `git push`, document discoveries) and the map of which rules the enforcement hooks back deterministically on harnesses that run them. (Claude Code plugin installs show skill names prefixed with `jus:` — invoke the prefixed form there.)

> **Note:** `ticket-workflow` is the single load-bearing SOP skill — it inlines the estimation, labeling, testing-gate, and `jus` API material that earlier lived in the separate `testing-gates`, `juscribe-api`, and `estimation-labels` skills (retired because they never auto-invoked; their content was already resident here). For monumental, the deeper extracted reference also lives in `.jus/sop/` (`api-reference.md`, `workflows.md`, `commands.md`) and `.jus/docs/`.
