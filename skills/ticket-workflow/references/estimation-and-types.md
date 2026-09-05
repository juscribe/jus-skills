# Estimation

Effort is captured in `points`. **Valid values: `0`, `1`, `2`, `3`, `5`, `8`** — no other values, no half-points.

| Points | Calibration |
| --- | --- |
| `0` | Trivial config change, typo fix — no real engineering effort |
| `1` | Single-file change, simple bug fix |
| `2` | Small feature or multi-file change with clear scope |
| `3` | Medium feature — new endpoint + frontend, multiple specs |
| `5` | Large feature spanning backend + frontend + tests, or a complex refactor |
| `8` | Epic-scale work — usually a sign the ticket should be broken into smaller tickets |

- **Every ticket gets points, including chores and bugs.** Chores are NOT automatically `0`; a chore that requires real work gets real points (chores affect velocity too). `0` is reserved for genuinely trivial / no-effort items.
- **Research tickets are typically `1`–`2` points** — the deliverable is description content, not code.
- **Features require points to leave icebox.** A feature with `points: null` cannot be transitioned to `prioritized` (except when cancelling).
- **If you reach for `8`, stop and split.** An 8-point ticket is almost always two or three smaller tickets in disguise — splitting up front beats partial-delivery rejection cycles later.

```sh
jus api PATCH /workspaces/{ws}/tickets/{id} '{"ticket":{"points":2}}'
```

# Ticket Types

The `ticket_type` field controls which icon renders on the board and signals intent to the stakeholder.

| Type | API value | Icon | Meaning |
| --- | --- | --- | --- |
| Feature | `feature` | ★ | New functionality or enhancement to existing behavior |
| Bug | `bug` | ● | Something that worked before is now broken |
| Chore | `chore` | ⚙ | Maintenance, refactoring, config, CI — no user-visible behavior change |
| Research | `research` | ⚗ | Investigation, analysis, answering questions — deliverable is description content, not code |

## Choosing the right type

Top to bottom — pick the first that fits:

1. **Deliverable is findings, not code** → `research`
2. **Deliverable is invisible to users** (deps, config, CI, internal cleanup) → `chore`
3. **Something used to work and now doesn't** → `bug`
4. **Adds or changes user-visible behavior** → `feature`
5. **It's a timeline marker on the board, not work** → `milestone`, `release`, or `deadline`

Common miscalibrations to avoid: "document how X works" → `research`, not `chore`; "refactor without behavior change" → `chore`, not `feature`; "restore behavior that regressed" → `bug`, not `feature`; "change existing behavior in a user-visible way" → `feature`, not `chore` (even if small).

## Marker types (timeline, not work items)

Markers render as horizontal bars on the board, not cards. They are timeline-planning artifacts and are excluded from API responses by default — pass `include_markers=true` to include them when listing, and read `.meta.excluded_markers` to see how many a query without it dropped.

| Type | API value | Icon | Use for |
| --- | --- | --- | --- |
| Milestone | `milestone` | ◆ | Significant project checkpoint or goal |
| Release | `release` | ⚑ | Version cut or deployment boundary |
| Deadline | `deadline` | ⚑ | Hard date constraint (renders red) |

**Marker titles name the thing itself** — the vehicle + payload for a release, the checkpoint for a milestone. No "Pending …" or type-word prefixes ("Release:", "Milestone:") and no leading icon characters: the board renders every marker with its type icon (and a type-colored bar), so a prefixed or icon-led title states the type twice.

# Ticket Metadata

| Field | Default / convention |
| --- | --- |
| `requester_id` | **Auto-set** to `current_user` by the API — not settable. The agent that creates the ticket is the requester. |
| `stakeholder_id` | **Set to the workspace owner's user ID** for all tickets. Look it up once per workspace rather than hardcoding it. |
| `assignee_ids` | Set to your agent user ID when you are doing the coding. **Mixed-actor tickets (some steps only the stakeholder can perform): assign BOTH** — and give each subtask its own `assignee_id` (see `references/subtasks.md`). **Omit or leave empty** when creating tickets you won't immediately work on — let the stakeholder assign. |
| `description` | **Append-only.** Fetch first; if non-null, prepend existing content + `\n\n---\n\n` before your additions. See [`hard-rules`](../SKILL.md#related-skills). |
| `points` | Required for features to leave icebox. Valid values: `0, 1, 2, 3, 5, 8`. See [Estimation](#estimation). |
| `ticket_type` | One of `feature`, `bug`, `chore`, `research` (or marker types). See [Ticket Types](#ticket-types). |
| `label_ids` | Array of integers, 1–3 entries. See [Label conventions](../SKILL.md#label-conventions). |
| `project_id` | Scope a ticket under a project when one applies — improves board organization and unlocks project-level rollups. ⚠️ **Only ever a project still `unprioritized`, `prioritized` or `started`** — filing into one past `started` succeeds silently and leaves the project's state no longer tracking its contents. See [`hard-rules`](../SKILL.md#related-skills) → Ticket Placement. |
| `panel` / `state` / `position` / `insert_at` | The placement, honoured on create since 2026-08. See `references/api.md` → Placing a ticket on create; `bulk_create` takes only the first two. |
| `comments_count` | Counter-cached integer. Check before fetching comments. |
| `blocked` / `active_dependencies_count` | If `true` / `> 0`, fetch dependencies before deciding to start. |

## Creating a ticket with full metadata

```sh
jus api POST /workspaces/1/tickets '{
  "ticket": {
    "title": "Short imperative title",
    "description": "What and why, with acceptance criteria.",
    "ticket_type": "feature",
    "points": 2,
    "stakeholder_id": 1,
    "assignee_ids": [2],
    "label_ids": [1, 5],
    "project_id": 103,
    "panel": "backlog",
    "insert_at": "bottom"
  }
}'
```

⚠️ **`project_id` is the one field here with a precondition.** Read the project's state first — a project past `started` takes the ticket without complaint and never advances again:

```sh
jus api GET '/workspaces/{ws}/projects/{id}?fields=id,name,state'
```

`panel` and `insert_at` are the placement, and they belong in this call rather than a follow-up — see `references/api.md` → Placing a ticket on create. Omit both and the ticket lands at the bottom of the **icebox**.
