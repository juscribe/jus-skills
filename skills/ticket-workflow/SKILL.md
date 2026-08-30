---
name: ticket-workflow
description: The single load-bearing Juscribe SOP skill — the full ticket lifecycle from pickup to delivery PLUS estimation, ticket types, labels, metadata, testing gates, and the complete `jus` CLI / API reference. Use when working any ticket — picking one up, transitioning state, investigating, sizing, labeling, writing tests, running pre-commit gates, calling `jus api`, committing, self-reviewing, finishing, delivering, handling rejections, processing batches, or resolving dependency blockers. Auto-invoke whenever a ticket ID (`#N`) or "work on this ticket" / "pick up backlog" / "deliver" / "rejected" appears. In a project wired to Juscribe (a `.jus/` directory or the `jus` CLI), bare ticket language — `#123`, the board, the backlog, deliver — always means Juscribe tickets, so this skill is the one to invoke for them, never a skill for any other issue tracker.
allowed-tools: Bash(jus *), Bash(git *), Bash(make *), Bash(cd *), Read, Grep, Glob, Edit, Write
license: MIT
---

# Ticket Workflow — Juscribe Lifecycle SOP

> **This skill and `.jus/SOP.md` overlap deliberately.** That file is the standalone SOP, appended to your AI context by `jus init` so a project with no plugin still has one. This skill covers the same lifecycle in more depth and is kept more current — where the two differ, this one wins.
>
> Read this when working any ticket. This is the **single load-bearing skill** for Juscribe work: it defines the full lifecycle (session start → pickup → investigate → label → code → commit → self-review → finish → deliver), the batch-work rules, the dependency-blocker protocol, **and** the operational reference an agent needs along the way — estimation, ticket types, labels, metadata, the testing gates, and the `jus` CLI / API. The companion [`hard-rules`](#related-skills) skill carries the non-negotiable must/must-not; on harnesses that run the jus enforcement hooks (Claude Code today, with Codex and Kimi adapters) the most painful of those are enforced deterministically, and everywhere else they are prompt-level only.

The lifecycle, in one line:

```
(1) create or pick up → (2) start → (3) investigate → (3b) apply labels → (4) code → (5) commit → (6) self-review → (7) finish → (8) deliver
```

Every change goes through every phase, no exceptions for "small" or "ad-hoc" work. Transitions happen at the natural moment, not batched — the board must reflect reality in real time. **NEVER transition to `accepted` or `rejected`** — only the stakeholder decides.

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

If response shows `blocked: true` or `active_dependencies_count > 0`, fetch dependencies and apply the [Dependency Handling Protocol](#dependency-handling-protocol) below.

### Pre-start gate (hard checklist)

Before transitioning to `started`, verify:

- `description` is non-null
- `points` is set (see [Estimation](#estimation))
- `stakeholder_id` is set

If any are missing, PATCH them first. Never start a ticket that fails this gate.

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
- **Steps someone performs are SUBTASKS, not description checkboxes.** A runbook, a migration sequence, a mixed-actor procedure — those are subtasks on the ticket, because the board can render, count, order, assign and broadcast them and a `- [ ]` is only prose. Acceptance criteria are the exception and stay in the description: they are claims about done-ness, not things anyone performs. See [Subtasks](#subtasks--a-tickets-checklist).
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
  - ⚠️ **Set one only when it is genuinely blocking.** A dependency asserts the work _cannot proceed_, and the [Dependency Handling Protocol](#dependency-handling-protocol) tells other agents to skip what it marks. Recording a soft ordering preference that way makes a workable ticket look unstartable — put that in the description instead, and say why it is not a blocker.
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

And a delivery comment: `**Commit:**` line, a short `**What shipped:**` block, then a numbered `**To verify:**` list — see [Post finished comment](#post-finished-comment-before-transitioning). The same conventions apply to description flesh-outs (root cause, acceptance criteria) and dependency/blocker comments.

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

## Phase 6: Finish & Deliver

### Pre-delivery gate: Did you actually do what the ticket asks?

**Before finishing, re-read the ticket description and acceptance criteria.** Did you implement what was prescribed? If you deferred something, skipped a requirement, chose not to do something the ticket specifies, or deviated from the described scope — **do NOT finish or deliver.** Instead:

1. Leave the ticket in `started`.
2. Post a comment explaining what you couldn't do, why, and what options exist.
3. Add an **External dependency** so the ticket shows as blocked:
   ```sh
   jus api POST /workspaces/{ws}/tickets/{id}/dependencies '{"dependency":{"blocker_type":"External","blocked_type":"Ticket","blocked_id":{id},"description":"User input"}}'
   ```
4. Move on to the next ticket. The stakeholder resolves the dependency after providing input.

**Delivering work that doesn't match the ticket is worse than not delivering at all** — it forces a rejection cycle. When in doubt, leave it started and comment.

### Post finished comment BEFORE transitioning

Re-read the ticket's comments (`?include_comments=true`) before writing the delivery comment. Don't re-answer questions or repeat content from earlier comments (including your own start comment).

The "To verify" section with concrete acceptance/rejection steps is **mandatory, not optional — even during batch work.** Every ticket gets its own delivery comment with verification steps. Do not batch or skip. Shape the comment per [Formatting](#formatting-descriptions-and-comments): bold section labels, a numbered To-verify list, fenced code for commands.

**Every delivery comment MUST include git information:**

- **Direct commits on main:**

  ````
  **Commit:** `abc1234` on main
  ```sh
  git show abc1234 --stat
  git show abc1234
  ````

  N files changed, X insertions, Y deletions.

  ```

  ```

- **Dispatched work (on a branch):** Do NOT include branch info — the dispatch job appends it automatically after the session completes.
- **Tickets with no code changes** (research, documentation, already-implemented): Omit git info — state plainly that no code changes were made.

```sh
jus api POST /workspaces/{ws}/tickets/{id}/comments '{"comment":{"body":"...verification steps..."}}'
```

### Transition

```sh
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"finished"}'
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"delivered"}'
```

Sequence: commit → self-review → post finished comment → finish → deliver.

## Phase 7: Project Completion

When all tickets in a project reach `accepted`, post a **validation comment on the Project** summarizing how the stakeholder can verify every ticket works as spec'd. This is a consolidated end-to-end QA guide — not a repeat of individual ticket steps.

```sh
jus api POST /workspaces/{ws}/projects/{id}/comments '{"comment":{"body":"## Validation Guide\n\n1. Step one...\n2. Step two...\n..."}}'
```

Guidelines:

- **Cover every ticket** — reference each by `#N` and describe how to verify its behavior.
- **Order by user flow** — group steps by the natural order a user encounters the features, not by ticket number.
- **Be specific** — exact UI paths, expected states, edge cases worth checking.
- **Call out regressions** — note any areas where existing behavior could have been affected.

## Batch Work & Special Workflows

- **Respect ticket ordering** — work tickets in their assigned `position` order. Do not reorder or cherry-pick.
- **A stakeholder may have a shorthand for "work the whole backlog"** — if yours does, it means every ticket in the backlog, in position order, without asking for confirmation between them. Record the phrase in the project's own instructions; it is a convention between you and them, not a Juscribe feature.
- **Every ticket gets the FULL lifecycle, even in batch mode.** Each gets: start → investigate → code → commit → self-review → **delivery comment with verification steps** → finish → deliver. Do not skip the delivery comment to save time. Do not combine delivery comments across tickets — the stakeholder reviews tickets individually.
- **Do not force-deliver tickets that aren't fully done.** If a batch ticket has questions, blockers, or incomplete work, leave it in `started` with a comment and move to the next. Delivering partial work to "clear the batch" is strictly prohibited.
- **Research ticket workflow** — start the ticket, do the research (web searches, codebase analysis, reading docs), capture findings in the ticket description, then finish and deliver. No code commits needed — the deliverable is the description content itself.

## Estimation

Effort is captured in `points`. **Valid values: `0`, `1`, `2`, `3`, `5`, `8`** — no other values, no half-points.

| Points | Calibration |
| --- | --- |
| `0` | Trivial config change, typo fix — no real engineering effort |
| `1` | Single-file change, simple bug fix |
| `2` | Small feature or multi-file change with clear scope |
| `3` | Medium feature — new endpoint + frontend, multiple specs |
| `5` | Large feature spanning backend + frontend + tests, or a complex refactor |
| `8` | Epic-scale work — usually a sign the ticket should be broken into smaller tickets |

- **Every ticket gets points, including chores and bugs.** Chores are NOT automatically `0`; a chore that requires real work gets real points (chores affect velocity too). `0` is reserved for genuinely trivial / no-effort items.
- **Research tickets are typically `1`–`2` points** — the deliverable is description content, not code.
- **Features require points to leave icebox.** A feature with `points: null` cannot be transitioned to `prioritized` (except when cancelling).
- **If you reach for `8`, stop and split.** An 8-point ticket is almost always two or three smaller tickets in disguise — splitting up front beats partial-delivery rejection cycles later.

```sh
jus api PATCH /workspaces/{ws}/tickets/{id} '{"ticket":{"points":2}}'
```

## Ticket Types

The `ticket_type` field controls which icon renders on the board and signals intent to the stakeholder.

| Type | API value | Icon | Meaning |
| --- | --- | --- | --- |
| Feature | `feature` | ★ | New functionality or enhancement to existing behavior |
| Bug | `bug` | ● | Something that worked before is now broken |
| Chore | `chore` | ⚙ | Maintenance, refactoring, config, CI — no user-visible behavior change |
| Research | `research` | ⚗ | Investigation, analysis, answering questions — deliverable is description content, not code |

### Choosing the right type

Top to bottom — pick the first that fits:

1. **Deliverable is findings, not code** → `research`
2. **Deliverable is invisible to users** (deps, config, CI, internal cleanup) → `chore`
3. **Something used to work and now doesn't** → `bug`
4. **Adds or changes user-visible behavior** → `feature`
5. **It's a timeline marker on the board, not work** → `milestone`, `release`, or `deadline`

Common miscalibrations to avoid: "document how X works" → `research`, not `chore`; "refactor without behavior change" → `chore`, not `feature`; "restore behavior that regressed" → `bug`, not `feature`; "change existing behavior in a user-visible way" → `feature`, not `chore` (even if small).

### Marker types (timeline, not work items)

Markers render as horizontal bars on the board, not cards. They are timeline-planning artifacts and are excluded from API responses by default — pass `include_markers=true` to include them when listing.

| Type | API value | Icon | Use for |
| --- | --- | --- | --- |
| Milestone | `milestone` | ◆ | Significant project checkpoint or goal |
| Release | `release` | ⚑ | Version cut or deployment boundary |
| Deadline | `deadline` | ⚑ | Hard date constraint (renders red) |

**Marker titles name the thing itself** — the vehicle + payload for a release, the checkpoint for a milestone. No "Pending …" or type-word prefixes ("Release:", "Milestone:") and no leading icon characters: the board renders every marker with its type icon (and a type-colored bar), so a prefixed or icon-led title states the type twice.

## Ticket Metadata

| Field | Default / convention |
| --- | --- |
| `requester_id` | **Auto-set** to `current_user` by the API — not settable. The agent that creates the ticket is the requester. |
| `stakeholder_id` | **Set to the workspace owner's user ID** for all tickets. Look it up once per workspace rather than hardcoding it. |
| `assignee_ids` | Set to your agent user ID when you are doing the coding. **Mixed-actor tickets (some steps only the stakeholder can perform): assign BOTH** — and give each subtask its own `assignee_id` (see [Subtasks](#subtasks--a-tickets-checklist)). **Omit or leave empty** when creating tickets you won't immediately work on — let the stakeholder assign. |
| `description` | **Append-only.** Fetch first; if non-null, prepend existing content + `\n\n---\n\n` before your additions. See [`hard-rules`](#related-skills). |
| `points` | Required for features to leave icebox. Valid values: `0, 1, 2, 3, 5, 8`. See [Estimation](#estimation). |
| `ticket_type` | One of `feature`, `bug`, `chore`, `research` (or marker types). See [Ticket Types](#ticket-types). |
| `label_ids` | Array of integers, 1–3 entries. See [Label conventions](#label-conventions). |
| `project_id` | Scope a ticket under a project when one applies — improves board organization and unlocks project-level rollups. |
| `panel` / `state` / `position` / `insert_at` | The placement, honoured on create since 2026-08. See [Placing a ticket on create](#placing-a-ticket-on-create); `bulk_create` takes only the first two. |
| `comments_count` | Counter-cached integer. Check before fetching comments. |
| `blocked` / `active_dependencies_count` | If `true` / `> 0`, fetch dependencies before deciding to start. |

### Creating a ticket with full metadata

```sh
jus api POST /workspaces/1/tickets '{
  "ticket": {
    "title": "Short imperative title",
    "description": "What and why, with acceptance criteria.",
    "ticket_type": "feature",
    "points": 2,
    "stakeholder_id": 1,
    "assignee_ids": [2],
    "label_ids": [1, 5],
    "project_id": 103,
    "panel": "backlog",
    "insert_at": "bottom"
  }
}'
```

`panel` and `insert_at` are the placement, and they belong in this call rather than a follow-up — see [Placing a ticket on create](#placing-a-ticket-on-create). Omit both and the ticket lands at the bottom of the **icebox**.

## `jus` CLI & API Reference

The `jus` CLI wraps curl with auth, the `/api/v1` prefix, and jq formatting. Flags: `--raw` (no jq), `-v` (verbose). Token comes from `JUSCRIBE_API_TOKEN` or `.jus/config/api_token.txt`. Installed via Homebrew (`brew install juscribe/tap/jus`) and symlinked at `bin/jus` in this repo. **Output:** the `HTTP <status>` line goes to **stderr**; **stdout is pure JSON** — pipe stdout straight to a parser (`jus api GET '...' | jq .`). Never `2>&1`: it merges the status line into the body and breaks the parse. **Response shape:** bodies are wrapped under a top-level key — a single resource under `.ticket` / `.project`, lists under `.tickets` (with a sibling `.pagination`), `.comments`, etc. Parse `.ticket`/`.project`/`.tickets`, not the JSON root. `include_comments=true` inlines comments on a single **ticket** (`.ticket.comments`) but **not on a project** — fetch those from `jus api GET '/workspaces/{ws}/projects/{id}/comments'` (`.comments`). **Errors:** every mutating body must be wrapped under its resource key — `{"comment":{"body":"..."}}`, not `{"comment":"..."}` and not `{"body":"..."}` for anything you build by hand. A wrong shape is a **400** whose `.error` names the key. **Check the exit code, not just the body:** `jus api` exits **non-zero on any non-2xx** (since v0.6.11), and the error body is still valid JSON on stdout — so `| jq` succeeds on a failure too. A 404 body is only `{"error":"Not found"}` with no status field, so there is nothing in the JSON to key on; use `if ! jus api ...` or `set -e`.

- **Use `jus api` instead of `curl`** — manual curl loses auth and pretty-printing.
- **Avoid a direct console or ORM script for data work** — it bypasses controllers, broadcasts and activity logging, so changes won't show live and won't generate an audit trail. Go through the API.
- **Never fetch full ticket lists at session start** — use `agent_state` for orientation; fetch individual tickets on demand.
- **Combine efficiency tools** — sparse fieldsets, opt-out params, and `agent_state` stack; use them together. Every byte returned costs tokens.

### HTTP method patterns & subcommands

```sh
jus api GET '/workspaces/{ws}/tickets/{id}'
jus api POST /workspaces/{ws}/tickets '{"ticket":{"title":"..."}}'   # inline JSON
jus api POST /workspaces/{ws}/tickets @.jus/tmp/ticket.json          # file body (@ prefix)
jus api POST /workspaces/{ws}/tickets <<'EOF'                        # heredoc (stdin auto-detected)
{"ticket": {"title": "New ticket", "description": "Multi-line\ndescription here"}}
EOF
jus api PATCH /workspaces/{ws}/tickets/{id} '{"ticket":{"points":2}}'
jus api DELETE /workspaces/{ws}/dependencies/{dep_id}

jus download <attachment-url-path> .jus/tmp/screenshot.png                      # attachment from a ticket
jus init      # first-time setup (token + workspace + symlink)
jus login     # authenticate with API token
jus whoami    # show authenticated user
jus cleanup   # remove all files from .jus/tmp/
jus version   # the CLI version — what the server sees in the X-Jus-Version header
jus switch    # change which AI coding CLI runs dispatched work (multi-LLM accounts)
jus station init | auth | start | logs     # manage the local dispatch station
```

#### Three things `jus api` does to your call

Worth knowing because each is invisible in the response, and one of them can send a body you did not write.

- **`{ws}` is substituted for you.** `jus init` stores the workspace id and `jus api` replaces a literal `{ws}` in the path with it — so every path in this skill is copy-pastable as written. With no workspace configured the call stops and names `jus init`; it never requests the literal.
- **The `/api/v1` prefix is added only when the path does not already start with `/api/`.** So a path you write in full reaches whatever namespace it names, unprefixed.
- ⚠️ **A malformed JSON body is auto-repaired, and only stderr says so.** When the shell has eaten quotes or truncated the body, `jus api` tries several recoveries, prints `Warning: Body was not valid JSON — auto-repaired.` and sends the repaired version. It is a rescue for a mangled call, not a licence to build bodies loosely — the repair may not be what you meant, and the request succeeds either way. Pass anything you did not type by hand through `@file` or a quoted heredoc, and read stderr.

### Request-shape gotchas

Five behaviours that present as a hang, a no-op, a bare 500, or a silent success rather than an error. Each is listed by the **symptom you will actually be looking at**.

- **The command hangs and never returns** → you ran `jus api PATCH <path>` with **no body argument**. It does not error and does not default to `{}` — it waits on stdin forever. Body-less endpoints still need an explicit empty object: `jus api PATCH /workspaces/{ws}/dependencies/{id}/resolve '{}'`.
- **A newly created ticket is in the wrong panel, or at the wrong end of it** → you named no placement, and the default is the **bottom of the icebox** — not the panel you were looking at. Create takes `panel`, `state`, `position` and `insert_at` and honours all four; see [Placing a ticket on create](#placing-a-ticket-on-create). ⚠️ The recipe this bullet used to give — create, then `/reorder` — is a wasted call, and the claim it rested on (`position` silently ignored) stopped being true.
- **A transition is rejected as invalid** → `/transition` walks the state machine **one state at a time**. `unprioritized` straight to `started` is a 422, not a shortcut; go through `prioritized`. The error names the valid next states, so read it rather than guessing again.
- **A transition returns a body of nulls and nothing changes** → you tried to move a ticket **backwards**, e.g. `prioritized` → `unprioritized` when parking work back to the icebox. `/transition` only walks the state machine forwards. Use a direct field update instead: `PATCH /workspaces/{ws}/tickets/{id} '{"ticket":{"state":"unprioritized"}}'`. Forward moves keep using `/transition`.
- **A create returns a bare `HTTP 500` with `"Internal Server Error"` and nothing else** → check the **case** of an enum value. `ticket_type` is lowercase (`feature`, `bug`, `chore`, `milestone`, `release`, `deadline`, `research`); passing `"Release"` raises `ArgumentError` inside the model and surfaces as a 500 that names no field. Any enum-backed attribute fails the same way, so a 500 on an otherwise well-formed create is a casing bug until proven otherwise — not a server fault to retry.
- **You set `assignee_ids` / `label_ids` / `stakeholder_id` and the response shows `null`** → the write **succeeded**. `*_ids` fields do not echo back; the response carries the expanded `assignees` / `labels` / `stakeholder` objects instead. Verify against those, not the `*_ids` key, or you will retry a write that already landed.

### Placing a ticket on create

**`POST /tickets` takes the placement with the create — which panel, and where inside it.** One call, not two. Before 2026-08 `position` and `panel` were permitted and then discarded, so a `201` came back having ignored both; that is no longer the behaviour and the recipe built around it is a wasted call.

| Key | Accepts | Effect |
| --- | --- | --- |
| `panel` | `icebox` / `backlog` / `current` / `done` | The list to arrive in. The panel's **entry state** follows — `unprioritized`, `prioritized`, `started`, `accepted` respectively |
| `state` | any state name | Sets the panel too, since each state belongs to exactly one |
| `position` | a number | The exact position |
| `insert_at` | `top` / `bottom` / `before:<id>` / `after:<id>` | The position computed server-side, relative to the panel or to a neighbouring ticket |

```sh
jus api POST /workspaces/{ws}/tickets '{"ticket":{"title":"…","panel":"backlog","insert_at":"top"}}'
jus api POST /workspaces/{ws}/tickets '{"ticket":{"title":"…","insert_at":"after:2772"}}'
```

**The defaults are the part worth knowing.** With no placement named at all a ticket lands at the **bottom of the icebox** — `insert_at` defaults to `bottom`, and the panel to `icebox`. An anchor overrides that panel default: `insert_at: "after:<id>"` on its own places the ticket in whichever panel that ticket is already in.

**Contradictions are refused, never settled by precedence.** Each of these is a `422` whose `error` names what disagreed, because a silent winner is the defect this replaced:

- `position` and `insert_at` in the same request — they are alternatives, so give one.
- `state` and `panel` naming different panels.
- `before:<id>` / `after:<id>` naming a ticket in a different panel than the one requested, one that is not in the workspace, or one that has no position of its own.
- `position` or `insert_at` against the `done` panel, which is ordered by completion and reassigns positions on arrival. A `done` create with **no** placement is fine.
- An unrecognised `state`, `panel` or `insert_at` directive — a bare `after:` with no id gets its own message, because that is a lost id rather than a typo.

⚠️ **`insert_at` is a directive, not a stored attribute, so it does not echo back.** Read the resulting `position` and `panel` instead — the same shape as the `*_ids` gotcha above, where nothing coming back does not mean nothing happened.

**Moving an EXISTING ticket is still its own call**, and `/reorder` is the one to use:

```sh
jus api PATCH /workspaces/{ws}/tickets/{id}/reorder '{"position": 4.5}'
```

⚠️ Note the bare body — `/reorder` reads `position` at the top level, **not** wrapped in `{"ticket": {…}}`. A plain `PATCH …/tickets/{id}` with a `position` does write the column (measured), but it broadcasts `ticket_updated` rather than `ticket_reordered`, so open boards do not move the card.

### Bulk endpoints

Five collection endpoints act on many tickets in one request, each taking a `tickets` array. Reach for them before writing a `PATCH` loop — one measured sweep relabelled 148 tickets in 6 requests instead of 148.

| Endpoint | Body | Returns |
| --- | --- | --- |
| `POST …/tickets/bulk_create` | full ticket attributes per item | `results` — one entry per item |
| `PATCH …/tickets/bulk_update` | `id` plus attributes: `label_ids`, `assignee_ids`, points, `panel`/`state` | `results` — one entry per item |
| `PATCH …/tickets/bulk_transition` | `id` and `state`, validated against the state machine per item | `results` — one entry per item |
| `PATCH …/tickets/bulk_reorder` | `id` and `position` per item | `results` of `{id, position}` — **one transaction** |
| `PATCH …/tickets/bulk_sidebar_reorder` | `id` and `sidebar_position` / `bookmarks_position` | `204`, no body |

```sh
jus api PATCH /workspaces/{ws}/tickets/bulk_update '{"tickets":[{"id":"101","points":2},{"id":"102","points":3}]}'
```

**A failed item fails alone.** The first three return `HTTP 200` whatever happened inside, with `{"success": true, "ticket": {…}}` or `{"success": false, "errors": [...]}` per entry — so the status line tells you nothing and **the `results` array is what you check**. A ticket id that does not exist is one failed entry, not a failed request.

**`bulk_reorder` is the exception, deliberately.** It runs in one transaction and a bad entry rolls the whole move back, because a half-reordered board is worse than an unmoved one.

#### `bulk_create` refuses `position` and `insert_at` — and that is not a limitation to route around

Single create honours both (above); `bulk_create` rejects the item that carries either. The contract of a batch is "create these, **in this order**", and per-item placement contradicts it: two items both asking for the `top` come out in the reverse of the order they were sent, while `bottom` preserves it — the same directive family splitting on order with nothing in the response to say which happened. Two items naming the same `position` simply collide.

`panel` and `state` **are** honoured per item, so a batch can be created straight into the backlog. Ordering within it is the second call:

```sh
jus api POST /workspaces/{ws}/tickets/bulk_create '{"tickets":[{"title":"first","panel":"backlog"},{"title":"second","panel":"backlog"}]}'
jus api PATCH /workspaces/{ws}/tickets/bulk_reorder '{"tickets":[{"id":"101","position":12.25},{"id":"102","position":12.5}]}'
```

⚠️ `bulk_reorder` writes the positions you give it verbatim — it computes no gaps. Read the neighbours you are landing between (`?fields=id,position`) and pick values in the gap, as the second call above does.

**`bulk_create` then `bulk_reorder` is two calls by design, not a workaround** — and `bulk_reorder` exists precisely so the second one is not a loop. Items are appended to their panel in request order, so a batch that only needs to be contiguous at the bottom needs no second call at all.

### Efficiency toolkit

- **Agent state (preferred for session start)**: `agent_state?panels=current,backlog` returns ~2–4 KB markdown; `summary?panels=...` is the structured-JSON variant. Cache TTL 5 minutes; invalidated on ticket/project changes. Never start a session by listing all tickets.
- **Sparse fieldsets**: `?fields=id,title,state,points` — pick exactly what you need (`id` always included).
- ⚠️ **`labels` is an array of STRINGS; `label_objects` is the array of objects.** It is the only association on a ticket that is not objects, so `.ticket.labels[].name` fails with `Cannot index string with string "name"` — and a fetch passing `include_label_objects=false` leaves the string array as the only one there.
- **Opt-out params**: `include_markers` (default `false`), `include_label_objects` (default `true`; `false` omits the array — string `labels` always present), `include_attachments` (default `false`), `include_comments` (default `false`), `include_subtasks` (default `false`), `comments_limit` (caps to N most recent).
- **`comments_count`**: every ticket response carries it — check before fetching comments; if `0`, skip `include_comments` entirely.

| Task | Approach |
| --- | --- |
| Session start | `agent_state?panels=current,backlog` |
| Fetch a ticket to work on | `tickets/{id}?include_comments=true&include_attachments=true&include_label_objects=false` |
| Bulk state check across panel | `tickets?fields=id,title,state&panel=current` |
| Everything with a label | `tickets?label=security&fields=id,title,state` — one request, not a paging loop |
| Project ticket list | `projects/{id}/tickets?fields=id,title,state,points` |
| Create / update / transition | Normal endpoints — write paths return full data |

### Index filter params

The ticket index takes a substantial filter set, and **nothing rejects a name it does not recognise, and nothing logs it either** — the index never puts the query string through strong parameters, so there is no `Unpermitted parameter` line to go looking for. A misspelled filter returns the unfiltered list with `HTTP 200`, which reads exactly like a filter that matched everything. Check `.pagination.count` against what you expected.

⚠️ **This is why "the tickets API has no text search" circulates as lore.** `query=` and `search=` are silently ignored because neither is the param name. **`q` works** — a case-insensitive substring match on title _or_ description.

| Param | Notes |
| --- | --- |
| `q` | Substring match (`ILIKE`) on title or description |
| `label` | Matches either label representation — see below |
| `panel` | `icebox` / `backlog` / `current` / `done` |
| `state` | Exact state name |
| `ticket_type` | Naming a marker type overrides the `include_markers` default |
| `project_id` | The project's **external** ID, not its database ID. ⚠️ An unknown one does **not** return `[]` — it matches every ticket with NO project |
| `iteration_id` | Iteration external ID, or `none` for unassigned. ⚠️ An unknown one **404s** the whole request |
| `external_id` | The `#N` you see on the board |
| `requester_id` / `stakeholder_id` / `assignee_id` | User ID |
| `team_id` | Assignee, unassigned requester, or stakeholder is on the team |
| `points_gt` / `points_lt` | Strict, and exclusive of the bound. Non-numeric input reads as `0` |
| `created_after` / `_before` | Inclusive timestamps |
| `updated_since` | Strictly after — for polling what changed |
| `page` / `per_page` | Default 50, max 200. The envelope key is `count`, **not** `total_count` |

Filters combine with `AND`, so one request usually replaces a paging loop:

```sh
jus api GET '/workspaces/{ws}/tickets?label=security&panel=backlog&fields=id,title,state'
```

⚠️ **`label` matches two representations, and only one of them renders.** A ticket carries labels twice: the `ticket_labels` join (serialized as `label_objects`, and what the board draws as badges) and a legacy string mirror on the ticket itself. The filter unions both, so it never under-returns — but a name living only in the mirror **shows no badge on the card**, has no `Label` record, and will never colour or appear in the label picker. Labelling still goes through `label_ids`, which writes both representations. `jus api GET '/workspaces/{ws}/labels'` is the vocabulary; a name outside it is history, not a label.

## Subtasks — a ticket's checklist

A ticket carries an ordered checklist of its own. Each item has a **title, an optional description, an optional single assignee**, a `completed` flag and a `position` — so the steps of a multi-step ticket are data the board can render and count, rather than lines in the description that nothing can query.

They are not returned by default. `subtasks_count` is on every ticket payload; `include_subtasks=true` inlines them, or fetch the collection.

```sh
jus api GET '/workspaces/{ws}/tickets/{id}/subtasks'
jus api POST /workspaces/{ws}/tickets/{id}/subtasks '{"subtask":{"title":"…","description":"…","assignee_id":2}}'
jus api PATCH /workspaces/{ws}/tickets/{id}/subtasks/{subtask_id} '{"subtask":{"title":"…","completed":true}}'
jus api PATCH /workspaces/{ws}/tickets/{id}/subtasks/{subtask_id}/reorder '{"position":2.5}'
jus api DELETE /workspaces/{ws}/tickets/{id}/subtasks/{subtask_id}
```

Writable: `title` (required), `description`, `completed`, `position`, `assignee_id`. `position` defaults to the end of the list, and `created_by` is the caller. The response expands `assignee` and `created_by` as user objects rather than bare ids, the way a ticket expands its own.

⚠️ **`assignee_id` must be a member of the workspace's organization** — anyone else is a `422` reading `must belong to this workspace`. Send `null` or `""` to clear it.

⚠️ **`completed` IS HOW YOU TICK A STEP — there is a `/toggle` endpoint, and it is not it.**

`PATCH …/subtasks/{subtask_id}` with `{"subtask":{"completed":true}}` sets the state you asked for, and setting it to the value it already holds is a no-op answering `200`. `PATCH …/subtasks/{subtask_id}/toggle` **flips whatever it finds** (`completed: !completed`), so it is right only when you already know the current state — and a ticket is a surface a person writes to as well. An agent "ticking" a step the stakeholder ticked already silently **un**ticks it, and both calls answer `200` with a subtask in the body, so nothing distinguishes them. Measured: three steps a stakeholder had checked off from their phone, turned back off by an agent recording its own work.

Both paths broadcast the same `subtask_updated`, so the explicit form costs nothing. Reach for `/toggle` only when flipping the current state is genuinely the intent — a person clicking a checkbox, which is what the web and mobile clients do.

⚠️ **Comment and ticket REACTION toggles are a DIFFERENT endpoint and are correct as toggles.** `POST …/comments/{id}/reactions/toggle '{"emoji":"👍"}'` adds or removes _your own_ reaction, which is exactly the intent, and there is no desired-state form. Do not "fix" those.

⚠️ **Two shape traps in those five lines, both of them silent:**

- **`/reorder` reads `position` at the top level**, not wrapped in `{"subtask": …}` — the same bare shape as a ticket's own `/reorder`.
- **`{subtask_id}` is a plain row id, not an `#N`.** The ticket segment of that URL _is_ an external id, so one path carries two kinds of id that look alike. Take the subtask's `id` from the response; never assume it reads like a ticket reference.

**A subtask is not a small ticket.** It has no state machine, no points, no labels, no comments and no dependencies. Reach for one when the steps only make sense together and none is separately deliverable; file a second ticket otherwise.

⚠️ **STEPS SOMEONE PERFORMS BELONG HERE, NOT IN THE DESCRIPTION.** A runbook, a migration sequence, a mixed-actor procedure: the board can render, count, order, assign and broadcast a subtask, and the stakeholder can tick one off from their phone. A `- [ ]` line does none of that, and only an agent rewriting the whole description can ever change one — exactly backwards when the steps are the stakeholder's to run. The actor is the `assignee_id`, not an `**[Actor]**` tag in the text.

⚠️ **THE COMMAND GOES IN THE `description`, NOT THE `title`.** The board truncates a subtask title, so one long enough to hold a real command is ellipsised and cannot be copied. Title: `N. ` plus a short imperative label. Description: the fenced command, then the commentary. **One bare command per fence**, copy-pastable as-is — no `#` comment on the command line, and never several steps sharing one fence, because copying a step then drags the commentary with it.

⚠️ **The `N. ` stays in the title.** Neither surface renders an ordinal, so it is the only way anything else can point at a specific step.

**What stays a description checkbox: acceptance criteria.** They are claims about whether the ticket is _done_, not things someone performs, and they are what the stakeholder re-reads at acceptance. If you cannot tell which you are writing, ask whether a person could be **assigned** it — a step has an actor, a criterion does not.

## Dependency Handling Protocol

When a ticket has `blocked: true` or `active_dependencies_count > 0`, fetch `GET .../dependencies` and evaluate each blocker:

| Blocker state | Action |
| --- | --- |
| `accepted` / `cancelled` | Stale — resolve manually, comment, proceed |
| `delivered` / `finished` | Proceed (note in start comment) |
| `started` + assigned to another agent | **Skip** — comment "Blocked by #N", move on |
| `started` + unassigned | Pick up if small (≤2pt, same project), otherwise skip + flag |
| `prioritized` / `unprioritized` | **Skip** — prerequisite hasn't started, flag to stakeholder |
| `External` | Check description; resolve if met, otherwise skip + ask |

**A date on the blocker answers _when_, and the table above only answers _whether_.** Read `earliest_blocker_due_on` / `earliest_blocker_due_kind` off the ticket before deciding — a `wait_until` still in the future is a hard stop whatever the blocker's own state says, while an `expected_by` is a forecast you may work alongside. The three kinds are in [Blocker dates](#blocker-dates) below.

In batch work: skip blocked tickets (don't transition to `started`), post a comment, continue in position order. Respect dependency order over position order (topological sort).

### Dependencies API

```sh
# List — what blocks a ticket, and what it blocks (same shape on projects: substitute projects/{id})
jus api GET '/workspaces/{ws}/tickets/{id}/dependencies'
jus api GET '/workspaces/{ws}/tickets/{id}/dependencies/blocks'

# Create — Ticket, Project, or External blocker
jus api POST /workspaces/{ws}/tickets/874/dependencies \
  '{"dependency":{"blocker_type":"Ticket","blocker_id":809,"blocked_type":"Ticket","blocked_id":874}}'
jus api POST /workspaces/{ws}/tickets/100/dependencies \
  '{"dependency":{"blocker_type":"External","blocked_type":"Ticket","blocked_id":100,"description":"Waiting on DNS propagation"}}'

# Resolve (preserves history) / Delete (only for deps created in error) — both workspace-level
jus api PATCH /workspaces/{ws}/dependencies/{dep_id}/resolve
jus api DELETE /workspaces/{ws}/dependencies/{dep_id}
```

Constraints: valid `blocker_type` = `Ticket` / `Project` / `External`; valid `blocked_type` = `Ticket` / `Project`; External blockers require a `description` (no `blocker_id` to point at); all entities must belong to the same workspace.

**Both sides can be a project**, and the same endpoints hang off `projects/{id}` — so `Project` → `Ticket`, `Ticket` → `Project` and `Project` → `Project` are all expressible. A whole project waiting on one ticket is a `Project` blocked by a `Ticket`, not an External blocker describing it in prose.

**Recording it from the blocker's side.** `POST /tickets/{id}/dependencies` reads as "this ticket is blocked by …". Add `"direction":"blocks"` and the ticket you posted to becomes the **blocker**, with `blocked_type` / `blocked_id` naming what it holds up — the natural shape when you have just finished something and know what it unblocks:

```sh
jus api POST /workspaces/{ws}/tickets/809/dependencies \
  '{"dependency":{"direction":"blocks","blocked_type":"Ticket","blocked_id":874}}'
```

### Blocker dates

A blocker can carry a date, and the date carries a **kind**, because the same calendar day means three different things and only the kind distinguishes them.

| `due_kind` | Reads as | What it means when you are deciding whether to pick the ticket up |
| --- | --- | --- |
| `wait_until` | "Blocked until" | Do not start before this date. A hard stop |
| `review_on` | "Review on" | Revisit and decide on this date. Not a stop |
| `expected_by` | "Expected by" | When the blocker is forecast to clear. Informational |

`due_on` (`YYYY-MM-DD`) and `due_kind` can be set on create, or afterwards:

```sh
jus api POST /workspaces/{ws}/tickets/100/dependencies \
  '{"dependency":{"blocker_type":"External","blocked_type":"Ticket","blocked_id":100,"description":"Vendor countersignature","due_on":"2026-11-30","due_kind":"expected_by"}}'

jus api PATCH /workspaces/{ws}/dependencies/{dep_id} '{"dependency":{"due_on":"2026-11-30","due_kind":"wait_until"}}'
jus api PATCH /workspaces/{ws}/dependencies/{dep_id} '{"dependency":{"due_on":null,"due_kind":null}}'   # clear both
```

⚠️ **Neither half works alone.** A date with no kind cannot be worded and a kind with no date says nothing, so each without the other is a `422`. Both absent is fine and is the common case. Clearing them means sending both as `null`.

⚠️ **`due_on` and `due_kind` are the ONLY editable fields on a dependency.** The update endpoint permits nothing else, so a `blocker_id` in the body is dropped rather than repointing the row — and it answers `200`, having changed only the date. **Repointing a blocker is a delete plus a create**, because a different blocker is a different dependency.

**Reading a date back.** Every ticket and project payload carries the soonest one as a scalar pair, `earliest_blocker_due_on` / `earliest_blocker_due_kind`, alongside the per-blocker `due_on` / `due_kind` inside `active_dependencies_summary`. Read the pair to decide; read the summary to say which blocker it was.

### Creating dependencies

- **During investigation** — if you discover untracked prerequisites, create via `POST .../dependencies` + comment. Hard block → leave started + move on. Soft dependency → proceed but create the link for documentation.
- **During ticket creation** — convert prose prerequisites ("requires #N") into formal `Ticket→Ticket` dependencies.
- **For user input** — create an `External` dependency with description `"User input: <what you need>"` whenever you cannot proceed without stakeholder input. This makes the block visible on the board. Posting a comment alone is not enough.

### Resolving and post-delivery

- **Auto-resolve** fires when a blocker reaches `accepted`/`cancelled`. No manual action needed.
- **Manual resolve** (`PATCH .../resolve`) — for external blockers or when auto-resolve missed.
- **Delete** (`DELETE .../dependencies/{id}`) — only for dependencies created in error.
- **After delivering** — check `GET .../dependencies/blocks` and mention any unblocked tickets in the delivery comment. Don't auto-start them unless they're next in your batch queue.
- **Stale hygiene** — during session orientation, resolve any dependencies whose blockers are already in a terminal state.

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

## Converting a ticket

**A research ticket whose finding is a multi-ticket design is a project wearing a ticket's clothes.** The signal is concrete: you are about to write acceptance criteria that decompose into separate deliverables with their own dependencies.

⚠️ **Only a `research` ticket can be converted.** Anything else that has outgrown its type is a **retype** — `PATCH …/tickets/{id} '{"ticket":{"ticket_type":"chore"}}'` — because a feature that grew was always a feature. Conversion exists to preserve a finished investigation and link it to the work it recommends, which is a thing only research has.

There is a dedicated endpoint. **Do not cancel the ticket and hand-create a project** — that is the natural workaround if you do not know this exists, and it throws away the description, the requester, the stakeholder, and the link back.

```sh
jus api POST /workspaces/{ws}/tickets/{id}/convert '{}'
```

⚠️ **The body is required.** A body-less `POST`/`PATCH` hangs waiting on stdin rather than defaulting to `{}`.

What it does, in one transaction:

|  |  |
| --- | --- |
| Creates a project | carrying the ticket's **title, description, requester and stakeholder** |
| Sets `source_ticket_id` | so the project records where it came from |
| Transitions the ticket to **`converted`** | and clears its `project_id` |
| Records activities on both | and broadcasts `project_created` |

It returns `{ticket, project}`, so the new project's id comes back in the same call.

**It refuses** with a `422` and a message rather than failing silently, in the order the checks fire:

1. The ticket is already `converted`.
2. It is `cancelled` — a terminal state cannot become a project.
3. **It is not a `research` ticket** — `only a research ticket can be converted; this one is a feature`.

⚠️ The source-type check runs **ahead of** the target checks below, deliberately: a feature asking to become a feature is wrong for a more fundamental reason than whatever it named as a target, and hearing about `ticket_type` first sends you to fix the wrong parameter.

**After converting**, populate the project: create the child tickets with `project_id` set and their placement in the same call — `panel` plus `position` or `insert_at`, see [Placing a ticket on create](#placing-a-ticket-on-create). For a whole set, `bulk_create` then `bulk_reorder`.

### Converting into a ticket instead

The same endpoint takes an optional `target`. Absent or `"project"` is the behaviour above; `"ticket"` creates one new ticket of a type you choose.

```sh
jus api POST /workspaces/{ws}/tickets/{id}/convert '{"target":"ticket","ticket_type":"feature"}'
```

Reach for it when a research ticket's finding is **one piece of work** rather than a decomposable design — a one-ticket project is the wrong shape for that.

The new ticket carries **title, description, requester, stakeholder, project and labels**, and lands at the **top of the icebox**, `unprioritized`. It does **not** carry points: a research estimate says nothing about the size of the work it recommends, so estimate it yourself before prioritising. Returns `{ticket, converted_ticket}` — the source serializes `converted_ticket_id`, the new one `source_ticket_id`. Unlike the project path, the source **keeps** its `project_id`.

⚠️ **`ticket_type` is required here, and a marker type is refused.** `feature`, `bug`, `chore` and `research` are the choices; `milestone`, `release` and `deadline` are dates on the timeline rather than work, so converting a finding into one loses the finding instead of scheduling it. A missing, unknown or marker `ticket_type` is a `422` naming the field.

```sh
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"started"}'
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"finished"}'
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"delivered"}'
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"cancelled","resolution":"duplicate"}'
```

> **NEVER transition to `accepted` or `rejected`** — only the stakeholder decides.

## Related Skills

- `hard-rules` — the non-negotiable must/must-not that overrides everything here (commit immediately, no lint suppression, stakeholder-verbatim descriptions, never deliver incomplete work, no `git push`, document discoveries) and the map of which rules the enforcement hooks back deterministically on harnesses that run them. (Claude Code plugin installs show skill names prefixed with `jus:` — invoke the prefixed form there.)

> **Note:** `ticket-workflow` is the single load-bearing SOP skill — it inlines the estimation, labeling, testing-gate, and `jus` API material that earlier lived in the separate `testing-gates`, `juscribe-api`, and `estimation-labels` skills (retired because they never auto-invoked; their content was already resident here). For monumental, the deeper extracted reference also lives in `.jus/sop/` (`api-reference.md`, `workflows.md`, `commands.md`) and `.jus/docs/`.
