# Phase 6: Finish & Deliver

## Contents

- [Pre-delivery gate: Did you actually do what the ticket asks?](#pre-delivery-gate-did-you-actually-do-what-the-ticket-asks)
- [Post finished comment BEFORE transitioning](#post-finished-comment-before-transitioning)
- [Transition](#transition)
- [Formatting descriptions and comments](#formatting-descriptions-and-comments)
- [Phase 7: Project Completion](#phase-7-project-completion)

## Pre-delivery gate: Did you actually do what the ticket asks?

**Before finishing, re-read the ticket description and acceptance criteria.** Did you implement what was prescribed? If you deferred something, skipped a requirement, chose not to do something the ticket specifies, or deviated from the described scope — **do NOT finish or deliver.** Instead:

1. Leave the ticket in `started`.
2. Post a comment explaining what you couldn't do, why, and what options exist.
3. Add an **External dependency** titled for the ask, so the ticket shows as blocked:
   ```sh
   jus api POST /workspaces/{ws}/tickets/{id}/dependencies '{"dependency":{"blocker_type":"External","blocked_type":"Ticket","blocked_id":{id},"title":"User input: <the ask in a few words>","description":"<the full ask>"}}'
   ```
   ⚠️ **`title` is the half the board draws**, so it is the one to get right — leave it out and it is derived from the description, cut at 80 characters with an ellipsis. When the ask is simply that the next subtask is someone else's, the title names that subtask and there is **no description**.
4. Move on to the next ticket. The stakeholder resolves the dependency after providing input.

**Delivering work that doesn't match the ticket is worse than not delivering at all** — it forces a rejection cycle. When in doubt, leave it started and comment.

### Then tick the boxes you met

**Tick each `- [ ]` box you met in the description, before the delivery comment and the `finished` call.** An unticked box tells the stakeholder the work is not done, whatever the delivery comment says, and the description is what they re-read at acceptance. Fetching the description to tick it is the re-read this gate asks for, so work from the ticket, not from memory.

```sh
jus api GET '/workspaces/{ws}/tickets/{id}?fields=description' | jq -j '.ticket.description' > desc.md
```

Edit `desc.md`: change `- [ ]` to `- [x]` on each box you met, and nothing else. The stakeholder's words stay verbatim.

```sh
jus api PATCH /workspaces/{ws}/tickets/{id} "$(jq -Rs '{ticket:{description:.}}' < desc.md)"
```

Tick only a box you can answer one question for: **what evidence would I cite?** A command, an output, a file, a commit. "It will be true once this ships" is a forecast, not evidence. A wrongly ticked box is worse than an unticked one, because it looks like success and nobody goes back to it. **An unmet box stays unticked, and an unmet box means do not finish** — that is the gate above firing.

A subtask whose step is done gets `{"subtask":{"completed":true}}` in the same pass. Never `/toggle` it: that flips whatever state it finds, so it unticks a step someone else already ticked.

## Post finished comment BEFORE transitioning

Re-read the ticket's comments (`?include_comments=true`) before writing the delivery comment. Don't re-answer questions or repeat content from earlier comments (including your own start comment).

The "To verify" section with concrete acceptance/rejection steps is **mandatory, not optional — even during batch work.** Every ticket gets its own delivery comment with verification steps. Do not batch or skip. Shape the comment per Formatting (_Formatting descriptions and comments_ below): bold section labels, a numbered To-verify list, fenced code for commands.

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

- **Work on a branch:** name it, and say what has and has not happened to it. Somebody meeting a branch they did not expect should not have to ask what state it is in.

  ```
  **Branch:** `3832-workflow-strategy` — nothing merged, nothing pushed.
  ```

- **Dispatched work (on a branch):** Do NOT include branch info — the dispatch job appends it automatically after the session completes.
- **Tickets with no code changes** (research, documentation, already-implemented): Omit git info — state plainly that no code changes were made.

```sh
jus api POST /workspaces/{ws}/tickets/{id}/comments '{"comment":{"body":"...verification steps..."}}'
```

## Transition

```sh
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"finished"}'
```

Sequence: commit → self-review → tick the boxes → post finished comment → finish.

⚠️ **Finish, and stop there. Call `delivered` only when a person asks for it.** Delivering is the handover: the claim that the work is ready for someone to accept. A board that keeps Finished and Delivered apart does so because its owner wants that handover to be a separate step, taken by a person or by their deploy. A board that merges them lands your `finished` call in `delivered` by itself. So the one call is right on both, and the workspace payload's `merge_finished_into_delivered` says which kind of board you are on.

When a person does ask ("deliver #N"), make both calls, `finished` then `delivered`, because a transition steps one state at a time. On a merged board the second answers `200` having changed nothing, which is not a failure.

## Formatting descriptions and comments

Descriptions and comments render as **markdown on the board**, for a human scanning a card rather than a terminal log. Structure beats prose:

- **Bold section labels** open each part of the story: `**Root cause:**`, `**Plan:**`, `**What shipped:**`, `**To verify:**`, `**Acceptance criteria:**`.
- **Bullets and numbered lists** over paragraph runs — one idea per bullet, and numbered steps for anything the stakeholder will follow in order.
- **Fenced code blocks** for every command, path list or output the stakeholder might copy (`sh`-fenced for commands); **inline backticks** for file paths, method names, flags and states in prose.
- **`#N` / `pN` references** wherever you mention tickets or projects. ⚠️ **`#N` is RESERVED for ticket ids. Never write a bare `#` in front of any other number** — a workspace id, a comment id, a row id, a port, a count. In a title or description it creates a real reference to whichever ticket carries that number; in a comment it still renders as a ticket link. Write `workspace 12`, `comment 6079`, `port 5432`.
- **Bold the verdict, not everything** — the load-bearing words (`**no mount**`, `does **not** retry`), not whole sentences.

⚠️ **A fence inside ANY list item must sit at the list's CONTENT column** — two spaces under a `- ` marker, not lined up under the text. Indented further, it renders as one line of inline code with the language tag glued to the command, while the source still looks correct. Check the rendered output; the worked example, and an example start comment, are in `references/formatting.md`.

A delivery comment: `**Commit:**` line, a short `**What shipped:**` block, then a numbered `**To verify:**` list — see Post finished comment (`references/delivering.md` → _Post finished comment BEFORE transitioning_). Description flesh-outs and blocker comments follow the same conventions.

# Phase 7: Project Completion

When all tickets in a project reach `accepted`, post a **validation comment on the Project** summarizing how the stakeholder can verify every ticket works as spec'd. This is a consolidated end-to-end QA guide — not a repeat of individual ticket steps.

```sh
jus api POST /workspaces/{ws}/projects/{id}/comments '{"comment":{"body":"## Validation Guide\n\n1. Step one...\n2. Step two...\n..."}}'
```

Guidelines:

- **Cover every ticket** — reference each by `#N` and describe how to verify its behavior.
- **Order by user flow** — group steps by the natural order a user encounters the features, not by ticket number.
- **Be specific** — exact UI paths, expected states, edge cases worth checking.
- **Call out regressions** — note any areas where existing behavior could have been affected.
