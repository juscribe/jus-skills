# Ticket description rules — the full text

Read before any PATCH that touches a description. `SKILL.md` states the rule; this file is the whole of it, with the reasons and the traps.

## Ticket Description Rules

The rule protects exactly one thing — **stakeholder-authored text, preserved verbatim, always** — and it imposes exactly one duty on everything else: **agent-authored text stays current.**

- **NEVER overwrite the stakeholder's words.** Before any PATCH that replaces `description`, fetch the ticket first; an append (`description_append`) needs no fetch, because it never sends their words back. When fleshing out a stakeholder's description, their text comes first with a `---` line separating your additions — their sentence, even a single one, is the source of truth for what was requested, and replacing it with your own summary destroys the original intent. This holds in every context: triage, investigation notes, cancellation reasons, acceptance-criteria additions.
- **Below that boundary, EDIT — don't layer.** Agent-authored content is living documentation. When facts change, integrate the correction into the existing text so the description reads as one coherent, current spec. Do NOT stack dated "Update (…):" sections onto agent-authored content — sediment accumulates until nobody can tell current from stale. A dated correction note is only for a _stakeholder-authored_ claim you must not touch; your own text you simply fix.
- A stakeholder-requested rewrite may restructure everything — the one line never crossed is discarding the stakeholder's original words.

**Fleshing out needs no read at all.** Write your additions to a file, starting with the `---` line (drop it when the description is empty), and send them as `description_append`. The server joins them after a blank line to whatever the row holds at write time, so the stakeholder's words never travel through your shell and a failed read cannot wipe them:

```sh
test -s .jus/tmp/append.md \
  && jq -Rs '{ticket:{description_append:.}}' < .jus/tmp/append.md > .jus/tmp/append.json \
  && jus api PATCH /workspaces/{ws}/tickets/{id} @.jus/tmp/append.json
```

**MCP:** `append_to_description`.

**Updating your own additions later** is an edit inside the text, so it needs the round trip: read the description, rewrite your part in place with everything above the separator byte-identical, and PATCH the whole of it back. Use the guarded read and write in `ticket-workflow/references/delivering.md` → _Then tick the boxes you met_. ⚠️ **An unguarded round trip is how descriptions get wiped**: a failed read leaves an empty file, an empty description is a valid PATCH, and the API answers `200`. The routes to that and the recovery are in `ticket-workflow/references/api.md` → _Writing a description without wiping it_.

**MCP:** `get_ticket` to read, then `update_ticket` with the whole description.
