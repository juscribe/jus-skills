# Picking up a ticket

Read before your first `jus` call on a ticket: finding it, the checks before `started`, the lock itself, and working several tickets in a row.

## Phase 1: Session Start

Orient with the agent state endpoint — never fetch full ticket lists at session start.

```sh
jus api GET '/workspaces/{ws}/agent_state?panels=current,backlog'
```

It returns compact markdown (~2–4KB): projects, velocity, users and one line per ticket, cached for 5 minutes. Decide what to work on from it, then fetch individual tickets.

## Fetch the ticket with comments AND attachments

```sh
jus api GET '/workspaces/{ws}/tickets/{id}?include_comments=true&include_attachments=true&include_label_objects=false'
```

**MUST include comments and attachments.** Comments carry the stakeholder's context, open questions and decisions; attachments carry rejection screenshots and design mocks. If `comments_count` is `0`, drop `include_comments=true`.

If the response shows `blocked: true` or `active_dependencies_count > 0`, fetch the dependencies and apply the Dependency Handling Protocol (`references/dependencies.md`).

## Pre-start gate (hard checklist)

Before transitioning to `started`, verify:

- `description` is non-null
- `points` is set
- `stakeholder_id` is set

If any are missing, PATCH them first. Never start a ticket that fails this gate.

**The point scale, the ticket types and the metadata defaults are in `references/estimation-and-types.md`** — open it before putting a number or a type on anything. A guessed type is a `422`; a guessed point value silently distorts the board's velocity.

## Name a branch `<ticket-id>-<slug>` whenever you cut one

⚠️ **The commit linker depends on it.** It reads a ticket id only from the start of the branch's LAST path segment, followed by a dash. `3705-copy-a-branch-name` links its commits and its pull request with nothing typed anywhere; `copy-a-branch-name-3705` links nothing. A prefix is fine: `feat/3705-copy-a-branch-name`.

**Where the work lands is the project's call** — whether to branch, merge or push. Absent instructions, commit where you are and **do not push**: an unrequested push cannot be taken back.

## Fleshing out a sparse user-created ticket

A bare title or a one-line description does not pass the gate above. **Flesh the ticket out with substance the stakeholder can react to:**

- **What to add:** your read of the problem (root cause for bugs, approach for features), **acceptance criteria**, and any implementation or test notes. Format it per Formatting (`references/delivering.md` → _Formatting descriptions and comments_).
- **When:** at pickup, as part of the pre-start gate. Add what investigation finds as you learn it.
- **How:** fetch first. If `description` is non-null, the stakeholder's text stays first and verbatim, then `\n\n---\n\n`, then yours — see Description conventions (`references/investigating.md` → _Description conventions_).

A title-only ticket has no acceptance criteria to deliver against and no basis for its estimate.

## CRITICAL: Transition to `started` BEFORE investigating

The moment you decide to work the ticket, transition it and assign yourself, **before** reading any source file. It is the concurrency lock that tells other sessions the ticket is taken.

```sh
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"started"}'
jus api PATCH /workspaces/{ws}/tickets/{id} '{"ticket":{"assignee_ids":[{your_user_id}]}}'
```

Sequence: fetch → start → assign → THEN investigate. **NEVER reverse this order.** Where the jus hooks run, a `UserPromptSubmit` hook fetches the ticket and prints the transition command, but writes nothing: the lock is still yours to take.

## ⚠️ Do NOT put a 👀 on a ticket

**The eyes reaction is not part of the lifecycle.** The hooks that once added and removed it were retired because the reaction went stale in every direction; do not add it by hand. **`started` plus an assignee is the concurrency lock** — it is what the conflict rule below keys on. Your reaction on a **comment** is a different mechanism and is unaffected.

## Concurrency conflict

If the transition to `started` fails, check the assignees. If another agent has claimed the ticket, **stop**, tell the user it appears taken, and ask how to proceed.

## Rejection workflow

A rejected ticket goes `rejected → started → fix → finish`. **NEVER** `git commit --amend` on delivered work — create a new commit.

- **When the user says "rejected", the transition has already happened in the app.** Do not call the reject transition; transition `rejected → started` and fix.
- **Always fetch attachments on a rejected ticket** — the stakeholder may have attached screenshots of the problem. `jus download <url-path> .jus/tmp/<filename>` saves one to view.

## Batch Work & Special Workflows

- **Respect ticket ordering** — work tickets in their `position` order. Do not reorder or cherry-pick.
- **A stakeholder may have a shorthand for "work the whole backlog"**: every ticket in it, in position order, with no confirmation between them. Record the phrase in the project's own instructions; it is a convention between you and them, not a Juscribe feature.
- **Every ticket gets the FULL lifecycle, even in batch mode**: start → investigate → code → commit → self-review → tick the boxes → **delivery comment with verification steps** → finish. Never skip or combine delivery comments — the stakeholder reviews tickets individually.
- **Do not force-deliver tickets that aren't fully done.** A batch ticket with questions, blockers or incomplete work stays in `started` with a comment while you move to the next; `references/dependencies.md` records the block. Delivering partial work to "clear the batch" is strictly prohibited.
- **Research tickets** — start it, do the research (web searches, codebase analysis, docs), put the findings in the ticket description, then finish it. No commit needed: the description is the deliverable.
