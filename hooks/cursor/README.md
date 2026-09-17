# jus enforcement hooks — Cursor adapter

Runs all thirteen shared hook scripts (`../scripts/`) under Cursor's native
hooks system (#4261).

> ## ⚠️ NOT LIVE-VERIFIED. READ THIS BEFORE RELYING ON IT.
>
> **No hook in this adapter has been watched refusing anything.** `cursor-agent`
> is not installed on the machine this was written on, so what follows rests on
> Cursor's published hooks documentation plus the shim's own tests against
> synthetic payloads — not on a session where a `git push --force` was actually
> blocked.
>
> Compare the Codex adapter, whose README describes a prompted force-push
> refused with the remote tip unmoved, because codex was installed.
>
> **What would settle it:** install `cursor-agent`, prompt it to force-push a
> throwaway branch, check the remote tip, and replace this box with what you saw.

> ⚠️ **These hooks do nothing outside a Juscribe project** (#4404). Each runs
> only when the payload's `cwd` is inside a git repository whose toplevel holds
> a `.jus/` directory; everywhere else they exit 0 in silence. That is the
> shared scripts' behaviour, so it applies here however this adapter is
> installed — including a user-scope install that every project on the machine
> sees. `JUS_HOOKS_EVERYWHERE=1` restores the old machine-wide behaviour.

## Setup

One shared clone per machine, then either scope:

```sh
git clone https://github.com/juscribe/jus-skills.git ~/.jus-skills
```

**Per project:**

```sh
mkdir -p .cursor && cp ~/.jus-skills/hooks/cursor/hooks.json .cursor/hooks.json
```

**Per machine:**

```sh
cp ~/.jus-skills/hooks/cursor/hooks.json ~/.cursor/hooks.json
```

⚠️ **Do not install at both scopes.** Cursor merges what it finds, so every hook
registers twice and fires twice per event — the same trap
`installing-the-bundle.md` documents for Claude Code, with the same symptom:
nothing fails, a counter just doubles.

⚠️ **The `~` in every `command` is unverified.** Cursor documents project hook
commands as running from the project root and suggests relative paths like
`.cursor/hooks/script.sh`; this manifest uses `~/.jus-skills/...` because the
bundle lives outside the project and there is no relative path from `.cursor/` to
a home directory. Whether Cursor spawns these through a shell that expands `~` is
exactly the kind of thing an install settles in one run. **If the hooks do
nothing at all, this is the first thing to check** — substitute your absolute
home path and try again.

## Why this one is nearly a passthrough

Cursor's `preToolUse` and `postToolUse` payloads already carry `tool_name` and
`tool_input` under exactly the names the shared scripts read, and **exit 2
blocks** — documented as "equivalent to `permission: deny`". So neither the
input nor the output needs translating on those two events.

⚠️ **And its failure default already matches ours.** Cursor treats any non-zero
exit other than 2 as fail-**open** unless the hook sets `failClosed: true`. That
is this bundle's own doctrine, so the Cursor shim needs none of the exit-code
collapse the Copilot one does — see `hooks/copilot/README.md` for what that
asymmetry costs there. **Do not add `failClosed: true` to this manifest**: it
turns a broken `jq` into a stopped agent.

What does need a shim is that Cursor splits shells, edits and prompts into their
**own events**, none of which carries `tool_name`:

| Cursor event                 | carries                         | normalized to              |
| ---------------------------- | ------------------------------- | -------------------------- |
| `beforeShellExecution`       | `command`, `cwd`, `sandbox`     | `tool_name: "Bash"`        |
| `afterShellExecution`        | `command`, `output`, `duration` | `Bash` + `tool_response`   |
| `afterFileEdit`              | `file_path`, `edits[]`          | `tool_name: "MultiEdit"`   |
| `beforeSubmitPrompt`         | `prompt`, `attachments`         | `prompt`, unchanged        |
| `stop`                       | `status`, `loop_count`          | `cwd` + `stop_hook_active` |
| `preToolUse` / `postToolUse` | `tool_name`, `tool_input`       | passthrough                |

✅ **The shell events are why this adapter is the sturdiest of the five.**
`beforeShellExecution` hands over `command` directly, so the five command
blockers never have to guess what Cursor calls its shell tool — the failure mode
that forces shape-inference on Copilot (#4260) does not arise here.

## The three degradations

**1. ⚠️ `stop` CANNOT BLOCK, so the dirty-tree gate becomes advice.**

Cursor lists `stop` among the hooks that cannot refuse an action.
`jus-stop-uncommitted.sh` is a hard gate on Claude Code, Codex and Kimi's plugin
path: it exits 2 and the session cannot end with uncommitted work. On Cursor the
message is printed and the session ends anyway.

This is the Kimi shape exactly — enforcement degrading to a reminder — and it is
the single thing that stops this being full parity. It is also the most
consequential of the thirteen to lose, because it is the one that catches work
about to be abandoned rather than work about to be done wrong.

**2. There is no before-file-edit event.**

`afterFileEdit` fires once the write has happened, so it cannot refuse one.
`jus-block-lint-suppression.sh` therefore rides `preToolUse`, which is the only
pre-hook that can see an edit — and there the tool **name** is undocumented, so
the shim infers from the argument shape:

| `tool_input` carries          | mapped to   |
| ----------------------------- | ----------- |
| `.edits`                      | `MultiEdit` |
| `.old_string` / `.new_string` | `Edit`      |
| `.content`                    | `Write`     |
| `.command`                    | `Bash`      |

⚠️ **The inference is confined to `preToolUse`.** Every other event above already
knows what it is, and guessing where you do not have to is how a shim acquires a
second failure mode.

**3. `stop` carries neither `cwd` nor `stop_hook_active`.**

The workspace comes from the common `workspace_roots` array, and the loop guard
from `loop_count`, which Cursor increments each time the stop hook has already
run this turn. The shim maps `workspace_roots[0]` → `cwd` and `loop_count > 0` →
`stop_hook_active`.

⚠️ **Get either wrong and the failure is silent in opposite directions:** a
missing `cwd` means the hook never finds a repository and never fires; a missing
loop guard means it fires forever.

## `beforeMCPExecution` is NOT registered, and that is a decision

Cursor has two events Claude Code does not — `beforeShellExecution` and
`beforeMCPExecution` — and the second is a genuine gap in what this bundle
protects. An MCP tool can reach the same outcomes as a shell command, unwatched.

**It is still not registered, because our guards have nothing to match.**
`jus-block-force-push.sh` and `jus-block-no-verify.sh` are command-**text**
matchers: they read `tool_input.command` and look for `--force` or `--no-verify`.
A `beforeMCPExecution` payload carries `mcp_server_name`, a server URL or command,
and an arbitrary `tool_input` object — there is no command string in it.
Registering them there would add hook invocations that can never fire, which
reads as coverage on an audit and is not.

**What covering it would actually take** is a different guard that matches on MCP
_tool names_ — and there is no portable answer to what a force-push-equivalent
MCP tool is called on someone else's setup. That is its own ticket. The gap is
named here so the next person meets it as a decision rather than an oversight.

## Event mapping

| Shared hook                           | Claude event       | Cursor event                                  |
| ------------------------------------- | ------------------ | --------------------------------------------- |
| `jus-block-force-push.sh`             | `PreToolUse`       | `beforeShellExecution`                        |
| `jus-block-no-verify.sh`              | `PreToolUse`       | `beforeShellExecution`                        |
| `jus-pre-commit-gate.sh`              | `PreToolUse`       | `beforeShellExecution`                        |
| `jus-block-accepted-manifest-edit.sh` | `PreToolUse`       | `beforeShellExecution`                        |
| `jus-blocker-date-nudge.sh`           | `PreToolUse`       | `beforeShellExecution`                        |
| `jus-block-lint-suppression.sh`       | `PreToolUse`       | `preToolUse`                                  |
| `jus-post-bash-tracker.sh`            | `PostToolUse`      | `afterShellExecution`                         |
| `jus-track-edits.sh`                  | `PostToolUse`      | `afterFileEdit`                               |
| `jus-start-comment-nudge.sh`          | `PostToolUse`      | `afterFileEdit`                               |
| `jus-docs-nudge.sh`                   | `PostToolUse` ×2   | `afterShellExecution` **and** `afterFileEdit` |
| `jus-stop-uncommitted.sh`             | `Stop`             | `stop` — **advisory only**                    |
| `jus-ticket-claim-nudge.sh`           | `UserPromptSubmit` | `beforeSubmitPrompt`                          |

✅ **`jus-docs-nudge.sh` is registered twice here and that is correct**, unlike on
Copilot. Claude registers it under two matchers of one event; Cursor has two
distinct events, so two registrations fire on different things rather than
double-firing on the same one.

## Skills, and not loading them twice

Cursor reads `.agents/skills/`, `.cursor/skills/`, `~/.agents/skills/` and
`~/.cursor/skills/`, and for compatibility also `.claude/skills/` and
`.codex/skills/`. The canonical install writes `.agents/skills/` only, so one
install is one copy.

⚠️ **The risk is a project that already has another tool's directory.** A repo
carrying both `.agents/skills/jus-*` and `.claude/skills/jus-*` — say because
someone set it up for Claude Code first — gives Cursor the same skills twice,
listed twice, with nothing saying which is which. Symlinking both at the same
shared clone does not help: Cursor discovers by path, not by inode.

## Tests

`jus/hooks/tests.sh`, in the `cursor adapter` section: the manifest is valid JSON
in Cursor's shape, every script it names exists, all thirteen are registered, and
the shim normalises each of the six event shapes — including that `stop` derives
its `cwd` from `workspace_roots` and its loop guard from `loop_count`.
