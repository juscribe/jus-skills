# State Machine Reference

Read before any transition other than `started` or `finished`, or when a transition is refused.

```
unprioritized → prioritized → started → finished → delivered → accepted
                                                             → rejected → started
Any non-terminal state → cancelled  (requires resolution)
Any non-terminal state → converted  (ticket became a project — see below)
archived → accepted
```

Valid `cancelled` resolutions (enum — exact values): `duplicate`, `wont_do`, `cant_reproduce`, `obsolete`.

Panel mapping: `unprioritized→icebox`, `prioritized→backlog`, `started/finished/delivered/rejected→current`, `accepted/cancelled/converted/archived→done`.

`converted` and `archived` are terminal in practice: `converted` has no onward transition, and `archived` can only go to `accepted`.

⚠️ **A board may MERGE Finished into Delivered** — a per-workspace option its owner sets. The map is unchanged; the `finished` call lands the ticket in `delivered` in one transaction. That is why your `finished` call is your last one on every board: merged, it delivers; unmerged, delivering is a person's step. A `delivered` call on a ticket already there answers `200` unchanged, which is not a failure. The workspace payload's `merge_finished_into_delivered` says which kind of board you are on.

## Reopening a cancelled ticket

`cancelled` is terminal for `/transition`, but a plain PATCH of the state takes a ticket back, and **leaving `cancelled` clears the resolution**:

```sh
jus api PATCH /workspaces/{ws}/tickets/{id} '{"ticket":{"state":"prioritized"}}'
```

**MCP:** `update_ticket` with `state`.

Sending a `resolution` with a state that is not `cancelled` is still a `422` (`Resolution can only be set when state is cancelled`): the two contradict each other. The ticket keeps its id, comments and project, and lands at the bottom of the backlog.

## Projects

- **A project moves through `projects/{id}/transition`, and is placed through `projects/{id}/reorder`.** Create and PATCH take `name`, `description`, `color`, `requester_id`, `stakeholder_id`, `label_ids` and `assignee_ids`; a `state`, `panel` or `position` in either body is a `422` naming the two endpoints.
- **A cancelled project reopens only with `"force": true`** on the transition.
- ⚠️ **Cancelling a project cancels every ticket in it that is not already in Done**, started ones included, each with the project's resolution. Done tickets are left as they are. If one ticket refuses, the whole call fails with a `422` naming why and nothing is cancelled. The project's `cancellable_ticket_count` says how many a cancel would take; read it first.
- **A sealed project's state follows its tickets.** Where sealing is on, every manual transition on a sealed project is a `422` except `cancelled`, and `force` does not lift it.
