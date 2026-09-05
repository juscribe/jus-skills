# Dependency Handling Protocol

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

## Dependencies API

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

## Blocker dates

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

⚠️ **`blocker_id`, `blocker_type`, `blocked_id` and `blocked_type` are NOT editable — but `title`, `description`, `due_on` and `due_kind` ARE** (`DependencyParams::EDITABLE`, `app/services/dependency_params.rb:21`). A `blocker_id` in the update body is dropped rather than repointing the row, and the call still answers `200` — so a repoint that looks like it worked did not. **Repointing a blocker is a DELETE plus a create**, because a different blocker is a different dependency. ⚠️ **Rewording one is NOT.** This passage said only the two date fields were editable until #3293, and following that destroys a dependency's history to change a sentence — #3199 added the two text fields precisely so a badly derived title could be fixed in place.

**Reading a date back.** Every ticket and project payload carries the soonest one as a scalar pair, `earliest_blocker_due_on` / `earliest_blocker_due_kind`, alongside the per-blocker `due_on` / `due_kind` inside `active_dependencies_summary`. Read the pair to decide; read the summary to say which blocker it was.

## Creating dependencies

- **During investigation** — if you discover untracked prerequisites, create via `POST .../dependencies` + comment. Hard block → leave started + move on. Soft dependency → proceed but create the link for documentation.
- **During ticket creation** — convert prose prerequisites ("requires #N") into formal `Ticket→Ticket` dependencies.
- **For user input** — create an `External` dependency with description `"User input: <what you need>"` whenever you cannot proceed without stakeholder input. This makes the block visible on the board. Posting a comment alone is not enough.

## Resolving and post-delivery

- **Auto-resolve** fires when a blocker reaches `accepted`/`cancelled`. No manual action needed.
- **Manual resolve** (`PATCH .../resolve`) — for external blockers or when auto-resolve missed.
- **Delete** (`DELETE .../dependencies/{id}`) — only for dependencies created in error.
- **After delivering** — check `GET .../dependencies/blocks` and mention any unblocked tickets in the delivery comment. Don't auto-start them unless they're next in your batch queue.
- **Stale hygiene** — during session orientation, resolve any dependencies whose blockers are already in a terminal state.
