# Phase 3: Investigation & Labels

Read after the `started` transition, before you read the codebase: how far to investigate, the labels to apply before writing code, the start comment that comes before your first edit, the tests that ship with the change, and how every comment and description is written on the board.

## Contents

- [Investigation guidelines](#investigation-guidelines)
- [Label conventions](#label-conventions)
- [Post the start comment BEFORE the first code edit](#post-the-start-comment-before-the-first-code-edit)
- [Testing](#testing)
- [Description conventions](#description-conventions)
- [Comment conventions](#comment-conventions)

After starting, investigate the codebase. Then apply 1–3 labels before writing code.

## Investigation guidelines

- **Match the exploration to the ticket.** A small, well-understood change wants a couple of direct file reads, not a fan-out of exploration agents. Calibrate "small" to your own codebase.
- **Skip deep architecture analysis for familiar domains** — for routine UI or styling work, read the target files and one or two neighbours. Trace the full state-management chain only when the fix requires it.
- **Time-box investigation to ~3 minutes** for tickets ≤ 2 points. Still reading code after 3 files? Start implementing and adjust as you go.
- **Document what you learn in code comments** — when you decode an animation flow, a state pattern or a WebSocket dance, explain in the source _why_ and how the pieces connect, not the obvious _what_.

## Label conventions

Labels describe **technical areas** — the layers your change touches — not project themes or business intent, which the project grouping already carries.

```sh
jus api PATCH /workspaces/{ws}/tickets/{id} '{"ticket":{"label_ids":[1,2]}}'
```

**MCP:** `update_ticket` with `labels`, by name, which replaces the set.

Guidelines:

- **1–3 labels per ticket** (most are 1–2). More than 3 means the ticket is too large, or the labels repeat what the project already says.
- **Don't duplicate the project grouping.** In a "Mobile redesign" project every ticket already implies `mobile`.
- `docs` — documentation-only tickets. Not for a code ticket that also touches a comment or README.
- `refactor` — restructuring without behavior change. Combine it with `frontend`/`backend` only when the refactor genuinely spans both.
- `regression` — a fix restoring behavior that previously worked. Apply it alongside the area label (e.g. `regression` + `frontend`).

### Finding this workspace's labels

**Label IDs are per-workspace and are not listed here.** Fetch your project's own:

```sh
jus api GET '/workspaces/{ws}/labels'
```

**MCP:** `list_labels`.

**The project should document what each label MEANS**, not just its id, in its own instructions. A label with no _when to apply_ is applied by guesswork, and the cost lands on whoever later filters by it.

**If you need a label that doesn't exist, ask the stakeholder before inventing one.** Labels are a controlled vocabulary, and a near-duplicate is worse than a missing one because it silently splits every future filter.

## Post the start comment BEFORE the first code edit

**Before you edit a single source file, post a "Starting" comment** on the ticket: your read of the problem (the root cause, for a bug), the plan, and how you will test it. It is the stakeholder's first sign that work began, and the record of your plan before implementation. Nothing hard-blocks skipping it — where the jus hooks run, a soft nudge fires on the first source edit — so it rests on you. Do not skip it, and do not fold it into the delivery comment.

```sh
jus api POST /workspaces/{ws}/tickets/{id}/comments '{"comment":{"body":"Starting. <root cause + plan + test intent>"}}'
```

**MCP:** `add_comment`.

## Testing

**Every code change MUST include corresponding tests.** Specifically:

- **Bugs**: a test that reproduces the bug — one that fails before the fix and passes after, shipped in the same commit. A fix with no failing-first test has not been shown to fix anything.
- **Features**: tests that define the expected behaviour, including the error and edge paths.
- **Refactors**: coverage of the behaviour being preserved, in place before you move it — add it first if it is missing.

The tests covering your change must pass before every commit. Match the style of the neighbouring tests — their fixtures, helpers and favoured matchers — rather than importing habits from elsewhere.

### The ordering and the coverage bar are the project's call

**This skill's default is test-first**: investigate → write a failing test → implement → watch it pass → lint → COMMIT. A test written after the code tends to assert what the code does rather than what it should do.

**But it is a default, not a universal. The project's testing policy wins**: where the installing project's instructions set an ordering or a coverage bar, follow them. Where they are silent, work test-first and cover every new or changed line.

What does **not** vary: a change ships with tests, a bug fix has a test that failed before the fix, and the tests covering your change pass before you commit.

### What to test, where

| Layer | Coverage target |
| --- | --- |
| HTTP endpoints | Happy path + validation errors + **authorization** |
| Domain / data models | Validations, scopes, callbacks, business-logic methods |
| Client-side logic | Hooks, store actions, utility functions, component behaviour |
| Concurrent code | Business logic, exercised under the race detector if the language has one |

**Put each test where the project already puts that kind of test.** If a layer has no home yet, ask: a test in the wrong tree often never runs, which looks identical to passing.

## Description conventions

- **Every ticket must have a description and effort estimate.** A title alone is not sufficient.
- **Stakeholder text verbatim; agent text kept current.** Fetch the ticket BEFORE patching. The stakeholder's words stay first and word-for-word, then a `\n\n---\n\n` separator, then yours; their request is the source of truth. Your own additions are living documentation: when facts change, edit them in place rather than stacking dated updates, so the description reads as one current spec.
- **Steps someone performs are SUBTASKS, not description checkboxes** — a runbook, a migration sequence, a mixed-actor procedure. The board can render, count, order, assign and broadcast a subtask; a `- [ ]` is only prose. A single thing to do needs no subtask: it is the ticket. Acceptance criteria also stay in the description, because they are claims about done-ness rather than things anyone performs. See Subtasks (`references/subtasks.md`).
- **Mixed-actor tickets: one timeline, both assigned.** When some steps only the stakeholder can do (vendor consoles, secrets, purchases, hardware), assign BOTH parties to the ticket and give each subtask its own `assignee_id`, in execution order. Never split it into "Stakeholder does: / Agent does:" sections — they hide the interleaving, and the first untoggled subtask must show whose move it is. Tick each the turn its step completes. When the next untoggled subtask is the stakeholder's, apply the External-blocker protocol: leave `started`, comment naming the awaited step, add the dependency. Full rule: [`hard-rules`](../SKILL.md#related-skills) → Steps Are Subtasks.

## Comment conventions

Post comments as you work — at minimum the start comment (_Post the start comment BEFORE the first code edit_ above) and a delivery comment. The thread should tell the implementation story.

- **Capture user interjections** — when the user sends scope-affecting messages mid-ticket, mirror them into the ticket's comment thread.
- **Use `#N` for tickets, `pN` for projects** — both autolink on the board. Never write "ticket 123" or "project 66" in prose.
- **Format for the board, not a terminal** — see Formatting (`references/delivering.md` → _Formatting descriptions and comments_).
- **References happen by themselves; a prerequisite needs a DEPENDENCY.** There is no References API and nothing to call. Juscribe parses `#N`/`pN` out of a ticket's **title and description** on save and stores the references itself; editing the text removes stale ones.
  - ⚠️ **Comments are NOT scanned.** A `#N` written only in a comment creates no reference, though it still renders as a link.
  - **Read them off the payload, not the text.** Every ticket and project carries both directions resolved: `references` (what it points at) and `referenced_by` (what points at it). Each entry is `{type, id, title, ticket_type, color}`, with `id` the `#N` / `pN` you would write. Regexing the description cannot see `referenced_by` at all. A deleted target comes back with a `null` id, so check before you follow one.
  - **When a ticket genuinely gates another** ("requires #75 complete"), the mechanism that makes it real on the board — `blocked: true`, a row in `active_dependencies_summary` — is a dependency:
    ```sh
    jus api POST /workspaces/{ws}/tickets/{blocked}/dependencies '{"dependency":{"blocker_type":"Ticket","blocker_id":{blocker},"blocked_type":"Ticket","blocked_id":{blocked}}}'
    ```

    **MCP:** `add_blocker` with `blocker_type` Ticket.

  - ⚠️ **Set one only when it is genuinely blocking.** A dependency asserts the work _cannot proceed_, and the Dependency Handling Protocol (`references/dependencies.md`) tells other agents to skip what it marks. Put a soft ordering preference in the description instead, and say why it is not a blocker.
- **Read comment reactions as stakeholder signals** — `include_comments=true` returns them per comment, and several 👎 from the stakeholder is an effective rejection of that approach. The full legend, and the endpoint for toggling your own, are in `references/formatting.md`.
