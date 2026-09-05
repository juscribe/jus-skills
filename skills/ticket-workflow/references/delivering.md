# Phase 6: Finish & Deliver

## Pre-delivery gate: Did you actually do what the ticket asks?

**Before finishing, re-read the ticket description and acceptance criteria.** Did you implement what was prescribed? If you deferred something, skipped a requirement, chose not to do something the ticket specifies, or deviated from the described scope — **do NOT finish or deliver.** Instead:

1. Leave the ticket in `started`.
2. Post a comment explaining what you couldn't do, why, and what options exist.
3. Add an **External dependency** so the ticket shows as blocked:
   ```sh
   jus api POST /workspaces/{ws}/tickets/{id}/dependencies '{"dependency":{"blocker_type":"External","blocked_type":"Ticket","blocked_id":{id},"description":"User input"}}'
   ```
4. Move on to the next ticket. The stakeholder resolves the dependency after providing input.

**Delivering work that doesn't match the ticket is worse than not delivering at all** — it forces a rejection cycle. When in doubt, leave it started and comment.

## Post finished comment BEFORE transitioning

Re-read the ticket's comments (`?include_comments=true`) before writing the delivery comment. Don't re-answer questions or repeat content from earlier comments (including your own start comment).

The "To verify" section with concrete acceptance/rejection steps is **mandatory, not optional — even during batch work.** Every ticket gets its own delivery comment with verification steps. Do not batch or skip. Shape the comment per [Formatting](../SKILL.md#formatting-descriptions-and-comments): bold section labels, a numbered To-verify list, fenced code for commands.

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

## Transition

```sh
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"finished"}'
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"delivered"}'
```

Sequence: commit → self-review → post finished comment → finish → deliver.

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
