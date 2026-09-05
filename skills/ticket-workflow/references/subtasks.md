# Subtasks — a ticket's checklist

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

⚠️ **AND ONE THING TO DO NEEDS NO SUBTASK AT ALL.** Subtasks are for a **sequence**. A ticket with a single step carries it in its own description — the command fenced there, the actor in the ticket's `assignee_ids`, the ticket's own state saying whether it happened. A lone subtask restates its ticket and hands the board nothing to render, count or order, which is the only reason subtasks exist. Two or more steps and you are back in the rule. Permission, not prohibition: a single subtask is not an error, just not something to manufacture.

⚠️ **STEPS SOMEONE PERFORMS BELONG HERE, NOT IN THE DESCRIPTION.** A runbook, a migration sequence, a mixed-actor procedure: the board can render, count, order, assign and broadcast a subtask, and the stakeholder can tick one off from their phone. A `- [ ]` line does none of that, and only an agent rewriting the whole description can ever change one — exactly backwards when the steps are the stakeholder's to run. The actor is the `assignee_id`, not an `**[Actor]**` tag in the text.

⚠️ **THE COMMAND GOES IN THE `description`, NOT THE `title`.** The board truncates a subtask title, so one long enough to hold a real command is ellipsised and cannot be copied. Title: `N. ` plus a short imperative label. Description: the fenced command, then the commentary. **One bare command per fence**, copy-pastable as-is — no `#` comment on the command line, and never several steps sharing one fence, because copying a step then drags the commentary with it.

⚠️ **The `N. ` stays in the title.** Neither surface renders an ordinal, so it is the only way anything else can point at a specific step.

**What stays a description checkbox: acceptance criteria.** They are claims about whether the ticket is _done_, not things someone performs, and they are what the stakeholder re-reads at acceptance. If you cannot tell which you are writing, ask whether a person could be **assigned** it — a step has an actor, a criterion does not.
