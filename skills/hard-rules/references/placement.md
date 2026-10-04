# Ticket placement — the full text

Read before filing a ticket, or before setting `project_id` on one. `SKILL.md` states the rule; this file is the whole of it, with the reasons and the traps.

## Ticket Placement — Filing Is Not Prioritising

**A new ticket goes to the BOTTOM of the backlog by default**, whether you filed it yourself or were asked to. Set it on the create rather than reordering afterwards.

The middle of the backlog is a sequencing decision the stakeholder has already made. Dropping a new ticket into it silently claims everything below matters less than something they have not read yet. **An unprioritized ticket goes to the top of the icebox** by the same reasoning.

**It is a default, not an absolute. Three things override it:**

1. **The stakeholder specified a position.** Do what they said.
2. **The work is genuinely urgent** — a live outage, an exposed credential, a security hole being actively reachable, or anything gating work already in flight. Then the top is correct: the window in which it is live is the whole cost.
3. **It is not urgent, but it plainly belongs before things already queued.** This is the common case and the one the two above mishandle. **Filing it at the bottom is not the neutral choice it looks like** — it asserts that everything above it matters more. Reaching for the top is the same error inverted.

   So **read the backlog before choosing**, pick a position between the two neighbours it belongs between, and **say which two in the delivery message**. A middle position chosen without listing the backlog is a guess wearing a number.

### And not into a project that is past `started`

**`project_id` only ever names a project that is still `unprioritized`, `prioritized` or `started`.** Once a project has moved past `started` — `finished`, `delivered`, `accepted`, `rejected`, `cancelled`, `archived` — nothing new goes into it. **Check the project's state before you set the field** — it is one call:

```sh
jus api GET '/workspaces/{ws}/projects/{id}?fields=id,name,state'
```

**MCP:** `get_project`.

⚠️ **Nothing refuses the create, and that is the whole problem.** You get a normal `201`, the ticket appears, and the board shows nothing wrong. Two things then go quietly untrue:

- **The project's state stops tracking its own contents.** A ticket moving to `prioritized` or `started` pulls its project forward with it — but **only out of the icebox or the backlog**. From `finished` onwards that advance is a no-op, so the new ticket can be started, worked and delivered while the project holding it goes on reading finished, or accepted, or sitting in Done. Nothing ever reconciles the two.
- **It edits a decision the stakeholder already made.** `accepted` is their verdict on a _set_ of tickets, and the project's point rollup is what a retrospective reports. Adding one afterwards changes both, retroactively, without anyone having decided to.

⚠️ **`rejected` is not the exception it looks like — it is the trap.** A rejected project returns to `started`, so it reads as live work. But the advance does not fire from `rejected` either, so a ticket filed there sits inside a project stuck at rejected. **Wait for the restart, then file.**

**What to do instead, in the order to try it:**

1. **File it with no project.** A standalone ticket is an ordinary thing and costs nothing.
2. **File it under a live project** that genuinely covers it — not the nearest closed one.
3. **Open a successor project** when the follow-on is a body of work rather than one ticket.

Either way, **name the closed project as `pN` in the new ticket's description.** A `pN` in a description is parsed into a real reference row, so the closed project shows the follow-on back — which is the lineage the `project_id` would have carried, and the part worth keeping.

**Reopening a closed project is the stakeholder's call.** If the new work genuinely belongs in it, ask them — do not file into it and hope the state catches up. It will not.
