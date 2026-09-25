# `jus` CLI & API Reference

The `jus` CLI wraps curl with auth, the `/api/v1` prefix, and jq formatting. Flags: `--raw` (no jq), `-v` (verbose). Token comes from `JUSCRIBE_API_TOKEN` or `.jus/config/api_token.txt`. Installed via Homebrew (`brew install juscribe/tap/jus`) and symlinked at `bin/jus` in this repo. **Output:** the `HTTP <status>` line goes to **stderr**; **stdout is pure JSON** — pipe stdout straight to a parser (`jus api GET '...' | jq .`). Never `2>&1`: it merges the status line into the body and breaks the parse. **Response shape:** bodies are wrapped under a top-level key — a single resource under `.ticket` / `.project`, lists under `.tickets` (with a sibling `.pagination`), `.comments`, etc. Parse `.ticket`/`.project`/`.tickets`, not the JSON root. `include_comments=true` inlines comments on a single **ticket** (`.ticket.comments`) but **not on a project** — fetch those from `jus api GET '/workspaces/{ws}/projects/{id}/comments'` (`.comments`). **Errors:** every mutating body must be wrapped under its resource key — `{"comment":{"body":"..."}}`, not `{"comment":"..."}` and not `{"body":"..."}` for anything you build by hand. A wrong shape is a **400** whose `.error` names the key. **Check the exit code, not just the body:** `jus api` exits **non-zero on any non-2xx** (since v0.6.11), and the error body is still valid JSON on stdout — so `| jq` succeeds on a failure too. A 404 body is only `{"error":"Not found"}` with no status field, so there is nothing in the JSON to key on; use `if ! jus api ...` or `set -e`.

- **Use `jus api` instead of `curl`** — manual curl loses auth and pretty-printing.
- **Avoid a direct console or ORM script for data work** — it bypasses controllers, broadcasts and activity logging, so changes won't show live and won't generate an audit trail. Go through the API.
- **Never fetch full ticket lists at session start** — use `agent_state` for orientation; fetch individual tickets on demand.
- **Combine efficiency tools** — sparse fieldsets, opt-out params, and `agent_state` stack; use them together. Every byte returned costs tokens.

**Two sibling files carry the rest:** `references/api-writes.md` for where a created ticket lands and the bulk endpoints, and `references/api-queries.md` for sparse fieldsets, opt-out params and the index filters.

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

## Three things `jus api` does to your call

Worth knowing because each is invisible in the response, and one of them can send a body you did not write.

- **`{ws}` is substituted for you.** `jus init` stores the workspace id and `jus api` replaces a literal `{ws}` in the path with it — so every path in this skill is copy-pastable as written. With no workspace configured the call stops and names `jus init`; it never requests the literal.
- **And the whole `/workspaces/{ws}/` prefix is optional**. `jus api GET /tickets` and `jus api GET '/tickets/{id}/comments'` resolve against the same stored id. A path whose first segment is a **top-level** route — `session`, `profile`, `notifications`, `api_tokens`, `organizations`, `teams`, `workspaces`, `admin`, `my`, `schema`, `versions` and the auth family — is left alone, so the short form cannot shadow one. ⚠️ **Only the CLI does this**, and the premise it looks like it rests on is false: only an agent token is workspace-scoped, so the server cannot infer a workspace from a credential. A raw `curl` writes the path in full.
- **The `/api/v1` prefix is added only when the path does not already start with `/api/`.** So a path you write in full reaches whatever namespace it names, unprefixed.
- ⚠️ **A malformed JSON body is auto-repaired, and only stderr says so.** When the shell has eaten quotes or truncated the body, `jus api` tries several recoveries, prints `Warning: Body was not valid JSON — auto-repaired.` and sends the repaired version. It is a rescue for a mangled call, not a licence to build bodies loosely — the repair may not be what you meant, and the request succeeds either way. Pass anything you did not type by hand through `@file` or a quoted heredoc, and read stderr.

## Request-shape gotchas

Five behaviours that present as a hang, a no-op, a bare 500, or a silent success rather than an error. Each is listed by the **symptom you will actually be looking at**.

- **The command hangs and never returns** → you ran `jus api PATCH <path>` with **no body argument**. It does not error and does not default to `{}`. On a CLI older than #4413 it waits on stdin forever; since that fix it waits a bounded moment and then sends no body, which the endpoint is no likelier to accept. Body-less endpoints still need an explicit empty object: `jus api PATCH /workspaces/{ws}/dependencies/{id}/resolve '{}'`. ⚠️ **An EMPTY body argument is the same as a missing one** — the CLI tests `[[ -n "$body_arg" ]]`, so `"$(jq ... < missing-file)"` reaches it as if you had passed nothing. `@file` is the form that fails loudly instead.
- **A newly created ticket is in the wrong panel, or at the wrong end of it** → you named no placement, and the default is the **bottom of the icebox** — not the panel you were looking at. Create takes `panel`, `state`, `position` and `insert_at` and honours all four; see `references/api-writes.md` → _Placing a ticket on create_. ⚠️ The recipe this bullet used to give — create, then `/reorder` — is a wasted call, and the claim it rested on (`position` silently ignored) stopped being true.
- **A transition is rejected as invalid** → `/transition` walks the state machine **one state at a time**. `unprioritized` straight to `started` is a 422, not a shortcut; go through `prioritized`. The error names the valid next states, so read it rather than guessing again.
- **A transition returns a body of nulls and nothing changes** → you tried to move a ticket **backwards**, e.g. `prioritized` → `unprioritized` when parking work back to the icebox. `/transition` only walks the state machine forwards. Use a direct field update instead: `PATCH /workspaces/{ws}/tickets/{id} '{"ticket":{"state":"unprioritized"}}'`. Forward moves keep using `/transition`.
- **A create returns a bare `HTTP 500` with `"Internal Server Error"` and nothing else** → check the **case** of an enum value. `ticket_type` is lowercase (`feature`, `bug`, `chore`, `milestone`, `release`, `deadline`, `research`); passing `"Release"` raises `ArgumentError` inside the model and surfaces as a 500 that names no field. Any enum-backed attribute fails the same way, so a 500 on an otherwise well-formed create is a casing bug until proven otherwise — not a server fault to retry.
- **You set `assignee_ids` / `label_ids` / `stakeholder_id` and the response shows `null`** → the write **succeeded**. `*_ids` fields do not echo back; the response carries the expanded `assignees` / `labels` / `stakeholder` objects instead. Verify against those, not the `*_ids` key, or you will retry a write that already landed.

