# jus enforcement hooks — Google Antigravity adapter

Runs all twelve shared hook scripts (`../scripts/`) under Antigravity's hooks
system (#4262). Antigravity replaced the Gemini CLI, which was sunset on
2026-06-18.

> ## ⚠️ THE WEAKEST-EVIDENCE ADAPTER IN THIS BUNDLE. READ ALL OF THIS BOX.
>
> Every other adapter here was written against **vendor documentation**.
> **Google does not document Antigravity's hook payload or its deny mechanism at
> all** — `antigravity.google/docs/cli/reference` lists a `/hooks` slash command
> and stops; the plugins page says hooks live "inside a plugin's `hooks.json` or
> your primary `settings.json`" and stops.
>
> So this was built from three third-party sources, **which disagree on the two
> things that decide whether a block works**:
>
> | Source                                         | Global config path                     | Deny response                               |
> | ---------------------------------------------- | -------------------------------------- | ------------------------------------------- |
> | Antigravity developer guide (Aug 2026)         | `~/.gemini/antigravity-cli/hooks.json` | `{"allow_tool": false, "deny_reason": "…"}` |
> | atamel.dev (Jul 2026, rev. Aug)                | `~/.gemini/config/hooks.json`          | not stated                                  |
> | **atuinsh/atuin#4117 — shipped, working code** | `~/.gemini/config/hooks.json`          | `{"decision": "allow"}`                     |
>
> Nothing here has been watched refusing anything: `agy` is not installed on the
> machine this was written on.
>
> **What the install settles, in order of how badly it is needed:**
>
> 1. Which deny key the engine actually reads. The shim emits **both**, so this
>    is survivable — unless (2).
> 2. **Whether Antigravity validates the response schema strictly.** If it
>    rejects an unknown key, the hedge in (1) breaks every hook rather than only
>    the wrong half. Nothing establishes this either way and it is the single
>    highest-risk unknown in this file.
> 3. Which global path is real. Project scope (`.agents/hooks.json`) is agreed by
>    all three sources; use that until (3) is answered.

## Setup

One shared clone per machine, then **project scope**, which every source agrees on:

```sh
git clone https://github.com/juscribe/jus-skills.git ~/.jus-skills
```

```sh
mkdir -p .agents && cp ~/.jus-skills/hooks/antigravity/hooks.json .agents/hooks.json
```

⚠️ **`.agents/hooks.json`, not `.agents/skills/`.** They are siblings and both are
Antigravity roots: the skills install writes `.agents/skills/<name>/`, this writes
a file one level up. Putting the manifest inside `skills/` registers nothing and
looks fine.

Global scope, **if** the atuin/atamel path is the right one:

```sh
mkdir -p ~/.gemini/config && cp ~/.jus-skills/hooks/antigravity/hooks.json ~/.gemini/config/hooks.json
```

⚠️ **A hook declared in both scopes runs twice** — both are loaded and merged, per
the developer guide. Pick one.

## The response translation, and why only this adapter needs it

Claude Code, Codex, Kimi, Copilot and Cursor all treat **exit 2 with a stderr
reason** as a block. That is exactly what the thirteen shared scripts already do,
so on those five the blocking half of an adapter is free.

**Antigravity wants a JSON answer on stdout for every invocation**, including the
ones that allow. From the atuin PR's own note:

> _"Antigravity requires an answer on stdout for every invocation: allow
> pre-tool-use hooks (including ones for tools Atuin ignores) and acknowledge
> everything else."_

So `jus-antigravity-adapt.sh` captures the shared script's **stderr as the
reason** and its **exit code as the verdict**, then writes:

```json
{ "decision": "deny", "allow_tool": false, "deny_reason": "…", "reason": "…" }
```

⚠️ **Both deny spellings are emitted on purpose.** They are different keys, so
they cannot contradict each other, and an unrecognised sibling is inert. This is
a hedge against a contested contract, labelled as one — not a belt-and-braces
habit to copy into the other adapters.

⚠️ **Only exit 2 denies.** Everything else allows, including a crash. That is the
usual fail-open doctrine, and it matters more here than elsewhere: a hook that
writes nothing at all to stdout may wedge the agent loop rather than merely
failing to guard.

## Payload mapping

| Antigravity                  | shared scripts          |
| ---------------------------- | ----------------------- |
| `.toolCall.args.CommandLine` | `tool_input.command`    |
| `.toolCall.args.ToolName`    | `tool_name` (MCP tools) |
| `.toolCall.name`             | `tool_name`             |
| `.toolCall.args`             | `tool_input`            |

⚠️ **The command is nested two levels deeper than anywhere else.**
`.toolCall.args.CommandLine` is the one field shipped code attests to. The shim
carries flatter fallbacks after it, which cost nothing and mean a payload that
turns out simpler than this still reaches the guards — rather than reaching them
as an empty string, which reads as "no command" and passes everything.

For edits, the tool name is inferred from the argument shape, as on Copilot and
Cursor: `.edits` → `MultiEdit`, `.old_string`/`.new_string` → `Edit`, `.content`
→ `Write`.

## Event mapping — twelve, not thirteen

Antigravity exposes five events: `PreToolUse`, `PostToolUse`, `PreInvocation`,
`PostInvocation` and `Stop`. Only `PreToolUse`, `PreInvocation` and
`PostInvocation` can refuse.

| Shared hook                           | Claude event       | Antigravity event          |
| ------------------------------------- | ------------------ | -------------------------- |
| `jus-block-force-push.sh`             | `PreToolUse`       | `PreToolUse`               |
| `jus-block-no-verify.sh`              | `PreToolUse`       | `PreToolUse`               |
| `jus-pre-commit-gate.sh`              | `PreToolUse`       | `PreToolUse`               |
| `jus-block-accepted-manifest-edit.sh` | `PreToolUse`       | `PreToolUse`               |
| `jus-blocker-date-nudge.sh`           | `PreToolUse`       | `PreToolUse`               |
| `jus-block-lint-suppression.sh`       | `PreToolUse`       | `PreToolUse`               |
| `jus-track-edits.sh`                  | `PostToolUse`      | `PostToolUse`              |
| `jus-post-bash-tracker.sh`            | `PostToolUse`      | `PostToolUse`              |
| `jus-start-comment-nudge.sh`          | `PostToolUse`      | `PostToolUse`              |
| `jus-docs-nudge.sh`                   | `PostToolUse` ×2   | `PostToolUse` ×1           |
| `jus-stop-uncommitted.sh`             | `Stop`             | `Stop` — **advisory only** |
| `jus-ticket-claim-nudge.sh`           | `UserPromptSubmit` | `PreInvocation`            |

⚠️ **`Stop` cannot block here either**, so the dirty-tree gate degrades to a
message exactly as it does on Cursor (#4261) and Kimi. That is the same
enforcement-becomes-advice loss, for the same reason, on a third tool.

⚠️ **`jus-docs-nudge.sh` is registered once**, like Copilot and unlike Cursor:
Antigravity has one post-tool event, so a second registration would double-fire
rather than cover a second surface.

## ⚠️ The sandbox does NOT make any of these redundant

Antigravity sandboxes by default — `sandbox-exec` on macOS, `nsjail` on Linux,
with `read_file` paths mounted read-only and `write_file` paths read-write. It is
a stronger default than Claude Code's, and the obvious question is which of our
hooks it replaces.

**None of them.** The two constraints are orthogonal:

- The sandbox constrains **where** a write may land.
- Every one of these constrains **what is done**, wherever it lands.

`block-force-push` and `block-no-verify` are git operations against a remote, not
filesystem writes. `block-lint-suppression` cares about the _content_ of an edit
to a file the sandbox already permits. `block-accepted-manifest-edit` cares about
_which board artefact_ is changing. `pre-commit-gate`, `stop-uncommitted` and the
nudges are session and workflow state.

The sandbox stops an agent escaping the project; these stop it working badly
inside one. An adapter that duplicated the sandbox would be noise — this one does
not, and that is a finding rather than a coincidence.

## Skills

Antigravity reads project `.agents/skills/` plus `GEMINI.md` and `AGENTS.md` as
context, so the canonical install works unchanged. ⚠️ **Its IDE ignores symlinks
for global skills** (issue #633) — use copies there: `cp -r ~/.jus-skills/skills/*
.agents/skills/`.

## Tests

`jus/hooks/tests.sh`, in the `antigravity adapter` section: the manifest is valid
JSON in the named-container shape, every script it names exists, all twelve are
registered, and the shim is checked in **both** directions — that a force-push
nested under `.toolCall.args.CommandLine` produces a deny object carrying both
spellings, that an allowed call still answers on stdout, and that a crash or
malformed input answers `allow` rather than nothing.
