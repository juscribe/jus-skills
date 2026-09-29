# `jus api` — creating, placing and bulk-editing tickets

Where a new ticket lands, and the five endpoints that act on many tickets in one request. The CLI basics and the request-shape gotchas are in `references/api.md`.

## Placing a ticket on create

**`POST /tickets` takes the placement with the create — which panel, and where inside it.** One call, not two. Before 2026-08 `position` and `panel` were permitted and then discarded, so a `201` came back having ignored both; that is no longer the behaviour and the recipe built around it is a wasted call.

| Key | Accepts | Effect |
| --- | --- | --- |
| `panel` | `icebox` / `backlog` / `current` / `done` | The list to arrive in. The panel's **entry state** follows — `unprioritized`, `prioritized`, `started`, `accepted` respectively |
| `state` | any state name | Sets the panel too, since each state belongs to exactly one |
| `position` | a number | The exact position |
| `insert_at` | `top` / `bottom` / `before:<id>` / `after:<id>` | The position computed server-side, relative to the panel or to a neighbouring ticket |

```sh
jus api POST /workspaces/{ws}/tickets '{"ticket":{"title":"…","panel":"backlog","insert_at":"top"}}'
jus api POST /workspaces/{ws}/tickets '{"ticket":{"title":"…","insert_at":"after:2772"}}'
```

**MCP:** `create_ticket` with `panel` and `insert_at`.

**The defaults are the part worth knowing.** With no placement named at all a ticket lands at the **bottom of the icebox** — `insert_at` defaults to `bottom`, and the panel to `icebox`. An anchor overrides that panel default: `insert_at: "after:<id>"` on its own places the ticket in whichever panel that ticket is already in.

⚠️ **A ticket created into Done counts as finished today.** `panel: "done"` or `state: "accepted"` stamps it now and files it into the live iteration, so it adds to this iteration's velocity. No API path keeps a historical date, so do not back-fill old work this way expecting it to land in the past.

**Contradictions are refused, never settled by precedence.** Each of these is a `422` whose `error` names what disagreed, because a silent winner is the defect this replaced:

- `position` and `insert_at` in the same request — they are alternatives, so give one.
- `state` and `panel` naming different panels.
- `before:<id>` / `after:<id>` naming a ticket in a different panel than the one requested, one that is not in the workspace, or one that has no position of its own.
- `position` or `insert_at` against the `done` panel, which is ordered by completion and reassigns positions on arrival. A `done` create with **no** placement is fine.
- An unrecognised `state`, `panel` or `insert_at` directive — a bare `after:` with no id gets its own message, because that is a lost id rather than a typo.

⚠️ **`insert_at` is a directive, not a stored attribute, so it does not echo back.** Read the resulting `position` and `panel` instead — the same shape as the `*_ids` gotcha in `references/api.md` → _Request-shape gotchas_, where nothing coming back does not mean nothing happened.

**Read the reply to a create: two keys can appear on it, and they ask for opposite things.**

| Reply | Means | Do |
| --- | --- | --- |
| `201` with a `warnings` key | A live ticket in this workspace already has the same title and was filed in the last 10 minutes, by anyone. Both rows now exist | Cancel yours as `duplicate`, name the other in a comment, and work on that one |
| `200` with a `deduplicated` key | You filed this same title under 60 seconds ago, so no second row was made; the reply carries the ticket you already have | Nothing to cancel: read `.ticket.id` and carry on |

Each key is **absent** when there is nothing to say, so `jq -e '.warnings'` is the whole check for the first.

**`project_id` takes the project's number with or without the board's `p`**: `"201"` and `"p201"` are the same project. A project that does not exist is a `422` reading `project p201 was not found in this workspace`.

**Moving an EXISTING ticket is still its own call**, and `/reorder` is the one to use:

```sh
jus api PATCH /workspaces/{ws}/tickets/{id}/reorder '{"position": 4.5}'
```

**MCP:** `move_ticket`, which puts a ticket directly above or below another rather than at a number.

⚠️ Note the bare body — `/reorder` reads `position` at the top level, **not** wrapped in `{"ticket": {…}}`. A plain `PATCH …/tickets/{id}` with a `position` does write the column (measured), but it broadcasts `ticket_updated` rather than `ticket_reordered`, so open boards do not move the card.

⚠️ **`/reorder` moves a ticket within its panel, never across.** It writes `position` and nothing else, so a position taken from another panel leaves the ticket in its own panel at a meaningless place. Change panels by changing the state (`/transition` forward, a plain `PATCH` with `state` backward), then reorder.

⚠️ **Markers count as neighbours.** A release, milestone or deadline marker holds a position in the same panel, and ticket lists leave markers out unless asked. Compute a midpoint from a listing fetched with `include_markers=true`, or the ticket can land on the wrong side of a release cut line.

## Bulk endpoints

Five collection endpoints act on many tickets in one request, each taking a `tickets` array. Reach for them before writing a `PATCH` loop — one measured sweep relabelled 148 tickets in 6 requests instead of 148.

| Endpoint | Body | Returns |
| --- | --- | --- |
| `POST …/tickets/bulk_create` | full ticket attributes per item | `results` — one entry per item |
| `PATCH …/tickets/bulk_update` | `id` plus attributes: `label_ids`, `assignee_ids`, points, `panel`/`state` | `results` — one entry per item |
| `PATCH …/tickets/bulk_transition` | `id` and `state`, validated against the state machine per item | `results` — one entry per item |
| `PATCH …/tickets/bulk_reorder` | `id` and `position` per item | `results` of `{id, position}` — **one transaction** |
| `PATCH …/tickets/bulk_sidebar_reorder` | `id` and `sidebar_position` / `bookmarks_position` | `204`, no body |

```sh
jus api PATCH /workspaces/{ws}/tickets/bulk_update '{"tickets":[{"id":"101","points":2},{"id":"102","points":3}]}'
```

**MCP:** no MCP tool updates in bulk. Call `update_ticket` once per ticket.

**A failed item fails alone.** The first three return `HTTP 200` whatever happened inside, with `{"success": true, "ticket": {…}}` or `{"success": false, "errors": [...]}` per entry — so the status line tells you nothing and **the `results` array is what you check**. A ticket id that does not exist is one failed entry, not a failed request.

**`bulk_reorder` is the exception, deliberately.** It runs in one transaction and a bad entry rolls the whole move back, because a half-reordered board is worse than an unmoved one.

## `bulk_create` refuses `position` and `insert_at` — and that is not a limitation to route around

Single create honours both (above); `bulk_create` rejects the item that carries either. The contract of a batch is "create these, **in this order**", and per-item placement contradicts it: two items both asking for the `top` come out in the reverse of the order they were sent, while `bottom` preserves it — the same directive family splitting on order with nothing in the response to say which happened. Two items naming the same `position` simply collide.

`panel` and `state` **are** honoured per item, so a batch can be created straight into the backlog. Ordering within it is the second call:

```sh
jus api POST /workspaces/{ws}/tickets/bulk_create '{"tickets":[{"title":"first","panel":"backlog"},{"title":"second","panel":"backlog"}]}'
jus api PATCH /workspaces/{ws}/tickets/bulk_reorder '{"tickets":[{"id":"101","position":12.25},{"id":"102","position":12.5}]}'
```

**MCP:** `create_tickets` for the first. No MCP tool reorders in bulk, so call `move_ticket` once per ticket.

⚠️ `bulk_reorder` writes the positions you give it verbatim — it computes no gaps. Read the neighbours you are landing between (`?fields=id,position`) and pick values in the gap, as the second call above does.

**`bulk_create` then `bulk_reorder` is two calls by design, not a workaround** — and `bulk_reorder` exists precisely so the second one is not a loop. Items are appended to their panel in request order, so a batch that only needs to be contiguous at the bottom needs no second call at all.

