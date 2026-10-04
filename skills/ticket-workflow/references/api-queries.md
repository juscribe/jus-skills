# `jus api` — reading and filtering tickets

Fetching only what you need, and the filters the ticket index accepts. The CLI basics and the request-shape gotchas are in `references/api.md`.

## Efficiency toolkit

- **Agent state (preferred for session start)**: `agent_state?panels=current,backlog` returns ~2–4 KB markdown; `summary?panels=...` is the structured-JSON variant. Cache TTL 5 minutes; invalidated on ticket/project changes. Never start a session by listing all tickets.
- **Sparse fieldsets**: `?fields=id,title,state,points` — pick exactly what you need (`id` always included).
- ⚠️ **`labels` is an array of STRINGS; `label_objects` is the array of objects.** It is the only association on a ticket that is not objects, so `.ticket.labels[].name` fails with `Cannot index string with string "name"` — and a fetch passing `include_label_objects=false` leaves the string array as the only one there.
- **Opt-out params**: `include_markers` (default `false`; the response says how many it removed in `.meta.excluded_markers`), `include_label_objects` (default `true`; `false` omits the array — string `labels` always present), `include_attachments` (default `false`), `include_comments` (default `false`), `include_subtasks` (default `false`), `comments_limit` (caps to N most recent).
- **Every `include_*` flag takes `true` or `false`, and nothing else.** Leave it out, or empty, for its default. Any other value, `1` and `yes` included, is a `422` naming the flag: `Unknown include_comments value: yes. Valid values: true, false.`

- **`comments_count`**: every ticket response carries it — check before fetching comments; if `0`, skip `include_comments` entirely.

| Task | Approach |
| --- | --- |
| Session start | `agent_state?panels=current,backlog` |
| Fetch a ticket to work on | `tickets/{id}?include_comments=true&include_attachments=true&include_label_objects=false` |
| Bulk state check across panel | `tickets?fields=id,title,state&panel=current` |
| Everything with a label | `tickets?label=security&fields=id,title,state` — one request, not a paging loop |
| Project ticket list | `projects/{id}/tickets?fields=id,title,state,points` |
| Create / update / transition | Normal endpoints — write paths return full data |

## Index filter params

The ticket index takes a substantial filter set, and **it refuses a parameter name it does not recognise**: `HTTP 422`, with every name it does accept in the error.

```text
Unknown parameter: search. Valid parameters: assignee_id, code, comments_limit, …, updated_since.
```

**Read it as a correction.** After `Unknown parameter:` comes every name it refused, not just the first. After `Valid parameters:` comes the whole set this endpoint reads, `page` and `per_page` included. Find the name you meant and send the request again. `jus api` exits `1` on the 422, so a script stops instead of reading on. A bad **value** for a name that does exist is a different 422, checked first and worded for the value: `Unknown stack mode: porject. Valid stack modes: project.`

⚠️ **Only the ticket index refuses.** Every other list endpoint, `projects/{id}/tickets` included, still ignores a name it does not know and answers `HTTP 200` with the unfiltered list. That reads exactly like a filter that matched everything, so there, check `.pagination.count` against what you expected.

⚠️ **`.pagination.count` cannot tell you the list is SHORT, and `.meta.excluded_markers` is the field that can.** The count describes what came back, so it agrees with a thinned list exactly as readily as with a complete one — there is no internal inconsistency to notice. Markers are the thinning that happens by default, and `.meta.excluded_markers` says how many the exclusion removed from your own filter's population. It is **always present**, `0` when `include_markers=true` or a `ticket_type` meant nothing was withheld, so a zero is an answer rather than a silence.

```sh
jus api GET '/workspaces/{ws}/tickets?iteration_id={iteration}&per_page=200' | jq '.meta.excluded_markers'
```

**MCP:** `list_tickets`. Its reply says in `notes` when markers were left out, and `include_markers` brings them back.

⚠️ **"The tickets API has no text search" circulates as lore, and it is wrong.** **`q` works**: a case-insensitive substring match on title _or_ description. `query=` and `search=` are the spellings people reach for, and the ticket index refuses both with the 422 above. It used to ignore them and return the whole table, which is where the lore came from.

| Param | Notes |
| --- | --- |
| `q` | Substring match (`ILIKE`) on title or description |
| `label` | Matches either label representation — see below |
| `panel` | `icebox` / `backlog` / `current` / `done` |
| `state` | Exact state name |
| `ticket_type` | Naming a marker type overrides the `include_markers` default |
| `project_id` | The project's **external** ID, with or without the board's `p` (`201` or `p201`). ⚠️ An unknown one **404s** the whole request, naming it |
| `iteration_id` | Iteration external ID, or `none` for unassigned. ⚠️ An unknown one **404s** the whole request |
| `external_id` | The `#N` you see on the board |
| `requester_id` / `stakeholder_id` / `assignee_id` | User ID |
| `team_id` | Assignee, unassigned requester, or stakeholder is on the team |
| `points_gt` / `points_lt` | Strict, and exclusive of the bound. Non-numeric input reads as `0` |
| `created_after` / `_before` | Inclusive timestamps |
| `updated_since` | Strictly after — for polling what changed |
| `resolution` | A cancelled ticket's resolution: `duplicate`, `wont_do`, `cant_reproduce`, `obsolete` |
| `sort` | `recent` (newest finished first) or `due_date` (soonest due first); otherwise the panel's own order |
| `tally` | `resolution` adds a `resolutions` object counting the whole filtered set, not just the page |
| `page` / `per_page` | Default 50, max 200. The envelope key is `count`, **not** `total_count` |

⚠️ **`panel=done` is not in board order.** It comes back accepted first, then converted, then cancelled, each **oldest first** by the time it reached Done, so the most recent work is on the last page. Pass `sort=recent` for newest first.

Filters combine with `AND`, so one request usually replaces a paging loop:

```sh
jus api GET '/workspaces/{ws}/tickets?label=security&panel=backlog&fields=id,title,state'
```

**MCP:** `list_tickets` with `label`, by name, and `panel`.

⚠️ **`label` matches two representations, and only one of them renders.** A ticket carries labels twice: the `ticket_labels` join (serialized as `label_objects`, and what the board draws as badges) and a legacy string mirror on the ticket itself. The filter unions both, so it never under-returns — but a name living only in the mirror **shows no badge on the card**, has no `Label` record, and will never colour or appear in the label picker. Labelling still goes through `label_ids`, which writes both representations. `jus api GET '/workspaces/{ws}/labels'` is the vocabulary; a name outside it is history, not a label.
