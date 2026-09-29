# External blockers — the full text

Read before adding a dependency because you are waiting on someone, or on a date. `SKILL.md` states the rule; this file is the whole of it, with the reasons and the traps.

## External Blocker Rule — Always Track What Needs User Input

- **ALWAYS add an External dependency when waiting for user input.** If you cannot proceed without information from the stakeholder (config values, credentials, design decisions, clarifications), you MUST:
  1. Leave the ticket in `started`.
  2. Post a comment explaining what you need.
  3. Add an External dependency **titled** for the input needed — a few words, not a paragraph.
- **Do NOT just ask and move on** — the dependency is the mechanism that makes the block visible on the board. A comment alone is invisible to project-level rollups.
- **`title` IS THE HALF THE BOARD DRAWS.** An External blocker requires a `title` (≤200 chars), not a `description` — the description is the body and appears on no card. Omit the title and one is derived from the description: first line, first sentence, cut at 80 characters with an ellipsis. That is how a blocker ends up drawn as a truncated paragraph. Write the short line yourself, and keep the description for what the title cannot hold.

```sh
jus api POST /workspaces/{ws}/tickets/{id}/dependencies '{"dependency":{"blocker_type":"External","blocked_type":"Ticket","blocked_id":{id},"title":"User input: <the ask in a few words>","description":"<the full ask>"}}'
```

**MCP:** `add_blocker` with `blocker_type` External.

- **A BLOCKER WHOSE CONDITION IS A TIME MUST CARRY `due_on` AND `due_kind`.** Waiting on an answer has no date; waiting on _"a full 7-day window with no errors"_ or _"three days after the rollout"_ does, and a row that states one in its text and leaves the date column null gives the board nothing to bring anyone back with. The ticket then reads as blocked forever and surfaces only when a human goes looking. Neither half works alone — each without the other is a `422`.

| Kind | Use it when |
| --- | --- |
| `wait_until` | The date is a hard do-not-start-before |
| `review_on` | Revisit and decide on that day — push the date if the condition still is not met |
| `expected_by` | A forecast, informational; work alongside it if you can |

  ⚠️ **Not knowing the date yet is what `review_on` is for.** Pick the soonest day on which checking is worth anyone's time and say in the description what to do if the answer is still wrong. An estimated review date beats none, because none is indistinguishable from a blocker nobody intends to revisit.
