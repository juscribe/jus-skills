# `jus` CLI & API Reference

The `jus` CLI wraps curl with auth, the `/api/v1` prefix, and jq formatting. Flags: `--raw` (no jq), `-v` (verbose). Token comes from `JUSCRIBE_API_TOKEN` or `.jus/config/api_token.txt`. Installed via Homebrew (`brew install juscribe/tap/jus`) and symlinked at `bin/jus` in this repo. **Output:** the `HTTP <status>` line goes to **stderr**; **stdout is pure JSON** — pipe stdout straight to a parser (`jus api GET '...' | jq .`). Never `2>&1`: it merges the status line into the body and breaks the parse. **Response shape:** bodies are wrapped under a top-level key — a single resource under `.ticket` / `.project`, lists under `.tickets` (with a sibling `.pagination`), `.comments`, etc. Parse `.ticket`/`.project`/`.tickets`, not the JSON root. `include_comments=true` inlines comments on a single **ticket** (`.ticket.comments`) but **not on a project** — fetch those from `jus api GET '/workspaces/{ws}/projects/{id}/comments'` (`.comments`). **Errors:** every mutating body must be wrapped under its resource key — `{"comment":{"body":"..."}}`, not `{"comment":"..."}` and not `{"body":"..."}` for anything you build by hand. A wrong shape is a **400** whose `.error` names the key. **Check the exit code, not just the body:** `jus api` exits **non-zero on any non-2xx** (since v0.6.11), and the error body is still valid JSON on stdout — so `| jq` succeeds on a failure too. A 404 body is only `{"error":"Not found"}` with no status field, so there is nothing in the JSON to key on; use `if ! jus api ...` or `set -e`.

- **Use `jus api` instead of `curl`** — manual curl loses auth and pretty-printing.
- **Avoid a direct console or ORM script for data work** — it bypasses controllers, broadcasts and activity logging, so changes won't show live and won't generate an audit trail. Go through the API.
- **Never fetch full ticket lists at session start** — use `agent_state` for orientation; fetch individual tickets on demand.
- **Combine efficiency tools** — sparse fieldsets, opt-out params, and `agent_state` stack; use them together. Every byte returned costs tokens.

## Contents

- HTTP method patterns & subcommands
- Three things `jus api` does to your call
- Request-shape gotchas
- Placing a ticket on create
- Bulk endpoints
- `bulk_create` refuses `position` and `insert_at` — and that is not a limitation to route around
- Efficiency toolkit
- Index filter params

## HTTP method patterns & subcommands

```sh
jus api GET '/workspaces/{ws}/tickets/{id}'
jus api POST /workspaces/{ws}/tickets '{"ticket":{"title":"..."}}'   # inline JSON
jus api POST /workspaces/{ws}/tickets @.jus/tmp/ticket.json          # file body (@ prefix)
jus api POST /workspaces/{ws}/tickets <<'EOF'                        # heredoc (stdin auto-detected)
{"ticket": {"title": "New ticket", "description": "Multi-line\ndescription here"}}
EOF
jus api PATCH /workspaces/{ws}/tickets/{id} '{"ticket":{"points":2}}'
jus api DELETE /workspaces/{ws}/dependencies/{dep_id}

jus download <attachment-url-path> .jus/tmp/screenshot.png                      # attachment from a ticket
jus init      # first-time setup (token + workspace + symlink)
jus login     # authenticate with API token
jus whoami    # show authenticated user
jus cleanup   # remove all files from .jus/tmp/
jus version   # the CLI version — what the server sees in the X-Jus-Version header
jus switch    # change which AI coding CLI runs dispatched work (multi-LLM accounts)
jus station init | auth | start | logs     # manage the local dispatch station
```

## Three things `jus api` does to your call

Worth knowing because each is invisible in the response, and one of them can send a body you did not write.

- **`{ws}` is substituted for you.** `jus init` stores the workspace id and `jus api` replaces a literal `{ws}` in the path with it — so every path in this skill is copy-pastable as written. With no workspace configured the call stops and names `jus init`; it never requests the literal.
- **The `/api/v1` prefix is added only when the path does not already start with `/api/`.** So a path you write in full reaches whatever namespace it names, unprefixed.
- ⚠️ **A malformed JSON body is auto-repaired, and only stderr says so.** When the shell has eaten quotes or truncated the body, `jus api` tries several recoveries, prints `Warning: Body was not valid JSON — auto-repaired.` and sends the repaired version. It is a rescue for a mangled call, not a licence to build bodies loosely — the repair may not be what you meant, and the request succeeds either way. Pass anything you did not type by hand through `@file` or a quoted heredoc, and read stderr.

## Request-shape gotchas

Five behaviours that present as a hang, a no-op, a bare 500, or a silent success rather than an error. Each is listed by the **symptom you will actually be looking at**.

- **The command hangs and never returns** → you ran `jus api PATCH <path>` with **no body argument**. It does not error and does not default to `{}` — it waits on stdin forever. Body-less endpoints still need an explicit empty object: `jus api PATCH /workspaces/{ws}/dependencies/{id}/resolve '{}'`.
- **A newly created ticket is in the wrong panel, or at the wrong end of it** → you named no placement, and the default is the **bottom of the icebox** — not the panel you were looking at. Create takes `panel`, `state`, `position` and `insert_at` and honours all four; see `references/api.md` → Placing a ticket on create. ⚠️ The recipe this bullet used to give — create, then `/reorder` — is a wasted call, and the claim it rested on (`position` silently ignored) stopped being true.
- **A transition is rejected as invalid** → `/transition` walks the state machine **one state at a time**. `unprioritized` straight to `started` is a 422, not a shortcut; go through `prioritized`. The error names the valid next states, so read it rather than guessing again.
- **A transition returns a body of nulls and nothing changes** → you tried to move a ticket **backwards**, e.g. `prioritized` → `unprioritized` when parking work back to the icebox. `/transition` only walks the state machine forwards. Use a direct field update instead: `PATCH /workspaces/{ws}/tickets/{id} '{"ticket":{"state":"unprioritized"}}'`. Forward moves keep using `/transition`.
- **A create returns a bare `HTTP 500` with `"Internal Server Error"` and nothing else** → check the **case** of an enum value. `ticket_type` is lowercase (`feature`, `bug`, `chore`, `milestone`, `release`, `deadline`, `research`); passing `"Release"` raises `ArgumentError` inside the model and surfaces as a 500 that names no field. Any enum-backed attribute fails the same way, so a 500 on an otherwise well-formed create is a casing bug until proven otherwise — not a server fault to retry.
- **You set `assignee_ids` / `label_ids` / `stakeholder_id` and the response shows `null`** → the write **succeeded**. `*_ids` fields do not echo back; the response carries the expanded `assignees` / `labels` / `stakeholder` objects instead. Verify against those, not the `*_ids` key, or you will retry a write that already landed.

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

**The defaults are the part worth knowing.** With no placement named at all a ticket lands at the **bottom of the icebox** — `insert_at` defaults to `bottom`, and the panel to `icebox`. An anchor overrides that panel default: `insert_at: "after:<id>"` on its own places the ticket in whichever panel that ticket is already in.

**Contradictions are refused, never settled by precedence.** Each of these is a `422` whose `error` names what disagreed, because a silent winner is the defect this replaced:

- `position` and `insert_at` in the same request — they are alternatives, so give one.
- `state` and `panel` naming different panels.
- `before:<id>` / `after:<id>` naming a ticket in a different panel than the one requested, one that is not in the workspace, or one that has no position of its own.
- `position` or `insert_at` against the `done` panel, which is ordered by completion and reassigns positions on arrival. A `done` create with **no** placement is fine.
- An unrecognised `state`, `panel` or `insert_at` directive — a bare `after:` with no id gets its own message, because that is a lost id rather than a typo.

⚠️ **`insert_at` is a directive, not a stored attribute, so it does not echo back.** Read the resulting `position` and `panel` instead — the same shape as the `*_ids` gotcha above, where nothing coming back does not mean nothing happened.

**Moving an EXISTING ticket is still its own call**, and `/reorder` is the one to use:

```sh
jus api PATCH /workspaces/{ws}/tickets/{id}/reorder '{"position": 4.5}'
```

⚠️ Note the bare body — `/reorder` reads `position` at the top level, **not** wrapped in `{"ticket": {…}}`. A plain `PATCH …/tickets/{id}` with a `position` does write the column (measured), but it broadcasts `ticket_updated` rather than `ticket_reordered`, so open boards do not move the card.

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

**A failed item fails alone.** The first three return `HTTP 200` whatever happened inside, with `{"success": true, "ticket": {…}}` or `{"success": false, "errors": [...]}` per entry — so the status line tells you nothing and **the `results` array is what you check**. A ticket id that does not exist is one failed entry, not a failed request.

**`bulk_reorder` is the exception, deliberately.** It runs in one transaction and a bad entry rolls the whole move back, because a half-reordered board is worse than an unmoved one.

## `bulk_create` refuses `position` and `insert_at` — and that is not a limitation to route around

Single create honours both (above); `bulk_create` rejects the item that carries either. The contract of a batch is "create these, **in this order**", and per-item placement contradicts it: two items both asking for the `top` come out in the reverse of the order they were sent, while `bottom` preserves it — the same directive family splitting on order with nothing in the response to say which happened. Two items naming the same `position` simply collide.

`panel` and `state` **are** honoured per item, so a batch can be created straight into the backlog. Ordering within it is the second call:

```sh
jus api POST /workspaces/{ws}/tickets/bulk_create '{"tickets":[{"title":"first","panel":"backlog"},{"title":"second","panel":"backlog"}]}'
jus api PATCH /workspaces/{ws}/tickets/bulk_reorder '{"tickets":[{"id":"101","position":12.25},{"id":"102","position":12.5}]}'
```

⚠️ `bulk_reorder` writes the positions you give it verbatim — it computes no gaps. Read the neighbours you are landing between (`?fields=id,position`) and pick values in the gap, as the second call above does.

**`bulk_create` then `bulk_reorder` is two calls by design, not a workaround** — and `bulk_reorder` exists precisely so the second one is not a loop. Items are appended to their panel in request order, so a batch that only needs to be contiguous at the bottom needs no second call at all.

## Efficiency toolkit

- **Agent state (preferred for session start)**: `agent_state?panels=current,backlog` returns ~2–4 KB markdown; `summary?panels=...` is the structured-JSON variant. Cache TTL 5 minutes; invalidated on ticket/project changes. Never start a session by listing all tickets.
- **Sparse fieldsets**: `?fields=id,title,state,points` — pick exactly what you need (`id` always included).
- ⚠️ **`labels` is an array of STRINGS; `label_objects` is the array of objects.** It is the only association on a ticket that is not objects, so `.ticket.labels[].name` fails with `Cannot index string with string "name"` — and a fetch passing `include_label_objects=false` leaves the string array as the only one there.
- **Opt-out params**: `include_markers` (default `false`; the response says how many it removed in `.meta.excluded_markers`), `include_label_objects` (default `true`; `false` omits the array — string `labels` always present), `include_attachments` (default `false`), `include_comments` (default `false`), `include_subtasks` (default `false`), `comments_limit` (caps to N most recent).
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

The ticket index takes a substantial filter set, and **nothing rejects a name it does not recognise, and nothing logs it either** — the index never puts the query string through strong parameters, so there is no `Unpermitted parameter` line to go looking for. A misspelled filter returns the unfiltered list with `HTTP 200`, which reads exactly like a filter that matched everything. Check `.pagination.count` against what you expected.

⚠️ **`.pagination.count` cannot tell you the list is SHORT, and `.meta.excluded_markers` is the field that can.** The count describes what came back, so it agrees with a thinned list exactly as readily as with a complete one — there is no internal inconsistency to notice. Markers are the thinning that happens by default, and `.meta.excluded_markers` says how many the exclusion removed from your own filter's population. It is **always present**, `0` when `include_markers=true` or a `ticket_type` meant nothing was withheld, so a zero is an answer rather than a silence.

```sh
jus api GET '/workspaces/{ws}/tickets?iteration_id={iteration}&per_page=200' | jq '.meta.excluded_markers'
```

⚠️ **This is why "the tickets API has no text search" circulates as lore.** `query=` and `search=` are silently ignored because neither is the param name. **`q` works** — a case-insensitive substring match on title _or_ description.

| Param | Notes |
| --- | --- |
| `q` | Substring match (`ILIKE`) on title or description |
| `label` | Matches either label representation — see below |
| `panel` | `icebox` / `backlog` / `current` / `done` |
| `state` | Exact state name |
| `ticket_type` | Naming a marker type overrides the `include_markers` default |
| `project_id` | The project's **external** ID, not its database ID. ⚠️ An unknown one does **not** return `[]` — it matches every ticket with NO project |
| `iteration_id` | Iteration external ID, or `none` for unassigned. ⚠️ An unknown one **404s** the whole request |
| `external_id` | The `#N` you see on the board |
| `requester_id` / `stakeholder_id` / `assignee_id` | User ID |
| `team_id` | Assignee, unassigned requester, or stakeholder is on the team |
| `points_gt` / `points_lt` | Strict, and exclusive of the bound. Non-numeric input reads as `0` |
| `created_after` / `_before` | Inclusive timestamps |
| `updated_since` | Strictly after — for polling what changed |
| `page` / `per_page` | Default 50, max 200. The envelope key is `count`, **not** `total_count` |

Filters combine with `AND`, so one request usually replaces a paging loop:

```sh
jus api GET '/workspaces/{ws}/tickets?label=security&panel=backlog&fields=id,title,state'
```

⚠️ **`label` matches two representations, and only one of them renders.** A ticket carries labels twice: the `ticket_labels` join (serialized as `label_objects`, and what the board draws as badges) and a legacy string mirror on the ticket itself. The filter unions both, so it never under-returns — but a name living only in the mirror **shows no badge on the card**, has no `Label` record, and will never colour or appear in the label picker. Labelling still goes through `label_ids`, which writes both representations. `jus api GET '/workspaces/{ws}/labels'` is the vocabulary; a name outside it is history, not a label.
