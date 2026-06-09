---
name: ticket-workflow
description: The single load-bearing Juscribe SOP skill — the full ticket lifecycle from pickup to delivery PLUS estimation, ticket types, labels, metadata, testing gates, and the complete `jus` CLI / API reference. Use when working any ticket — picking one up, transitioning state, investigating, sizing, labeling, writing tests, running pre-commit gates, calling `jus api`, committing, self-reviewing, finishing, delivering, handling rejections, processing batches, or resolving dependency blockers. Auto-invoke whenever a ticket ID (`#N`) or "work on this ticket" / "pick up backlog" / "deliver" / "rejected" appears.
allowed-tools: Bash(jus *), Bash(git *), Bash(bin/rspec*), Bash(bin/rubocop*), Bash(bin/reek*), Bash(bin/diff-cover*), Bash(bin/with-rbenv*), Bash(bin/ci*), Bash(pnpm *), Bash(go *), Bash(golangci-lint *), Bash(make *), Bash(cd *), Read, Grep, Glob, Edit, Write
---

# Ticket Workflow — Juscribe Lifecycle SOP

> Read this when working any ticket. This is the **single load-bearing skill** for Juscribe work: it defines the full lifecycle (session start → pickup → investigate → label → code → commit → self-review → finish → deliver), the batch-work rules, the dependency-blocker protocol, **and** the operational reference an agent needs along the way — estimation, ticket types, labels, metadata, the testing gates, and the `jus` CLI / API. The companion [`hard-rules`](#related-skills) skill carries the non-negotiable must/must-not; the plugin hooks enforce the most painful of those deterministically.

The lifecycle, in one line:

```
(1) create or pick up → (2) start → (3) investigate → (3b) apply labels → (4) code → (5) commit → (6) self-review → (7) finish → (8) deliver
```

Every change goes through every phase, no exceptions for "small" or "ad-hoc" work. Transitions happen at the natural moment, not batched — the board must reflect reality in real time. **NEVER transition to `accepted` or `rejected`** — only the stakeholder decides.

## Phase 0: Prerequisites — the `jus` CLI must be installed and authenticated

This SOP drives the Juscribe board through the **`jus` CLI**. The plugin ships the **skills and hooks only — not the CLI binary**, so before any phase below will work the user needs:

1. **The CLI** — `brew install juscribe/tap/jus` (or the curl installer at `app.juscribe.ai/install.sh`).
2. **Auth + workspace** — `jus login` (API token) or `jus init` (token + workspace + `bin/jus` symlink). `jus init` also sets the `{ws}` used throughout this skill.

**Preflight.** If you're about to run `jus` and aren't sure it's configured, run `jus whoami` first and read the failure:

- `jus: command not found` → the CLI isn't installed. Tell the user to `brew install juscribe/tap/jus`, then stop.
- `Error: No token available. Run 'jus login'…` → installed but unauthenticated. Tell the user to run `jus login` or `jus init`, then stop.

**Do not loop `jus` commands against an unconfigured CLI.** Surface the single setup step the error points to and stop — one clear instruction beats a wall of repeated errors. Everything below assumes this preflight passed.

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

- **Limit codebase exploration to 2–3 direct file reads** for frontend UI tickets. Don't deploy deep exploration agents for straightforward features.
- **Skip deep architecture analysis for familiar domains** — for React/hooks/CSS work, read the target files + 1–2 neighbors. Don't trace the full state-management chain unless the fix requires it.
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

#### Workspace 1 label IDs

| ID | Name | When to apply |
|----|------|---------------|
| 1 | `frontend` | Changes under `app/frontend/` |
| 2 | `backend` | Rails models / controllers / services / migrations |
| 3 | `api` | API contract changes — endpoint, payload shape, authorization |
| 4 | `database` | Schema, migrations, indexes, query performance |
| 5 | `css` | Styling-only changes (Tailwind, `application.css`) |
| 6 | `real-time` | Action Cable channels, broadcasts, Zustand sync |
| 7 | `docs` | Documentation-only — `.jus/docs/`, README, CLAUDE.md |
| 8 | `refactor` | Behavior-preserving restructuring |
| 9 | `regression` | Bug that fixes previously-working behavior |
| 10 | `responsive` | Responsive / breakpoint / mobile-web layout work |
| 11 | `docker` | Dockerfile, compose, container configuration |
| 12 | `branding` | Logo, color, typography, identity |
| 13 | `ui/ux` | Interaction design, flows, behavior — not pure styling |
| 14 | `mobile` | React Native / `mobile/` directory |

To confirm IDs in another workspace, list them: `jus api GET '/workspaces/{ws}/labels'`. **If you need a label that doesn't exist, ask the stakeholder before inventing one** — labels are a controlled vocabulary.

## Phase 4: Coding

### Post the start comment BEFORE the first code edit

The very first thing in Phase 4 — before you edit a single source file — **post a "Starting" comment on the ticket**: the root cause / your read of the problem, the plan, and your TDD intent. This is the earliest stakeholder-facing signal that work began and the record of your plan *before* implementation. It is prompt-only (a soft `jus-start-comment-nudge.sh` nudge reminds you on the first source edit, but nothing hard-blocks it), so it rests on you remembering. Do not skip it; do not fold it into the delivery comment.

```sh
jus api POST /workspaces/{ws}/tickets/{id}/comments '{"comment":{"body":"Starting. <root cause + plan + TDD intent>"}}'
```

### Test-Driven Development

Write tests **first**. The sequence is: investigate → write failing test → implement → verify test passes → lint → COMMIT. Never reverse the test and implementation steps.

- **Bugs**: write a failing test that reproduces the bug BEFORE writing the fix. The commit includes both the test and the fix.
- **Features**: write specs that define the expected behavior BEFORE implementing. Tests double as a clean-interface design pass.
- **Refactors**: ensure existing specs cover the behavior being preserved; add coverage if missing before refactoring.

Do not skip TDD because investigation was long, the fix seems obvious, or you're "just tweaking" something. If you catch yourself writing code before tests, stop and write the test first.

**Every code change MUST include corresponding test coverage** — 100% statement and branch coverage on all new code, no exceptions, even for error handling and edge cases. Existing specs must pass (a green suite is a prerequisite for every commit). Match existing test style — study neighboring spec files for conventions (factory usage, `sign_in`/`sign_out` helpers, the `:unprocessable_content` matcher, etc.).

#### What to test, where

| Layer | Spec location | Coverage target |
|-------|---------------|-----------------|
| API endpoints (`/api/v1/...`) | `spec/requests/api/v1/` | Happy path + validation errors + authorization |
| Mobile API endpoints (`/api/mobile/v1/...`) | `spec/requests/api/mobile/v1/` | Same as v1 — happy path + errors + auth |
| Models | `spec/models/` | Validations, scopes, callbacks, business-logic methods |
| Frontend logic | colocated `*.test.ts(x)` under `app/frontend/` | Hooks, store actions, utility functions, component behavior |
| Mobile logic | colocated `*.test.ts(x)` under `mobile/` | Same as frontend |
| Agent (Go) | `*_test.go` colocated under `station/` | Business logic, race-tested where concurrency matters |

### Description conventions

- **Every ticket must have a description and effort estimate.** A title alone is not sufficient.
- **Append to the stakeholder's existing description, never overwrite it** (protects stakeholder-authored intent — especially a sparse or blank description you're filling in; not a blanket ban on editing your own prior additions). Fetch the ticket BEFORE patching. If `description` is non-null, prepend the existing content + `\n\n---\n\n` separator before your additions. The original — even a one-sentence stakeholder request — is the source of truth.

### Comment conventions

Post comments as you work — at minimum a start comment (see [above](#post-the-start-comment-before-the-first-code-edit), posted before the first code edit) and a delivery comment when finishing. The comment thread should tell the implementation story.

- **Capture user interjections** — if the user sends scope-affecting messages mid-ticket, mirror those notes into the ticket's comment thread.
- **Use `#N` for tickets, `pN` for projects** — autolinks on the board. Never write "ticket 123" or "project 66" in prose.
- **Use References for prerequisites** — when a ticket mentions "requires #752 complete", create formal References via the API so dependencies are tracked, not just described.
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

### Per-area test commands

Use the `bin/` wrappers — Bash sessions don't inherit rbenv, so raw `bundle exec` will fail. The wrappers initialize rbenv automatically.

```sh
# Backend (Rails / RSpec) — SimpleCov runs automatically, no flag needed
bin/rspec                                          # full suite
bin/rspec spec/requests/api/v1/tickets_spec.rb     # single file
bin/rspec spec/requests/api/v1/tickets_spec.rb:42  # single example by line

# Frontend (React / Vitest)
pnpm test                                          # full suite (CI mode)
pnpm exec vitest run path/to/file.test.tsx         # single file
pnpm exec vitest run --coverage                    # with coverage

# Mobile (React Native / Jest)
cd mobile && pnpm test                             # full suite
cd mobile && pnpm test -- --coverage               # with coverage

# Agent (Go / station)
cd station && go test ./...                        # full suite
cd station && go test -race -count=1 ./...          # with race detection
```

### Mandatory post-commit checks

> These checks are the entire point of self-review. Skipping them has shipped broken tests and lint warnings across multiple tickets. **Do not skip.**

1. **Run the full backend suite** if Ruby files changed (`bin/rspec`) — not just files you touched. Tests you didn't write can break from your changes.
2. **Run architectural smell analysis** on ALL modified Ruby files (`bin/reek <file...>`) — fix every warning. Reek catches `TooManyMethods`, `FeatureEnvy`, `DuplicateMethodCall`, and other smells that rubocop misses. Do not defer reek warnings — they accumulate quickly. Genuine false positives → discuss with the stakeholder rather than suppressing silently.
3. **Run rubocop** on ALL modified Ruby files (`bin/rubocop <file...>`) — fix every offense.
4. **Run frontend linters** if `.ts`/`.tsx`/`.css` files changed: `pnpm exec eslint`, `pnpm exec prettier --check`, `pnpm exec tsc --noEmit` (always project-wide).
5. **Run the agent gate** when `station/` files changed: **always use `bin/ci --station`** — it runs the canonical agent CI flow (lint + test + race + coverage). Do NOT call raw `go test` / `golangci-lint` for the gate.

Fix issues in a follow-up commit with the same ticket prefix. Only finish once the code would pass a senior review.

### Diff coverage gate

After lints pass, run diff coverage for every component you touched. This verifies that **all new/changed lines** are exercised — not just that tests pass.

```sh
bin/diff-cover --backend          # Ruby changes
bin/diff-cover --frontend         # app/frontend/ changes
bin/diff-cover --mobile           # mobile/ changes
bin/diff-cover --station          # station/ changes
bin/diff-cover                    # all at once
```

Prerequisite: tests must run with coverage enabled first (`bin/rspec` does this automatically; frontend needs `pnpm exec vitest run --coverage`; mobile needs `cd mobile && pnpm test -- --coverage`; agent uses `cd station && make test-coverage`).

Default threshold: **100%**. Every new/changed line must be covered. If `bin/diff-cover` fails, write the missing tests before finishing. **This is a hard gate** — do not deliver with uncovered lines.

**Coverage strategy for stubborn lines** — analyze case by case: a **reachable** line means write the test that exercises it (don't skip "edge cases" or "error branches" — those are the most likely to break in production); **unreachable / dead code** means refactor the source to eliminate it rather than gaming coverage with `:nocov:` / `/* istanbul ignore */` markers. Do all uncovered lines in one pass; don't accumulate coverage debt across commits.

### Mobile pre-delivery checklist

**Code + passing tests is NOT sufficient for mobile work.** Multiple mobile tickets (#1526, #1535) shipped "delivered" but completely broken because these checks were skipped. **Hard gate.** Before finishing any mobile ticket, run through `.jus/docs/mobile.md` → "Mobile Pre-Delivery Checklist". The four critical checks:

1. **Mobile API namespace exposes every route action your feature uses** — the mobile API is a separate namespace (`/api/mobile/v1/`) from the web API (`/api/v1/`). A route that exists on web does not automatically exist on mobile.
2. **Sparse fieldset constants include every field your UI reads** — mobile responses are aggressively sparse-fielded; missing fields silently return `undefined` at runtime.
3. **`KeyboardAvoidingView` wraps any `TextInput` in modals** — keyboards cover inputs without it.
4. **Request specs under `spec/requests/api/mobile/v1/`** — not just web specs.

Always state in the delivery comment whether the mobile change requires a native rebuild or is JS-only.

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

The "To verify" section with concrete acceptance/rejection steps is **mandatory, not optional — even during batch work.** Every ticket gets its own delivery comment with verification steps. Do not batch or skip.

**Every delivery comment MUST include git information:**

- **Direct commits on main:**
  ```
  **Commit:** `abc1234` on main
  ```sh
  git show abc1234 --stat
  git show abc1234
  ```
  N files changed, X insertions, Y deletions.
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
- **"backlog please" = pick up ALL backlog tickets** — work every ticket in the backlog, in position order. Don't ask for confirmation.
- **Every ticket gets the FULL lifecycle, even in batch mode.** Each gets: start → investigate → code → commit → self-review → **delivery comment with verification steps** → finish → deliver. Do not skip the delivery comment to save time. Do not combine delivery comments across tickets — the stakeholder reviews tickets individually.
- **Do not force-deliver tickets that aren't fully done.** If a batch ticket has questions, blockers, or incomplete work, leave it in `started` with a comment and move to the next. Delivering partial work to "clear the batch" is strictly prohibited.
- **Research ticket workflow** — start the ticket, do the research (web searches, codebase analysis, reading docs), capture findings in the ticket description, then finish and deliver. No code commits needed — the deliverable is the description content itself.

## Estimation

Effort is captured in `points`. **Valid values: `0`, `1`, `2`, `3`, `5`, `8`** — no other values, no half-points.

| Points | Calibration |
|--------|-------------|
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
|------|-----------|------|---------|
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
|------|-----------|------|---------|
| Milestone | `milestone` | ◆ | Significant project checkpoint or goal |
| Release | `release` | ⚑ | Version cut or deployment boundary |
| Deadline | `deadline` | ⚑ | Hard date constraint (renders red) |

## Ticket Metadata

| Field | Default / convention |
|-------|----------------------|
| `requester_id` | **Auto-set** to `current_user` by the API — not settable. The agent that creates the ticket is the requester. |
| `stakeholder_id` | **Set to the workspace owner's user ID** for all tickets. In workspace 1 that's user `1` (Caleon). |
| `assignee_ids` | Set to your agent user ID (`2` for `caleon-claude`) when you are doing the coding. **Omit or leave empty** when creating tickets you won't immediately work on — let the stakeholder assign. |
| `description` | **Append-only.** Fetch first; if non-null, prepend existing content + `\n\n---\n\n` before your additions. See [`hard-rules`](#related-skills). |
| `points` | Required for features to leave icebox. Valid values: `0, 1, 2, 3, 5, 8`. See [Estimation](#estimation). |
| `ticket_type` | One of `feature`, `bug`, `chore`, `research` (or marker types). See [Ticket Types](#ticket-types). |
| `label_ids` | Array of integers, 1–3 entries. See [Label conventions](#label-conventions). |
| `project_id` | Scope a ticket under a project when one applies — improves board organization and unlocks project-level rollups. |
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
    "project_id": 103
  }
}'
```

## `jus` CLI & API Reference

The `jus` CLI wraps curl with auth, the `/api/v1` prefix, and jq formatting. Flags: `--raw` (no jq), `-v` (verbose). Token comes from `JUSCRIBE_API_TOKEN` or `.jus/config/api_token.txt`. Installed via Homebrew (`brew install juscribe/tap/jus`) and symlinked at `bin/jus` in this repo. **Output:** the `HTTP <status>` line goes to **stderr**; **stdout is pure JSON** — pipe stdout straight to a parser (`jus api GET '...' | jq .`). Never `2>&1`: it merges the status line into the body and breaks the parse. **Response shape:** bodies are wrapped under a top-level key — a single resource under `.ticket` / `.project`, lists under `.tickets` (with a sibling `.pagination`), `.comments`, etc. Parse `.ticket`/`.project`/`.tickets`, not the JSON root. `include_comments=true` inlines comments on a single **ticket** (`.ticket.comments`) but **not on a project** — fetch those from `jus api GET '/workspaces/{ws}/projects/{id}/comments'` (`.comments`).

- **Use `jus api` instead of `curl`** — manual curl loses auth and pretty-printing.
- **Avoid `rails runner` for data work** — it bypasses controllers, broadcasts, and activity logging, so changes won't show live and won't generate an audit trail.
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

jus download /rails/active_storage/blobs/redirect/eyJ... .jus/tmp/screenshot.png  # ActiveStorage attachment
jus init      # first-time setup (token + workspace + symlink)
jus login     # authenticate with API token
jus whoami    # show authenticated user
jus cleanup   # remove all files from .jus/tmp/
```

### Efficiency toolkit

- **Agent state (preferred for session start)**: `agent_state?panels=current,backlog` returns ~2–4 KB markdown; `summary?panels=...` is the structured-JSON variant. Cache TTL 5 minutes; invalidated on ticket/project changes. Never start a session by listing all tickets.
- **Sparse fieldsets**: `?fields=id,title,state,points` — pick exactly what you need (`id` always included).
- **Opt-out params**: `include_markers` (default `false`), `include_label_objects` (default `true`; `false` omits the array — string `labels` always present), `include_attachments` (default `false`), `include_comments` (default `false`), `comments_limit` (caps to N most recent).
- **`comments_count`**: every ticket response carries it — check before fetching comments; if `0`, skip `include_comments` entirely.

| Task | Approach |
|------|----------|
| Session start | `agent_state?panels=current,backlog` |
| Fetch a ticket to work on | `tickets/{id}?include_comments=true&include_attachments=true&include_label_objects=false` |
| Bulk state check across panel | `tickets?fields=id,title,state&panel=current` |
| Project ticket list | `projects/{id}/tickets?fields=id,title,state,points` |
| Create / update / transition | Normal endpoints — write paths return full data |

## Dependency Handling Protocol

When a ticket has `blocked: true` or `active_dependencies_count > 0`, fetch `GET .../dependencies` and evaluate each blocker:

| Blocker state | Action |
|---------------|--------|
| `accepted` / `cancelled` | Stale — resolve manually, comment, proceed |
| `delivered` / `finished` | Proceed (note in start comment) |
| `started` + assigned to another agent | **Skip** — comment "Blocked by #N", move on |
| `started` + unassigned | Pick up if small (≤2pt, same project), otherwise skip + flag |
| `prioritized` / `unprioritized` | **Skip** — prerequisite hasn't started, flag to stakeholder |
| `External` | Check description; resolve if met, otherwise skip + ask |

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
Any non-terminal state → cancelled (requires resolution)
```

Valid `cancelled` resolutions (enum — exact values): `duplicate`, `wont_do`, `cant_reproduce`, `obsolete`.

Panel mapping: `unprioritized→icebox`, `prioritized→backlog`, `started/finished/delivered/rejected→current`, `accepted/cancelled→done`.

```sh
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"started"}'
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"finished"}'
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"delivered"}'
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"cancelled","resolution":"duplicate"}'
```

> **NEVER transition to `accepted` or `rejected`** — only the stakeholder decides.

## Related Skills

- `jus:hard-rules` — the non-negotiable must/must-not that overrides everything here (commit immediately, no lint suppression, append-only descriptions, never deliver incomplete work, no `git push`, document discoveries) and the map of which rules the plugin hooks enforce deterministically.

> **Note:** `ticket-workflow` is the single load-bearing SOP skill — it inlines the estimation, labeling, testing-gate, and `jus` API material that earlier lived in the separate `testing-gates`, `juscribe-api`, and `estimation-labels` skills (retired in #1856 because they never auto-invoked; their content was already resident here). For monumental, the deeper extracted reference also lives in `.jus/sop/` (`api-reference.md`, `workflows.md`, `commands.md`) and `.jus/docs/`.
