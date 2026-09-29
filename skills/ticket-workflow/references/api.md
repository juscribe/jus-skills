# `jus` CLI & API Reference

The `jus` CLI wraps curl with auth, the `/api/v1` prefix, and jq formatting. Flags: `--raw` (no jq), `-v` (verbose). Token comes from `JUSCRIBE_API_TOKEN` or `.jus/config/api_token.txt`. Installed via Homebrew (`brew install juscribe/tap/jus`) and symlinked at `bin/jus` in this repo. **Output:** the `HTTP <status>` line goes to **stderr**; **stdout is pure JSON** — pipe stdout straight to a parser (`jus api GET '...' | jq .`). Never `2>&1`: it merges the status line into the body and breaks the parse. **Response shape:** bodies are wrapped under a top-level key — a single resource under `.ticket` / `.project`, lists under `.tickets` (with a sibling `.pagination`), `.comments`, etc. Parse `.ticket`/`.project`/`.tickets`, not the JSON root. `include_comments=true` inlines comments on a single **ticket** (`.ticket.comments`) but **not on a project** — fetch those from `jus api GET '/workspaces/{ws}/projects/{id}/comments'` (`.comments`). **Errors:** every mutating body must be wrapped under its resource key — `{"comment":{"body":"..."}}`, not `{"comment":"..."}` and not `{"body":"..."}` for anything you build by hand. A wrong shape is a **400** whose `.error` names the key. **Check the exit code, not just the body:** `jus api` exits **non-zero on any non-2xx** (since v0.6.11), and the error body is still valid JSON on stdout — so `| jq` succeeds on a failure too. A missing record's 404 body is only `{"error":"Not found"}` and a path no route matches says `{"error":"No route: PATCH /api/v1/…"}`, neither with a status field, so there is nothing in the JSON to key on; use `if ! jus api ...` or `set -e`.

- **Use `jus api` instead of `curl`** — manual curl loses auth and pretty-printing.
- **Avoid a direct console or ORM script for data work** — it bypasses controllers, broadcasts and activity logging, so changes won't show live and won't generate an audit trail. Go through the API.
- **Never fetch full ticket lists at session start** — use `agent_state` for orientation; fetch individual tickets on demand.
- **Combine efficiency tools** — sparse fieldsets, opt-out params, and `agent_state` stack; use them together. Every byte returned costs tokens.

**Two sibling files carry the rest:** `references/api-writes.md` for where a created ticket lands and the bulk endpoints, and `references/api-queries.md` for sparse fieldsets, opt-out params and the index filters.

## Contents

- [HTTP method patterns & subcommands](#http-method-patterns-subcommands)
- [Three things `jus api` does to your call](#three-things-jus-api-does-to-your-call)
- [Request-shape gotchas](#request-shape-gotchas)
- [Rate limits](#rate-limits)
- [Attachments](#attachments)
- [Writing a description without wiping it](#writing-a-description-without-wiping-it)

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
jus dispatch init | start | logs          # manage the local dispatch agent
jus dispatch setup-sandbox | auth         # choose where it runs, and sign that CLI in
```

**MCP:** `get_ticket`, `create_ticket` (a tool takes JSON arguments, so none of the three body forms is needed) and `update_ticket`. No MCP tool deletes a blocker; `resolve_blocker` resolves one. `jus download` is `get_attachment`, and the setup commands have no tool because the connector's sign-in replaces them.

⚠️ **`jus cleanup` empties `.jus/tmp/` without asking**, and another session working in the same project may be keeping request bodies there. Run it only when nothing else is working here.

## Three things `jus api` does to your call

Worth knowing because each is invisible in the response, and one of them can send a body you did not write.

- **`{ws}` is substituted for you.** `jus init` stores the workspace id and `jus api` replaces a literal `{ws}` in the path with it — so every path in this skill is copy-pastable as written. With no workspace configured the call stops and names `jus init`; it never requests the literal.
- ⚠️ **A wrong workspace number writes to another board rather than failing.** A token reaches every workspace in its organization, so a stale or mistyped number in a written-out path is a valid request against someone else's board. Let `{ws}` or the short form supply it.
- **And the whole `/workspaces/{ws}/` prefix is optional**. `jus api GET /tickets` and `jus api GET '/tickets/{id}/comments'` resolve against the same stored id. A path whose first segment is a **top-level** route — `session`, `profile`, `notifications`, `api_tokens`, `organizations`, `teams`, `workspaces`, `admin`, `my`, `schema`, `versions` and the auth family — is left alone, so the short form cannot shadow one. ⚠️ **Only the CLI does this**, and the premise it looks like it rests on is false: no token names a workspace — an agent token reaches every workspace in its organization — so the server cannot infer one from a credential. A raw `curl` writes the path in full.
- **The `/api/v1` prefix is added only when the path does not already start with `/api/`.** So a path you write in full reaches whatever namespace it names, unprefixed.
- ⚠️ **A malformed JSON body is auto-repaired, and only stderr says so.** When the shell has eaten quotes or truncated the body, `jus api` tries several recoveries, prints `Warning: Body was not valid JSON — auto-repaired.` and sends the repaired version. It is a rescue for a mangled call, not a licence to build bodies loosely — the repair may not be what you meant, and the request succeeds either way. Pass anything you did not type by hand through `@file` or a quoted heredoc, and read stderr.

## Request-shape gotchas

Behaviours that present as a hang, a no-op, a bare 500, or a silent success rather than an error. Each is listed by the **symptom you will actually be looking at**.

- **The command hangs and never returns** → you ran `jus api PATCH <path>` with **no body argument**. It does not error and does not default to `{}`. An old CLI waits on stdin forever; a current one waits a bounded moment and then sends no body, which the endpoint is no likelier to accept. Body-less endpoints still need an explicit empty object: `jus api PATCH /workspaces/{ws}/dependencies/{id}/resolve '{}'`. ⚠️ **An EMPTY body argument is the same as a missing one** — the CLI tests `[[ -n "$body_arg" ]]`, so `"$(jq ... < missing-file)"` reaches it as if you had passed nothing. `@file` fails loudly instead when the file is missing. A file of malformed JSON goes through the same repair as any other body, and one the repair cannot fix is refused with an error that names the heredoc and `@file` forms and a non-zero exit — nothing is sent.
- **A newly created ticket is in the wrong panel, or at the wrong end of it** → you named no placement, and the default is the **bottom of the icebox** — not the panel you were looking at. Create takes `panel`, `state`, `position` and `insert_at` and honours all four; see `references/api-writes.md` → _Placing a ticket on create_. ⚠️ The recipe this bullet used to give — create, then `/reorder` — is a wasted call, and the claim it rested on (`position` silently ignored) stopped being true.
- **A transition is rejected as invalid** → `/transition` walks the state machine **one state at a time**. `unprioritized` straight to `started` is a 422, not a shortcut; go through `prioritized`. The error names the valid next states, so read it rather than guessing again.
- **A transition returns a body of nulls and nothing changes** → you tried to move a ticket **backwards**, e.g. `prioritized` → `unprioritized` when parking work back to the icebox. `/transition` only walks the state machine forwards. Use a direct field update instead: `PATCH /workspaces/{ws}/tickets/{id} '{"ticket":{"state":"unprioritized"}}'`. Forward moves keep using `/transition`.
- **A create returns a bare `HTTP 500` with `"Internal Server Error"` and nothing else** → check the **case** of an enum value. `ticket_type` is lowercase (`feature`, `bug`, `chore`, `milestone`, `release`, `deadline`, `research`); passing `"Release"` raises `ArgumentError` inside the model and surfaces as a 500 that names no field. Any enum-backed attribute fails the same way, so a 500 on an otherwise well-formed create is a casing bug until proven otherwise — not a server fault to retry.
- **You set `assignee_ids` / `label_ids` / `stakeholder_id` and the response shows `null`** → the write **succeeded**. `*_ids` fields do not echo back; the response carries the expanded `assignees` / `labels` / `stakeholder` objects instead. Verify against those, not the `*_ids` key, or you will retry a write that already landed.
- **A write is refused with `label 99 is not in this workspace` or `user 7 is not a member of this workspace`** → an id you sent is not the workspace's, and nothing was written. Take label ids from `GET /workspaces/{ws}/labels` and assignees from the workspace's members. In a bulk call only that item fails.
- **Editing a comment answers a `404`** → the route is nested under its ticket: `PATCH /workspaces/{ws}/tickets/{id}/comments/{comment_id}`. The flat `PATCH /workspaces/{ws}/comments/{comment_id}` does not exist; its 404 says `No route: PATCH /api/v1/workspaces/{ws}/comments/{comment_id}`, where a missing comment says `Not found`.
- **A reply is refused with `Parent cannot reply to a reply`** → threads are one level deep. Send `reply_to_id` with the comment you are answering instead of `parent_id`, and the server attaches the reply to the thread's root.


## Rate limits

A caller over budget gets **`429` with `Retry-After: 60`**. The budget is counted per user, so **every session and every token of one bot share it**: three agents working the same board spend one allowance.

| Caller | Requests per minute | Of which writes |
| --- | --- | --- |
| a bot (agent token), free organization | 600 | 300 |
| a bot (agent token), paid organization | 3,000 | 1,500 |

Honour `Retry-After` rather than retrying at once, and cut the calls rather than pacing them: a filter or a sparse fieldset instead of paging, a bulk endpoint (`references/api-writes.md`) instead of a loop. A `503` is different: it is maintenance, covered in `references/setup.md`.

## Attachments

Upload is `multipart/form-data` to `POST /workspaces/{ws}/tickets/{id}/attachments`, one `files[]` part per file, up to **25 MB** each, from an allowlist of document and image types. `jus` has no upload command, so this is `curl` with the token from a config file (never on the command line):

```sh
curl -sS -K .jus/tmp/auth.conf -F 'files[]=@screenshot.png' "https://app.juscribe.ai/api/v1/workspaces/{ws}/tickets/{id}/attachments"
```

**MCP:** `attach_file`.

`.jus/tmp/auth.conf` holds one line, `header = "Authorization: Bearer <token>"`, written with `umask 077`. Downloading goes through `jus download`.

## Writing a description without wiping it

**An empty description is a valid PATCH, and the API answers `200` to it.** So every route below erases a ticket's description while the call reports success, and it is noticed only on the next read.

- **Adding text needs no read at all.** `description_append` joins your text after a blank line to whatever the row holds at write time, so neither a failed read nor a concurrent edit can lose anything. It is refused with a `422` when empty, or when sent together with `description`. The recipe is in `hard-rules` → Ticket Description Rules.
- **Editing inside the text needs the round trip**, and the guarded read and write are in `references/delivering.md` → _Then tick the boxes you met_. Each step is chained to the last, which is the whole guard.

Five ways the round trip turns into a wipe, each by the shape it takes:

- **`2>&1` on the read.** The `HTTP 200` line goes to stderr; merged into stdout it breaks the JSON, `jq` fails, and `> desc.md` has already truncated the file.
- **Stripping the status line off stdout** (`tail -n +2`, `sed 1d`). It was never on stdout, so this deletes the opening `{` of a good body instead, with the same result.
- **`"$(cat file)"` on a missing or misnamed file.** `cat` complains on stderr and the substitution is empty, so the PATCH carries `""`. Pass `@file`, which fails loudly when the file is missing.
- **An empty body file.** `jq -Rs` on an empty file builds valid JSON holding an empty string. Put `test -s <file>` in front of every write of prose.
- **A write on its own line after the read.** It runs whatever the read did, including nothing. Keep the round trip in one `&&` chain.

A `null` description is the same trap in another form: `jq -r`/`jq -j` prints the text `null`, and that is what gets written back.

**Wiped anyway? The activity log keeps the text it replaced.** The wipe is an `update` activity whose `detail.description` is `{from, to}` with `to` empty, and `from` is the whole prior description, verbatim. Activities are listed newest first, so this saves the text the latest wipe erased:

```sh
jus api GET '/workspaces/{ws}/tickets/{id}/activities' | jq -r '[.activities[] | select(.detail.description?.to == "")][0].detail.description.from' > .jus/tmp/restore.md
```

**MCP:** no MCP tool reads the activity log. Ask the person to restore the text from the ticket's history in the app.

Check `restore.md` with `test -s`, then send it back with the guarded write.
