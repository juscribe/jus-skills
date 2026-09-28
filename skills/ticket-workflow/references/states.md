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
