# Converting a ticket

**A research ticket whose finding is a multi-ticket design is a project wearing a ticket's clothes.** The signal is concrete: you are about to write acceptance criteria that decompose into separate deliverables with their own dependencies.

⚠️ **Only a `research` ticket can be converted.** Anything else that has outgrown its type is a **retype** — `PATCH …/tickets/{id} '{"ticket":{"ticket_type":"chore"}}'` — because a feature that grew was always a feature. Conversion exists to preserve a finished investigation and link it to the work it recommends, which is a thing only research has.

There is a dedicated endpoint. **Do not cancel the ticket and hand-create a project** — that is the natural workaround if you do not know this exists, and it throws away the description, the requester, the stakeholder, and the link back.

```sh
jus api POST /workspaces/{ws}/tickets/{id}/convert '{}'
```

⚠️ **The body is required.** A body-less `POST`/`PATCH` hangs waiting on stdin rather than defaulting to `{}`.

What it does, in one transaction:

|  |  |
| --- | --- |
| Creates a project | carrying the ticket's **title, description, requester and stakeholder** |
| Sets `source_ticket_id` | so the project records where it came from |
| Transitions the ticket to **`converted`** | and clears its `project_id` |
| Records activities on both | and broadcasts `project_created` |

It returns `{ticket, project}`, so the new project's id comes back in the same call.

**It refuses** with a `422` and a message rather than failing silently, in the order the checks fire:

1. The ticket is already `converted`.
2. It is `cancelled` — a terminal state cannot become a project.
3. **It is not a `research` ticket** — `only a research ticket can be converted; this one is a feature`.

⚠️ The source-type check runs **ahead of** the target checks below, deliberately: a feature asking to become a feature is wrong for a more fundamental reason than whatever it named as a target, and hearing about `ticket_type` first sends you to fix the wrong parameter.

**After converting**, populate the project: create the child tickets with `project_id` set and their placement in the same call — `panel` plus `position` or `insert_at`, see `references/api.md` → Placing a ticket on create. For a whole set, `bulk_create` then `bulk_reorder`.

## Converting into a ticket instead

The same endpoint takes an optional `target`. Absent or `"project"` is the behaviour above; `"ticket"` creates one new ticket of a type you choose.

```sh
jus api POST /workspaces/{ws}/tickets/{id}/convert '{"target":"ticket","ticket_type":"feature"}'
```

Reach for it when a research ticket's finding is **one piece of work** rather than a decomposable design — a one-ticket project is the wrong shape for that.

The new ticket carries **title, description, requester, stakeholder, project and labels**, and lands at the **top of the icebox**, `unprioritized`. It does **not** carry points: a research estimate says nothing about the size of the work it recommends, so estimate it yourself before prioritising. Returns `{ticket, converted_ticket}` — the source serializes `converted_ticket_id`, the new one `source_ticket_id`. Unlike the project path, the source **keeps** its `project_id`.

⚠️ **`ticket_type` is required here, and a marker type is refused.** `feature`, `bug`, `chore` and `research` are the choices; `milestone`, `release` and `deadline` are dates on the timeline rather than work, so converting a finding into one loses the finding instead of scheduling it. A missing, unknown or marker `ticket_type` is a `422` naming the field.

```sh
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"started"}'
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"finished"}'
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"delivered"}'
jus api PATCH /workspaces/{ws}/tickets/{id}/transition '{"state":"cancelled","resolution":"duplicate"}'
```

> **NEVER transition to `accepted` or `rejected`** — only the stakeholder decides.
