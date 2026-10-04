# Steps are subtasks — the full text

Read before writing steps someone performs, or a ticket that mixes the stakeholder's steps with yours. `SKILL.md` states the rule; this file is the whole of it, with the reasons and the traps.

## Steps Are Subtasks, Never Description Checkboxes

If a ticket tells someone to _do_ things in order — a runbook, a migration sequence, a mixed-actor procedure — those steps are **subtasks on the ticket**, not `- [ ]` lines in the description.

**Why, in one line: a description checkbox is prose, a subtask is data.** The board renders subtasks, counts them, orders them, assigns each to one person, broadcasts each change, and lets the stakeholder tick one off from their phone. A `- [ ]` can do none of that, and only an agent editing the whole description can ever change one — which is exactly backwards when the steps are the stakeholder's to run.

⚠️ **ONE THING TO DO NEEDS NO SUBTASK — the rule fires on a SEQUENCE.** A ticket with a single step does not owe a subtask for it: put the command in the ticket's own description, leave the actor in the ticket's `assignee_ids`, and let the ticket's state say whether it happened. A lone subtask restates its ticket — same actor, same one thing, two places to tick — and hands the board nothing to render, count or order, which is the entire argument above. **Two or more steps and you are back in the rule**, because that is where ordering, per-step actors and partial progress start to exist; a second step turning up later is the moment to create both. This is permission rather than prohibition — a single subtask is not an error, and a tool that writes one for you is not to be second-guessed. It is simply not something to manufacture.

```sh
jus api POST /workspaces/{ws}/tickets/{id}/subtasks '{"subtask":{"title":"2. Approve the certificate","description":"…","assignee_id":1}}'
jus api PATCH /workspaces/{ws}/tickets/{id}/subtasks/{subtask_id} '{"subtask":{"completed":true}}'
```

**MCP:** `add_subtask`, then `update_subtask` with `completed: true`.

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
- **Blocker integration:** whenever the next untoggled subtask is the stakeholder's, the External Blocker Rule in `SKILL.md` applies — leave the ticket `started`, post a comment naming exactly which step you are waiting on, and add the External dependency. **That blocker is a `title` naming the subtask and nothing else** — no `description` — because the subtask already carries the step, its command and its owner, and the board draws both: `{"title":"Subtask 3 — run the dispatch"}`. Restating the step in the blocker is duplication, not emphasis. Resolve it and continue when your next step unblocks.

### What stays a description checkbox: acceptance criteria

They are claims about whether the ticket is _done_, not things someone performs, and they are what the stakeholder re-reads at acceptance. Keep them in the description and keep them swept. If you cannot tell which you are writing, ask whether a person could be **assigned** it — a step has an actor, a criterion does not.
